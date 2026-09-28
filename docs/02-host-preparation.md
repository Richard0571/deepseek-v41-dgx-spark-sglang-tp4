# 02 · 宿主准备

**这篇讲什么**：四台都要做齐的内核护栏、Docker、SSH、哨兵。缺一项不要 `serve`。

---

## 1. 内核护栏（每台，root）

写入 `/etc/sysctl.d/99-dsv41-guard.conf` 后 `sysctl --system`：

```
vm.min_free_kbytes = 1048576
vm.watermark_scale_factor = 200
```

核对：

```bash
sysctl vm.min_free_kbytes vm.watermark_scale_factor
```

默认 `min_free` 只有约 44 MiB，是 wedge 主因之一。

## 2. Docker 与用户

- 每台已装 Docker，推理用户（示例 `cq`）在 `docker` 组。
- 四台都能 `docker image ls` 看到同一套基础镜像或准备 pull `lmsysorg/sglang:dev-dsv41`。
- **大文件不要走家庭套餐代理**（单次合计 >5 GB）。权重与基础镜像走局域网或直连。

## 3. SSH

- 工作机 → 四台：NVIDIA Sync 的 `spark-01`…`spark-04`。
- 节点之间：`ssh -o BatchMode=yes 10.100.24.x`，免密。
- knapcio `start-tp4.sh` 会从 head ssh 到 worker 起容器。

脚本与 `.env` **必须是 LF**。从 Windows 克隆时：`git -c core.autocrlf=false clone`。

## 4. 哨兵

见 [`scripts/memguard/README.md`](../scripts/memguard/README.md)。起服前：

```bash
/home/cq/v41-mg-phase.sh start
```

`ps` 里应有 `v41-mg-load.sh` / `memguard.sh` 在盯容器名。

## 5. 独占

同一批节点不要两个编排者同时 `docker rm` / 改相位。起服前看有没有别人的 boot / bench，写 claim，结束释放。

## 6. 时钟（可选，本机现状）

本机四台 GPU 锁 **300–2200 MHz**（`nvidia-smi -lgc`）。未评估过你的散热前不要照抄。
