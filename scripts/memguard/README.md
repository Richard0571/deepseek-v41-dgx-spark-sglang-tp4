# 宿主内存哨兵

DGX Spark 是统一内存。推理把页推满时会出现 **wedge**：ping 通、TCP 22 接受、**SSH banner 永不完成**。没有 BMC，只能等自愈或物理断电。

哨兵在触顶前 `docker kill` 掉推理容器，把 wedge 变成可恢复的容器死亡。

## 安装

把本目录四个脚本拷到每台 `/home/cq/`（文件名保持 `memguard.sh`、`v41-mg-phase.sh`、`v41-mg-load.sh`、`v41-kill-all.sh`）。起服前：

```bash
/home/cq/v41-mg-phase.sh start
/home/cq/v41-mg-phase.sh status
```

相位终态留 **load**。`switch` 到 steady 默认拒绝（须显式环境变量，见脚本）。

## 硬约束

| 项 | 值 |
|---|---|
| `vm.min_free_kbytes` | **1048576**（约 1 GiB），写入 `/etc/sysctl.d/` |
| `vm.watermark_scale_factor` | **200** |
| 绝对下限 | **1024 MB** `MemAvailable`，不得放宽 |
| PSI | 只走合取：`avail<16384` **且** `psi>50`。不要 PSI 单腿开火 |

**禁止** `memguard.sh start … 5.0 60.0`（曾误杀整集群）。

容器名须与 `.env.tp4` 里一致（本机历史名 `vllm_dsv41`）。`v41-kill-all.sh` 清四台，避免 head 死、worker 活。

同一批节点同一时刻只允许一个编排者：起服前写 claim，结束删 claim，并清 hold 文件（见 `v41-kill-all.sh` 调用关系）。
