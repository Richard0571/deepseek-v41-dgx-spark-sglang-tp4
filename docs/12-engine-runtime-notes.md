# 12 · 运行时

## 栈

SGLang + knapcio adapter：RoCEnante all-reduce / all-gather，`b12x_next` MoE（EP1），DSpark 投机 k=5，Engram 行在 NVMe。

## 调度

- 切块 4096。第二路大切块会被本机补丁挡住，短请求仍可进批。
- PDI=1：prefill 块与 decode 步交错，多路时单路 tok/s 会掉，但不该停。
- `SPARK_PREFILL_TP_MIN_ROWS` 低于 1024 会直接 raise（上游）；不要把切块改到非法区。

## 客户端

长上下文客户端（DSH 等）常在约 0.8×contextWindow 压缩。引擎总长必须 ≥ 客户端窗 + 最大输出，否则压缩前就会顶格。

## 历史 vLLM 备注

09-14 公开库写过 `--kv-cache-memory-bytes` 旁路 `--gpu-memory-utilization`。那是 **vLLM** 行为。现役是 SGLang 的 `MEM_FRACTION_STATIC` + `MAX_TOTAL_TOKENS`，不要把旧 GMU 结论套过来。
