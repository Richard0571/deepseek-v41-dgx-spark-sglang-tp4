# DGX Spark ×4 · DeepSeek-V4.1-Flash · knapcio v2.2（SGLang TP4）

在 **4 台 NVIDIA DGX Spark（GB10）** 上，用 [knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4) **v2.2**（提交 `e9ec61d2`）起 **SGLang TP4 / EP1**，跑 DeepSeek-V4.1-Flash。

本仓库是 **0 到 1 的部署手册 + 本机补丁 + 内存哨兵**，不是上游启动器的复刻。启动器、镜像构建、RoCE / Engram / MoE 默认值都以 knapcio 仓库为准。

> **2026-09-29**：公开库从 2026-09-14 的 **vLLM 第一方配方**整包换成现役 **knapcio v2.2**。旧 `scripts/v41-tuned-tp4.sh` 与 `patch/`（Tony 七补丁）已从默认路径删除，历史提交里还能看到。

---

## 现役数字（本机 2026-09-29 起服日志，A 级）

| 项 | 值 |
|---|---|
| 入口 | `http://<head-mgmt>:8001/v1`（脚本只用 RoCE `HEAD_IP`） |
| 模型名 | `deepseek-v4.1-flash` |
| 上游代码 | knapcio `e9ec61d2`（v2.2，2026-09-25） |
| 基础镜像 | `lmsysorg/sglang:dev-dsv41`（本机构建未再拉；记录 digest `381b27ff`） |
| 本机构建 tag | `dsv41-4x-spark:v22-roce-sw1` |
| 引擎总长 | `CONTEXT_LENGTH=600000`（客户端常见拆法：prompt 500000 + 输出 100000） |
| 默认输出帽 | `DSV41_MAX_NEW_TOKENS=100000` |
| 并发 | `MAX_RUNNING_REQUESTS=4`（CUDA graph decode bs 1–4） |
| KV 钉值 | `MAX_TOTAL_TOKENS=2500000`；`MEM_FRACTION_STATIC=0.80` 会按起服时内存再封顶。本机两靴实测池 **2,149,120–2,502,144** |
| 切块 | 上游默认 `CHUNKED_PREFILL_SIZE=4096` |
| Engram 缓存 | 上游默认 `DSV41_CACHE_GIB=4` |
| 必须加的启动项 | `--image-processor-backend pil`；`--prefill-decode-interval 1` |
| 本机补丁 | 第二路切块串行 + SSE keepalive（`scripts/suwen_fixes.py`） |

满池写入量（C）：`2502144 × 1670.75 B ≈ 4.18 GB/台`。KV 按写入占宿主页、用过不还，**不要拿刚起服的 `MemAvailable` 当长期余量**。

---

## 配方从哪来

| 来源 | 用什么 |
|---|---|
| [knapcio v2.2](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4) | `start-tp4.sh` / `boot.py` / `.env.tp4.example` / `Dockerfile.canary-roce` / RoCEnante / v2.2 开关 |
| [MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks) | knapcio 的上游启动器族；Mia 已收 knapcio TP4 线。本机「融合」= 跟 knapcio v2.2，不另拼 Mia TP3 切块 |
| 本仓库 | 拓扑、护栏、哨兵、`.env` 覆盖项、三处缺陷修复、验收与踩坑 |

v2.2 生产行（knapcio CHANGELOG，B，作者 09-25 自测）：`DSV41_L2_PREFETCH_WOA=1`、`DSV41_SPEC_SYNC_FREE=all`、`DSV41_EAGER_GLUE=all`、`DSV41_SPLIT_COMPACT_GATHER=1`。不要为「再快一点」自行加大 `MAX_TOTAL_TOKENS` 到上游默认 800 万，除非你量过四台空闲余量。

---

## 0 到 1（按这个顺序）

```text
拓扑与免密 → 内核护栏 + 哨兵 → 权重四台本地齐 → 浅克隆 knapcio（LF）
→ 写 .env.tp4 → 装本仓库补丁 → 四台 build → serve → 验收
```

| 步 | 文档 |
|---|---|
| 1 拓扑、RoCE 口不要对错 | [`docs/01-hardware-topology.md`](docs/01-hardware-topology.md) |
| 2 护栏 + 哨兵 | [`docs/02-host-preparation.md`](docs/02-host-preparation.md)、[`docs/07-memory-safety.md`](docs/07-memory-safety.md) |
| 3 权重 / Engram 目录 | [`docs/03-model-preparation.md`](docs/03-model-preparation.md) |
| 4 上游 + 本机修复 | [`docs/04-upstream-and-fixes.md`](docs/04-upstream-and-fixes.md) |
| 5 起服前清单 | [`docs/05-preflight.md`](docs/05-preflight.md) |
| 6 每个旋钮为什么这样 | [`docs/06-launch-parameters.md`](docs/06-launch-parameters.md) |
| 7 验收 | [`docs/08-verification.md`](docs/08-verification.md) |
| 8 回滚 | [`docs/09-rollback.md`](docs/09-rollback.md) |
| 9 踩坑 | [`docs/10-troubleshooting.md`](docs/10-troubleshooting.md) |
| 10 怎么报数字 | [`docs/11-measurement-notes.md`](docs/11-measurement-notes.md) |
| 11 运行时现象 | [`docs/12-engine-runtime-notes.md`](docs/12-engine-runtime-notes.md) |
| 12 客户端窗（DSH 示例） | [`docs/13-client-window.md`](docs/13-client-window.md) |

最短命令链（head 上，路径按你的改）：

```bash
# 0. 护栏已写入 /etc/sysctl.d/ ；哨兵
sudo sysctl vm.min_free_kbytes vm.watermark_scale_factor
# 期望 1048576 与 200
/home/cq/v41-mg-phase.sh start

# 1. 克隆（必须 LF；Windows 工作机不要 core.autocrlf=true）
git -c core.autocrlf=false clone https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4.git /home/cq/dsv41-4x-spark
cd /home/cq/dsv41-4x-spark
git checkout e9ec61d2   # 钉死本手册验证过的提交

# 2. 环境：从上游模板拷，再叠本仓库 env/tp4.overlay.env.example
cp .env.tp4.example .env.tp4
# 编辑站点 IP / 权重路径 / SSH / 网卡名，再写入 overlay 里的键

# 3. 本机修复（幂等）
bash /path/to/this-repo/scripts/apply-suwen-fixes.sh /path/to/this-repo/scripts/suwen_fixes.py /home/cq/dsv41-4x-spark

# 4. 四台各 build 一次，再 serve
./start-tp4.sh build
./start-tp4.sh serve
```

`runtime/sglang-canary` 若浅克隆没有树：从你已有的同提交 canary 目录拷进去，或按 knapcio README 补全后再 `build`。缺源时 `Dockerfile.canary-roce` 的 `COPY runtime/sglang-canary/python` 会失败。

---

## 本机补的三处上游缺陷

1. **`--prefill-decode-interval 1`**：长冷 prefill 时别的路 decode 不再饿数分钟（09-28 实测空档曾到 601 s；打开后直连最长间隔 **1.77 s**）。
2. **切块串行**（`suwen_fixes.py`）：已有切块请求在飞时，第二条「也会被切块」的请求退回等待，避免 `assert self.chunked_req is None` 四台一起退（09-26 Exit 247）。
3. **SSE keepalive**：首 token 前先发 `: keepalive` 注释，避免部分 HTTP 客户端（含 Node undici）**300 s 无字节断流**。

单测（纯 CPU）：`python scripts/test_suwen_fixes.py`（11 例）。

---

## 4 路打满窗（DSH，2026-09-29，A）

官方 DeepSeek Harness 桌面，窗 500000，4 场同时往上堆到自动压缩再续跑。39 回合，0 次超时 / 0 次容器重启 / 引擎 0 条 traceback。冷 prefill 10 次（约 19–34 万 token），首字 43–128 s；同期其它路仍出字 14.8–20 tok/s。四台最低 `MemAvailable` 9697–11094 MB，哨兵未开火。细节见 [`docs/08-verification.md`](docs/08-verification.md)。

---

## 硬纪律

1. **单机先行**再上四台。
2. **无哨兵不起服**。绝对下限 **1024 MB** 不得放宽。禁止再挂 `memguard.sh start … 5.0 60.0`。
3. **算出装不下就不要起**。统一内存上 `docker --memory` 拦不住驱动代持页。
4. **跨 boot 数字不可直比**。同 boot、丢冷样本、重复 3 次报中位（[`docs/11`](docs/11-measurement-notes.md)）。
5. **改旋钮先证明接线**：`MEM_FRACTION_STATIC` 在 `MAX_TOTAL_TOKENS` 已钉死且低于比例上限时不决定池大小。

---

## License

本仓库文档与脚本：**MIT**（[`LICENSE`](LICENSE)）。  
knapcio / Mia / SGLang 本体遵循**各自仓库许可**（SGLang 系多为 AGPL）。你构建的镜像会带上上游代码，分发镜像前先读上游 LICENSE。

Tony 七补丁与 09-14 vLLM 脚本不再是现役路径。
