# 04 · 上游仓库与本机修复

**这篇讲什么**：克隆哪一棵树、镜像怎么建、本仓库补丁装在哪。

---

## 1. 钉提交

```text
https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4
commit e9ec61d2   # v2.2，2026-09-25
```

Mia 仓库在 09-25 合并了 knapcio TP4 线之后主要改 README。本机不跟 Mia 的 TP3 切块默认（768）；TP4 prefill SP 要求切块 ≥2048，上游 TP4 默认 4096。

## 2. 克隆注意

- `core.autocrlf=false`，否则 `start.sh` 变 CRLF，bash 报「无效的选项名」。
- 浅克隆可能没有 `runtime/sglang-canary` 完整树。`Dockerfile.canary-roce` 需要 `COPY runtime/sglang-canary/python`。缺了就从已有同版本目录拷，或按上游说明拉 canary。
- 本机 canary 树记录为 `f80c91a4b`（与当时 checkout 一致）。

## 3. 构建

```bash
cd /home/cq/dsv41-4x-spark
# .env.tp4 里 BUILD_DOCKERFILE=Dockerfile.canary-roce
./start-tp4.sh build    # 四台各建；tag 用 IMAGE=
```

基础镜像 `lmsysorg/sglang:dev-dsv41` 本机已有时不要再经代理拉。

镜像一致性看 **`RootFS.Layers` digest**，不要只看 `docker images` 的短 ID（containerd 节点的 Id/Size 口径不同）。

## 4. 本机修复装法

```bash
bash scripts/apply-suwen-fixes.sh scripts/suwen_fixes.py /home/cq/dsv41-4x-spark
```

效果：

- 写入 `adapter/suwen_fixes.py`
- 在 `adapter/sitecustomize.py` 的 EngramFinder 之后插入 `suwen_fixes.install_finder()`
- `.env.tp4`：`IMAGE=dsv41-4x-spark:v22-roce-sw1`、`MAX_RUNNING_REQUESTS=4`，并确保 `EXTRA_SGLANG_ARGS` 含 `--prefill-decode-interval 1` 与 `--image-processor-backend pil`

改完再 `./start-tp4.sh build`，让镜像吃到 `adapter/`。

关闭补丁：`SUWEN_SERIALIZE_CHUNKED=0`；`DSV41_SSE_KEEPALIVE_EVERY_S=0`。

## 5. 不要复建的东西

自制 vLLM boot（`v41x-boot.sh` / `v41-recipe` / 按旧会话抄的 KVB argv）**不是**本手册路径。09-14 公开库里的 Tony 补丁仅作历史。
