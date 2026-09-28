# 06 · 参数与依据

**接线原则**：argv 里有 ≠ 代码读了 ≠ 当前配置会执行。下面只写本部署验证过的。

| 键 / 参数 | 本机值 | 依据 |
|---|---|---|
| `CONTEXT_LENGTH` | 600000 | SGLang `--context-length` 是**总长**。客户端 500k+100k 必须写成 600k，写成 500k 会在长输出截断。 |
| `DSV41_MAX_NEW_TOKENS` | 100000 | 须进入容器（`start.sh` 的 `-e` 名单或 `EXTRA_CONTAINER_ENV`）。只写在 `.env` 而未进容器则无效。日志应有 `caps at 100000`。 |
| `MAX_RUNNING_REQUESTS` | 4 | 与 CUDA graph decode bs 对齐。本机从 6 改 4，减轻长 prefill 互抢。 |
| `MAX_TOTAL_TOKENS` | 2500000 | 给内存留余量。0.80 静态预算可能把池压到约 2.15M（随起服时空闲变）。钉值高于比例上限时，日志 `max_total_num_tokens` 以比例为准。 |
| `MEM_FRACTION_STATIC` | 0.80 | 上游默认。当 KV 已被钉在比例之下时，再拧这个数**不改变**已钉池（09-28 实测 0.90→0.85 只差池缩小那一截）。 |
| `CHUNKED_PREFILL_SIZE` | 4096 | 上游 TP4 默认。不要抄 Mia TP3 的 768。 |
| `DSV41_CACHE_GIB` | 4 | 上游默认。 |
| `--image-processor-backend pil` | 开 | 09-26 / 09-29：不加则 worker 卡 `cargo --version --verbose` 5–9 分钟。 |
| `--prefill-decode-interval 1` | 开 | 每块 prefill 后插 1 步 decode。消费点在 SGLang 调度器；本配置会执行。 |
| `DSV41_FAST_LOAD_*` | 1 GB / 2 线程 | 只作用于加载，防装权把统一内存推顶。 |
| `SGLANG_ENABLE_TP_MEMORY_INBALANCE_CHECK=0` | 开 | 只关一项启动检查。 |
| v2.2 开关 | 模板原样 | `L2_PREFETCH_WOA` / `SPEC_SYNC_FREE=all` / `EAGER_GLUE=all` / `SPLIT_COMPACT_GATHER=1`。日志应有 `[spec_sync_free] armed`、`RoCEnante ready: world=4`、DSpark `gamma=5`。 |

## 明确不要抄回的旧数

`MAX_TOTAL_TOKENS=3500000` / 并发 5 或 6 / 窗 1048576 / 988576 / 4250000 / `MEM_FRACTION_STATIC=0.85` 当「还能再挤」——那些是另一套实验，09-28 已证明 KV 用过不还。

## 容量（C）

`2502144 × 1670.75 B ≈ 4.18×10⁹ B ≈ 4.18 GB/台` 满池写入。  
knapcio 默认 8000000 ≈ 13.4 GB/台（同一字节/token 假设）。
