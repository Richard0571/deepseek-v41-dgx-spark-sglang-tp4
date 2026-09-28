"""suwen_fixes 单测（纯 CPU、只用标准库）：python test_suwen_fixes.py"""
import asyncio
import enum
import importlib
import importlib.abc
import importlib.machinery
import sys
import tempfile
import types
import unittest
from collections import namedtuple
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import suwen_fixes  # noqa: E402


def fake_schedule_policy(chunked):
    """仿 dsv4.1 分支：add_one_req 调 _select_prefill_admission，is_chunked 时写 new_chunked_req。"""
    mod = types.ModuleType('fake_schedule_policy')
    mod.AddReqResult = enum.Enum('AddReqResult', 'CONTINUE NO_TOKEN OTHER')
    mod._PrefillAdmission = namedtuple('_PrefillAdmission', 'prefix_len extend_len max_new_tokens is_chunked')

    class PrefillAdder:
        def __init__(self):
            self.new_chunked_req = None
            self.can_run_list = []

        def _select_prefill_admission(self, req, **kwargs):
            if req == 'boom':
                raise RuntimeError('select failed')
            return mod._PrefillAdmission(0, 4096, 0, chunked)

        def add_one_req(self, req, has_chunked_req, truncation_align_size):
            admission = self._select_prefill_admission(req, truncation_align_size=truncation_align_size)
            if isinstance(admission, mod.AddReqResult):
                return admission
            self.can_run_list.append(req)
            if admission.is_chunked:
                self.new_chunked_req = req
            return mod.AddReqResult.CONTINUE

    mod.PrefillAdder = PrefillAdder
    suwen_fixes.install_chunked_serialize(mod)
    return mod


class ChunkedSerialize(unittest.TestCase):
    def test_first_chunked_request_admitted(self):
        mod = fake_schedule_policy(chunked=True)
        adder = mod.PrefillAdder()
        res = adder.add_one_req('a', has_chunked_req=False, truncation_align_size=None)
        self.assertEqual(res, mod.AddReqResult.CONTINUE)
        self.assertEqual(adder.new_chunked_req, 'a')

    def test_second_chunked_request_deferred(self):
        mod = fake_schedule_policy(chunked=True)
        adder = mod.PrefillAdder()
        res = adder.add_one_req('b', has_chunked_req=True, truncation_align_size=None)
        self.assertEqual(res, mod.AddReqResult.OTHER)
        self.assertIsNone(adder.new_chunked_req)
        self.assertEqual(adder.can_run_list, [])

    def test_fitting_request_admitted_while_chunked_inflight(self):
        mod = fake_schedule_policy(chunked=False)
        adder = mod.PrefillAdder()
        res = adder.add_one_req('c', True, None)
        self.assertEqual(res, mod.AddReqResult.CONTINUE)
        self.assertEqual(adder.can_run_list, ['c'])

    def test_flag_reset_after_exception(self):
        mod = fake_schedule_policy(chunked=True)
        adder = mod.PrefillAdder()
        with self.assertRaises(RuntimeError):
            adder.add_one_req('boom', has_chunked_req=True, truncation_align_size=None)
        self.assertFalse(adder._suwen_chunked_inflight)
        res = adder.add_one_req('d', has_chunked_req=False, truncation_align_size=None)
        self.assertEqual(res, mod.AddReqResult.CONTINUE)

    def test_layout_change_raises(self):
        with self.assertRaises(RuntimeError):
            suwen_fixes.install_chunked_serialize(types.ModuleType('empty'))


async def agen(items, delay_first=0.0):
    if delay_first:
        await asyncio.sleep(delay_first)
    for item in items:
        if isinstance(item, Exception):
            raise item
        yield item


def collect(stream):
    async def run():
        return [x async for x in stream]
    return asyncio.run(run())


def err(msg):
    return f'data: {{"error": "{msg}"}}\n\n'


class Keepalive(unittest.TestCase):
    def test_fast_first_chunk_no_comment(self):
        out = collect(suwen_fixes.keepalive_stream(agen(['a', 'b']), 0.2, 0.1, err))
        self.assertEqual(out, ['a', 'b'])

    def test_slow_first_chunk_gets_comments(self):
        out = collect(suwen_fixes.keepalive_stream(agen(['a'], delay_first=0.35), 0.1, 0.1, err))
        self.assertGreaterEqual(out.count(suwen_fixes.KEEPALIVE_LINE), 2)
        self.assertEqual(out[-1], 'a')

    def test_early_value_error_raises(self):
        with self.assertRaises(ValueError):
            collect(suwen_fixes.keepalive_stream(agen([ValueError('bad')]), 0.2, 0.1, err))

    def test_late_value_error_becomes_event(self):
        async def slow_fail():
            await asyncio.sleep(0.25)
            raise ValueError('late')
            yield  # noqa: unreachable，使其成为异步生成器
        out = collect(suwen_fixes.keepalive_stream(slow_fail(), 0.1, 0.1, err))
        self.assertIn(suwen_fixes.KEEPALIVE_LINE, out)
        self.assertEqual(out[-2:], [err('late'), 'data: [DONE]\n\n'])

    def test_cancel_closes_inner(self):
        closed = []

        async def inner():
            try:
                await asyncio.sleep(10)
                yield 'never'
            finally:
                closed.append(True)

        async def run():
            stream = suwen_fixes.keepalive_stream(inner(), 0.05, 0.05, err)
            first = await stream.__anext__()
            await stream.aclose()
            return first

        self.assertEqual(asyncio.run(run()), suwen_fixes.KEEPALIVE_LINE)
        self.assertEqual(closed, [True])


class FinderComposition(unittest.TestCase):
    def test_wraps_after_another_wrapping_finder(self):
        tmp = tempfile.mkdtemp()
        pkg = Path(tmp) / 'suwenfakepkg'
        pkg.mkdir()
        (pkg / '__init__.py').write_text('')
        (pkg / 'mod.py').write_text('VALUE = 1\n')
        sys.path.insert(0, tmp)

        class OuterLoader(importlib.abc.Loader):
            def __init__(self, inner):
                self.inner = inner

            def create_module(self, spec):
                return self.inner.create_module(spec)

            def exec_module(self, module):
                self.inner.exec_module(module)
                module.outer = True

        class OuterFinder(importlib.abc.MetaPathFinder):
            def find_spec(self, fullname, path=None, target=None):
                if fullname != 'suwenfakepkg.mod':
                    return None
                spec = importlib.machinery.PathFinder.find_spec(fullname, path)
                spec.loader = OuterLoader(spec.loader)
                return spec

        calls = []
        saved = dict(suwen_fixes._HOOKS)
        suwen_fixes._HOOKS.clear()
        suwen_fixes._HOOKS['suwenfakepkg.mod'] = lambda m: calls.append(getattr(m, 'outer', False))
        outer = OuterFinder()
        sys.meta_path.insert(0, outer)
        try:
            suwen_fixes.install_finder()
            mod = importlib.import_module('suwenfakepkg.mod')
            self.assertTrue(mod.outer)
            self.assertEqual(calls, [True])
        finally:
            sys.meta_path[:] = [f for f in sys.meta_path
                                if f is not outer and not isinstance(f, suwen_fixes._Finder)]
            suwen_fixes._HOOKS.clear()
            suwen_fixes._HOOKS.update(saved)
            sys.path.remove(tmp)


if __name__ == '__main__':
    unittest.main(verbosity=2)
