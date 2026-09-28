# 05 · 起服前清单

全部勾上再 `./start-tp4.sh serve`。

## 物理与网

- [ ] [`docs/01`](01-hardware-topology.md) 第 7 节
- [ ] 节点间 `BatchMode` SSH 通三台 worker
- [ ] `.env.tp4` 里 RoCE IP **02→.3、03→.1**

## 宿主

- [ ] `sysctl` 两项护栏
- [ ] `v41-mg-phase.sh status` 在岗，ABS ≥1024
- [ ] 没有第二个编排者在 `docker rm` / 改相位
- [ ] 脚本与 env 无 CR（`grep -l $'\r' start.sh .env.tp4` 应无输出）

## 软件

- [ ] 四台权重与 Engram 目录可写
- [ ] `git rev-parse HEAD` = `e9ec61d2`（或你有意换的提交，并自己重验）
- [ ] `adapter/suwen_fixes.py` 存在，`sitecustomize.py` 含 `import suwen_fixes`
- [ ] `EXTRA_SGLANG_ARGS` 含 `pil` 与 `--prefill-decode-interval 1`
- [ ] `CONTEXT_LENGTH=600000`、`MAX_RUNNING_REQUESTS=4`、`MAX_TOTAL_TOKENS=2500000`
- [ ] 镜像已在四台 build 完成

## 干跑

knapcio 脚本若提供 `dry-run` / 打印 `docker run`，看生成结果里：

- 有镜像名
- 有 `-e` 输出帽 / 上下文
- **续行中间没有 `#` 注释**（`\` 后面一行若以 `#` 开头会切断整条 `docker run`）

## 单机先行

第一次换镜像或换大旋钮：先一台（或先确认 worker 不会卡 `cargo --version`），再四台。
