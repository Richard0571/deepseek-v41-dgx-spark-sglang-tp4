# 03 · 权重与磁盘

**这篇讲什么**：模型文件放哪、Engram 为什么必须在 NVMe、要不要 NFS。

---

## 1. 权重

每台本地一份完整 checkpoint（不要只给 head）。路径写进 `.env.tp4` 的模型目录变量（knapcio 模板字段名以你 checkout 为准）。

本机用的是 **UNCENSORED** 变体，路径示例：`/home/cq/models/DeepSeek-V4.1-Flash-UNCENSORED`。官方权同样可以，改路径即可。

核：`ls …/*.safetensors | wc -l` 四台一致。

从 Hugging Face 拉权：走局域网或直连，**禁止**用订阅代理下大于 5 GB 的合计流量。

## 2. Engram

v2.2 把 Engram 行存放到 NVMe，宿主缓存默认 **`DSV41_CACHE_GIB=4`**。目录（`ENGRAM_DIR`）四台本地、可写、不要指到快满的盘。

`NFS_SHARE=0`：四台各有完整分片时不必 NFS。

## 3. 空间

每台至少留下：权重 + Engram 表 + Docker 镜像层 + 日志 + **数 GB 空闲给 KV 写入**。KV 池按写入占页，满池约 4 GB/台量级（C，按 250 万 token × 约 1670 B）。

## 4. 不要做的

- 不要假设 `docker --memory` 能在统一内存上挡住 OOM / wedge。
- 不要在 `/home/cq` 上对含 `models/` 的树做 `grep -r` / `find` 全扫（会灌满页缓存、误触发哨兵）。
