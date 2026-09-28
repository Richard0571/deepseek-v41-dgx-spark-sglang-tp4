# 08 · 验收

## 1. 口活着

```bash
curl -sS http://<head>:8001/v1/models
```

应看到模型 id，且 `max_model_len`（或等价字段）为 **600000**。

## 2. 日志必有行（本机 2026-09-29）

在 head / 各 rank 日志里核：

- `context_length=600000`（或 `context_len=600000`）
- `max_running_requests=4`，`cuda_graph_max_bs_decode=4`
- `prefill_decode_interval=1`
- `image_processor_backend=pil`
- `max_total_num_tokens` 在约 **2.15M–2.50M**（随 boot 内存变）
- `omitted max_tokens defaults and caps at 100000`
- `SUWEN fix installed: chunked serialize`（每 rank）
- 头节点 `SSE keepalive`
- `RoCEnante ready: world=4`
- `[spec_sync_free] armed (all)`
- `Initialized DSpark draft runner` 且 `gamma=5`

## 3. 直连：长 prefill 不饿死旁路

一路短 `ignore_eos` 出字，数秒后另一路丢 30 万级随机前缀。旁路 decode 间隔应在 **数秒内**（本机最长 1.77 s），不应再出现 100 s+ 完全无 chunk。

## 4. 多路客户端（本机 DSH，A）

| 项 | 结果 |
|---|---|
| 路数 | 4 |
| 回合 | 39 |
| 失败 / 超时 / 容器重启 | 0 |
| 每路至少一次自动压缩 | 是（压力约 33.5–35 万后回落） |
| 冷 prefill | 10 次，约 19.4–34.0 万 token，TTFT 43–128 s |
| 出字中位 | 29.2 tok/s（含思考；最低 14.8） |
| 四台最低 MemAvailable | 9697 / 11094 / 10429 / 10082 MB |

压缩判据不要用「decode 步数 ≥2」：短文也会过。应用「压力先到 ≥25 万再回落 ≥6 万」。

## 5. 哨兵

测试全程最低 avail 远高于 1024。若你的数字贴近 1024，先降 KV 或并发，不要关哨兵。
