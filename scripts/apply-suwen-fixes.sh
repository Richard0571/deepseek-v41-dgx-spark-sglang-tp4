#!/usr/bin/env bash
# 在 knapcio v2.2 checkout 上装本机修复并改 .env.tp4（不起服、不建镜像）。
# 用法：bash apply-suwen-fixes.sh /path/to/suwen_fixes.py [/path/to/dsv41-4x-spark]
# 幂等：重复执行不会重复插入。
set -euo pipefail
FIX_SRC="${1:?path to suwen_fixes.py}"
ROOT="${2:-/home/cq/dsv41-4x-spark}"
cd "$ROOT"

install -m 0644 "$FIX_SRC" adapter/suwen_fixes.py

python3 - <<'PY'
from pathlib import Path
p = Path('adapter/sitecustomize.py')
t = p.read_text()
anchor = "if os.environ.get('DSV41_SOURCE'):\n    sys.meta_path.insert(0, EngramFinder())\n"
block = (
    "\n# 本机修复（adapter/suwen_fixes.py）：第二路切块串行 + SSE keepalive。\n"
    "# 必须在 tp3_pad 导入任何 sglang 模块之前装上查找器。\n"
    "if os.environ.get('DSV41_SOURCE'):\n"
    "    try:\n"
    "        import suwen_fixes\n"
    "        suwen_fixes.install_finder()\n"
    "    except Exception as exc:\n"
    "        print(f'SUWEN fixes not installed: {exc!r}', flush=True)\n"
)
if 'import suwen_fixes' in t:
    print('sitecustomize: already patched')
else:
    assert t.count(anchor) == 1, 'anchor not unique'
    p.write_text(t.replace(anchor, anchor + block, 1))
    print('sitecustomize: patched')
PY
python3 -c "import ast; ast.parse(open('adapter/sitecustomize.py').read()); ast.parse(open('adapter/suwen_fixes.py').read()); print('ast ok')"

python3 - <<'PY'
import re
from pathlib import Path
p = Path('.env.tp4')
t = p.read_text()
def setk(t, k, v):
    pat = re.compile(rf'^{k}=.*$', re.M)
    hits = pat.findall(t)
    if len(hits) != 1:
        raise SystemExit(f'expected exactly one {k}= line, got {len(hits)}')
    return pat.sub(f'{k}={v}', t, count=1)
t = setk(t, 'IMAGE', 'dsv41-4x-spark:v22-roce-sw1')
t = setk(t, 'MAX_RUNNING_REQUESTS', '4')
m = re.search(r'^EXTRA_SGLANG_ARGS="(.*)"$', t, re.M)
if not m:
    raise SystemExit('EXTRA_SGLANG_ARGS="..." not found')
args = m.group(1)
if '--prefill-decode-interval' not in args:
    args += ' --prefill-decode-interval 1'
if '--image-processor-backend' not in args:
    args += ' --image-processor-backend pil'
t = setk(t, 'EXTRA_SGLANG_ARGS', f'"{args}"')
p.write_text(t)
PY
grep -nE '^(IMAGE|MAX_RUNNING_REQUESTS|MAX_TOTAL_TOKENS|CONTEXT_LENGTH|DSV41_MAX_NEW_TOKENS|EXTRA_SGLANG_ARGS)=' .env.tp4
