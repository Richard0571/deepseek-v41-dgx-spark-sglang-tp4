# 第三方归属

本手册描述的运行时主要来自：

- [knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4) v2.2 `e9ec61d2`
- [MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks)（启动器族上游）
- [sgl-project/sglang](https://github.com/sgl-project/sglang) / `lmsysorg/sglang:dev-dsv41`

`scripts/suwen_fixes.py` 只在 import 时打补丁，不修改上游 git 树里的源文件（`apply-suwen-fixes.sh` 会改你 checkout 里的 `adapter/sitecustomize.py` 与 `.env.tp4`）。

历史 vLLM 路径曾引用 [tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark](https://github.com/tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark) 与 [josephdrose/joe-spark-patches](https://github.com/josephdrose/joe-spark-patches)。那些文件已不在默认树里。
