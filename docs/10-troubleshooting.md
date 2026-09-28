# 10 · 踩坑表

| 现象 | 原因 | 处理 |
|---|---|---|
| worker 装权卡 5–9 分钟，`cargo --version --verbose` | 镜像默认探 rustc/cargo | `--image-processor-backend pil` |
| `docker run` requires at least 1 argument，下一行 `-e: 未找到命令` | `\` 续行后插了 `#` 注释，把续行符吃掉 | 注释写在整条命令外；用 dry-run 看拼好的行 |
| 四台突然全退，Exit 247，`assert chunked_req is None` | 两路切块重叠 | 确认 `suwen_fixes` 已装；`SUWEN_SERIALIZE_CHUNKED` 未关 |
| 一路长 prefill，其它路数分钟不出字 | 默认 PDI=0 | `--prefill-decode-interval 1` |
| 客户端 300 s 后静默失败，引擎还在算 | 首 token 前无 HTTP 体 | SSE keepalive；或换不等 300 s 的客户端 |
| `MAX_TOTAL_TOKENS=3000000` 日志却是 2502144 | 0.80 比例封顶 | 钉值改成与日志一致，或接受封顶 |
| `DSV41_*` 写在 env 但容器里没有 | 没进 `EXTRA_CONTAINER_ENV` / `start.sh` `-e` | 查 `docker inspect` Env |
| Windows 克隆后 `set -o pipefail` 无效 | CRLF | 重新 `autocrlf=false` 克隆 |
| 三台互通一台不通 | RoCE 表把 02/03 写反 | 见 docs/01 |
| SSH banner 超时、ping 通 | wedge | 停手、不轮询、等自愈或断电；查哨兵是否在岗 |
| build 缺 `runtime/sglang-canary/python` | 浅克隆不完整 | 拷同版本 canary 树 |
| 切换目录脚本在 worker 失败 | 假定每台都有 `state-tp4` | 只在目录存在时 mv |
| 镜像 ID 四台看起来不一样 | containerd vs overlay 显示口径 | 比 `RootFS.Layers` |
| `MemAvailable` 锯齿、anon 平 | 有人在扫大目录 | 停递归读 |

旧 vLLM 事故（仅档案）：未 Engram-on-disk 起 TP4 → spark-03 wedge；`docker --memory` 无效。
