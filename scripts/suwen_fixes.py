"""knapcio v2.2 上游栈的两处本机修复，由 sitecustomize 在每个 Python 进程里装上。

1. 切块串行（``sglang.srt.managers.schedule_policy``）：dsv4.1 分支的
   ``PrefillAdder.add_one_req`` 不看 ``has_chunked_req``，已有切块请求在跑时仍会再收一条
   会被切块的新请求，调度器随后 ``assert self.chunked_req is None`` 让四台一起退出（09-26
   实录 Exit 247）。这里只把「会被切块」的新请求退回等待队列（``AddReqResult.OTHER``），
   放得下的请求照常进批。``SUWEN_SERIALIZE_CHUNKED=0`` 关闭。

2. SSE keepalive（``sglang.srt.entrypoints.openai.serving_chat``）：SGLang 首个 token
   出来前不发响应头，DSH 的 Node fetch（undici）300 s 收不到头或字节就断开，冷 prefill
   或排队超过 5 分钟的请求会被静默丢弃（09-28 实录）。首块 ``grace`` 秒内没来就先发一行
   SSE 注释，之后每 ``every`` 秒一行直到首块。``DSV41_SSE_KEEPALIVE_EVERY_S=0`` 关闭。

serving_chat 已由 knapcio 的 EngramFinder 接管（装 encoding_compat），本查找器先取它给的
spec 再包一层，不替换它。
"""
import asyncio
import importlib.abc
import logging
import os
import sys

logger = logging.getLogger(__name__)

KEEPALIVE_LINE = ': keepalive\n\n'
_OFF = ('0', 'off', 'false', 'no')


def _say(msg):
    logger.warning(msg)
    print(msg, flush=True)


# ─── 1. 切块串行 ──────────────────────────────────────────────────────────────

def install_chunked_serialize(module):
    if os.environ.get('SUWEN_SERIALIZE_CHUNKED', '1').strip().lower() in _OFF:
        _say('SUWEN fix: chunked serialize off (SUWEN_SERIALIZE_CHUNKED=0)')
        return
    cls = getattr(module, 'PrefillAdder', None)
    admission_cls = getattr(module, '_PrefillAdmission', None)
    result_cls = getattr(module, 'AddReqResult', None)
    if cls is None or admission_cls is None or result_cls is None \
            or not hasattr(cls, '_select_prefill_admission'):
        raise RuntimeError('PrefillAdder / _PrefillAdmission / AddReqResult layout changed')
    if getattr(cls, '_suwen_chunked_serialize', False):
        return
    other = result_cls.OTHER
    original_add = cls.add_one_req
    original_select = cls._select_prefill_admission
    refused = [0]

    def add_one_req(self, req, has_chunked_req=False, truncation_align_size=None, *args, **kwargs):
        self._suwen_chunked_inflight = bool(has_chunked_req)
        try:
            return original_add(self, req, has_chunked_req, truncation_align_size, *args, **kwargs)
        finally:
            self._suwen_chunked_inflight = False

    def _select_prefill_admission(self, req, *args, **kwargs):
        admission = original_select(self, req, *args, **kwargs)
        if (getattr(self, '_suwen_chunked_inflight', False)
                and isinstance(admission, admission_cls) and admission.is_chunked):
            refused[0] += 1
            if refused[0] <= 3 or refused[0] % 200 == 0:
                _say(f'SUWEN fix: second chunked request deferred while one is in flight '
                     f'(count={refused[0]})')
            return other
        return admission

    cls.add_one_req = add_one_req
    cls._select_prefill_admission = _select_prefill_admission
    cls._suwen_chunked_serialize = True
    _say('SUWEN fix installed: chunked serialize (a second chunked request waits; '
         'requests that fit still join the batch)')


# ─── 2. SSE keepalive ────────────────────────────────────────────────────────

def keepalive_stream(first_chunk_stream, grace_s, every_s, error_line):
    """首块未到时先发 SSE 注释，首块到后原样转发。

    grace 窗口内的 ValueError 原样抛出，调用方仍回 400；注释发出后再出错就改成 SSE 错误事件，
    与 SGLang 流中途报错的做法一致。
    """
    async def run():
        gen = first_chunk_stream
        first = asyncio.ensure_future(gen.__anext__())
        sent = False
        try:
            done, _ = await asyncio.wait({first}, timeout=grace_s)
            while not done:
                sent = True
                yield KEEPALIVE_LINE
                done, _ = await asyncio.wait({first}, timeout=every_s)
            try:
                chunk = first.result()
            except StopAsyncIteration:
                return
            except ValueError as exc:
                if not sent:
                    raise
                yield error_line(str(exc))
                yield 'data: [DONE]\n\n'
                return
            yield chunk
            async for chunk in gen:
                yield chunk
        finally:
            if not first.done():
                first.cancel()
                try:
                    await first
                except BaseException:
                    pass
            await gen.aclose()

    return run()


def install_stream_keepalive(module):
    every = float(os.environ.get('DSV41_SSE_KEEPALIVE_EVERY_S', '30'))
    grace = float(os.environ.get('DSV41_SSE_KEEPALIVE_GRACE_S', '5'))
    if every <= 0:
        _say('SUWEN fix: SSE keepalive off (DSV41_SSE_KEEPALIVE_EVERY_S<=0)')
        return
    cls = getattr(module, 'OpenAIServingChat', None)
    if cls is None or not hasattr(cls, '_generate_chat_stream'):
        raise RuntimeError('OpenAIServingChat._generate_chat_stream not found')
    if getattr(cls, '_suwen_keepalive', False):
        return
    original = cls._generate_chat_stream

    def _generate_chat_stream(self, adapted_request, request, raw_request):
        return keepalive_stream(
            original(self, adapted_request, request, raw_request), grace, every,
            lambda msg: f'data: {self.create_streaming_error_response(msg)}\n\n')

    cls._generate_chat_stream = _generate_chat_stream
    cls._suwen_keepalive = True
    _say(f'SUWEN fix installed: SSE keepalive (first comment after {grace:.0f}s, '
         f'then every {every:.0f}s until the first chunk)')


# ─── 查找器 ──────────────────────────────────────────────────────────────────

_HOOKS = {
    'sglang.srt.managers.schedule_policy': install_chunked_serialize,
    'sglang.srt.entrypoints.openai.serving_chat': install_stream_keepalive,
}


class _Loader(importlib.abc.Loader):
    def __init__(self, inner, hook):
        self.inner = inner
        self.hook = hook

    def create_module(self, spec):
        return self.inner.create_module(spec)

    def exec_module(self, module):
        self.inner.exec_module(module)
        try:
            self.hook(module)
        except Exception as exc:
            _say(f'SUWEN fix NOT installed for {module.__name__}: {exc!r}')


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        hook = _HOOKS.get(fullname)
        if hook is None:
            return None
        spec = None
        for finder in sys.meta_path:
            if finder is self:
                continue
            find = getattr(finder, 'find_spec', None)
            if find is None:
                continue
            spec = find(fullname, path, target)
            if spec is not None:
                break
        if spec is None or spec.loader is None:
            return spec
        spec.loader = _Loader(spec.loader, hook)
        return spec


def install_finder():
    if any(isinstance(f, _Finder) for f in sys.meta_path):
        return
    for name, hook in _HOOKS.items():
        if name in sys.modules:
            hook(sys.modules[name])
    sys.meta_path.insert(0, _Finder())
