# LLM 可解释性动手脚本

配套文章：[../../articles/给LLM做脑扫描-可解释性技术全景.md](../../articles/给LLM做脑扫描-可解释性技术全景.md)

三个脚本一一对应文章里「三类扫描 / 三条上手路径」，难度和资源需求依次递增。

| 脚本 | 对应扫描 | 在做什么 | 资源 | 验证状态 |
|------|---------|---------|------|---------|
| [logit_lens_gpt2.py](./logit_lens_gpt2.py) | CT 断层 | 逐层残差流投影到词表，看答案第几层成型 | GPT-2，CPU 即可 | 语法通过，未实跑 |
| [gemma_scope_features.py](./gemma_scope_features.py) | 核磁/亮区 | SAE 拆出单义特征，看一句话点亮哪些概念 | Gemma-2-2b，门控+≈5GB | 语法通过，未实跑 |
| [circuit_tracer_attribution.py](./circuit_tracer_attribution.py) | 三维/全脑 | 归因图：一句话怎么被一步步算出来 | Gemma-2-2b，门控+GPU | 语法通过，未实跑 |

> ⚠️ 三个脚本均在无依赖环境下仅做了 `py_compile` 语法检查，**未在装齐依赖的环境实跑**。
> 首次运行前请按各脚本头部 docstring 装依赖（后两个还需 `huggingface-cli login` 并接受 Gemma 许可）。

## 建议顺序

1. **先跑 `logit_lens_gpt2.py`** —— 零门槛、CPU 可跑、几分钟出图，建立直觉。
2. 再上 **`gemma_scope_features.py`** —— 需登录 HF、显存/内存更高，但看到的是「概念级」特征。
3. **`circuit_tracer_attribution.py`** 最重 —— 需 GPU；想省事可先用零代码替代：
   直接在 <https://www.neuronpedia.org/gemma-2-2b> 在线生成归因图。

## 通用依赖速查

```bash
# 路径一
pip install transformer_lens torch
# 路径二
pip install sae-lens transformer-lens torch && huggingface-cli login
# 路径三
pip install circuit-tracer && huggingface-cli login
```
