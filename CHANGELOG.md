# Changelog

## 2026-09-29 — 整包换成 knapcio v2.2

- 现役引擎：**SGLang**（knapcio `e9ec61d2`），不再是 vLLM `aidendle94/sparkrun-vllm-dsv41-gb10`。
- 窗：**600000 总长**；客户端示例 500000 / 100000。
- 并发 **4**，KV 钉 **2500000**（0.80 比例封顶，实测池约 2.15M–2.50M）。
- 增加本机修复：PDI=1、切块串行、SSE keepalive。
- 删除默认路径上的 `scripts/v41-tuned-tp4.sh` 与 `patch/`（Tony 七补丁）。需要旧配方请翻本仓 2026-09-14 提交。

## 2026-09-14 — vLLM 第一方配方（已归档）

Tony 七补丁 + joe mp 组法 + vLLM official recipe。窗 720896。见该日提交。
