# 09 · 回滚

## 回 knapcio 上一棵树

1. `./start-tp4.sh` 停服（或四台 `docker rm -f` 你的容器名）。
2. 保留当前目录：`mv /home/cq/dsv41-4x-spark /home/cq/dsv41-4x-spark.bak-$(date +%Y%m%d)`
3. 换回旧 checkout / 旧镜像 tag，`.env.tp4` 一并换回。
4. 头节点若有 `state-tp4`，跟着目录走；**worker 常常没有这个目录**，切换脚本不要假定四台都有。
5. 哨兵仍盯同一容器名则不用改；改了容器名就要改哨兵参数。

本机 09-29 曾把旧树归档为 `dsv41-4x-spark.pre-v22-20260929`，镜像 `dsv41-4x-spark:canary-roce` 留作回滚。

## 回 09-14 vLLM

翻本仓库提交 `880fefe`：`scripts/v41-tuned-tp4.sh` + `patch/`。那是另一套镜像与 argv，**不能**和 knapcio 容器混在同一台抢 121 GB。

## 修坏了 sitecustomize

`git checkout -- adapter/sitecustomize.py` 后重新跑 `apply-suwen-fixes.sh`。
