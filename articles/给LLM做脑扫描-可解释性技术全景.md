---
title: "给大语言模型做『脑扫描』——LLM 可解释性技术全景"
source: "对话沉淀（内部 session）"
source_urls:
  - "https://transformer-circuits.pub/2024/scaling-monosemanticity/"
  - "https://transformer-circuits.pub/2025/attribution-graphs/biology.html"
  - "https://github.com/TransformerLensOrg/TransformerLens"
  - "https://www.neuronpedia.org/"
authors: "对话整理"
date: "2026-07-06"
fetched_at: "2026-07-06"
tags: ["可解释性", "interpretability", "机制可解释性", "LLM", "残差流", "SAE", "logit-lens", "activation-patching", "attribution-graph", "TransformerLens"]
---

# 给大语言模型做『脑扫描』——LLM 可解释性技术全景

> 用户问「怎么给模型做 CT / 核磁 / 三维扫描」——这在 AI 里就是**可解释性 (interpretability)**。
> 本文把医学扫描的三个类比，映射到真实的 LLM 可解释性技术，并给出从「当天出图」到「复现 Claude 脑扫描」的分层上手路径。

---

## 摘要

给 LLM「做扫描」= 打开黑盒看它内部在算什么。核心难点由 LLM 两个结构特性决定：**残差流 (residual stream)** 是贯穿所有层的信息主干（决定了「逐层切片」这一 CT 式方法天然成立），**叠加 (superposition)** 让单个神经元多义纠缠（决定了必须先用 SAE 拆成单义特征才读得懂）。此外，**只有开放权重模型能真扫**——闭源模型（GPT-4、Claude API）拿不到内部激活，只能做行为探测。

三个类比精准对应三类技术：**核磁/亮区** → 注意力·神经元·SAE 特征激活（哪里亮）；**CT 断层** → logit lens / 逐层探针（每层在算什么）；**三维/结构** → 电路与归因图（计算通路的立体形状）。技术栈从浅到深四层：注意力+logit lens（当天出图）→ 因果干预 activation patching（定位能力）→ SAE 特征扫描（读懂概念）→ 归因图/电路追踪（Anthropic 2025 前沿，最接近全脑扫描）。

---

## 一、LLM 特殊在哪（决定了怎么扫）

### 1.1 残差流是信息主干

Transformer 里每个 token 位置有一条贯穿所有层的「信息高速公路」——**残差流**。每一层的注意力头和 MLP 从残差流里**读**、计算后再**写**回去。

> 扫描 LLM 的本质，就是在残差流的不同层位切片，看每层往里写进了什么。这天然就是「CT 逐层断层」。

### 1.2 叠加与多义性（Superposition）

一个神经元往往同时编码好几个不相关的概念（「猫」+「暖色调」+「Python 缩进」），这叫 **polysemanticity**。根因：概念数量远超维度数量，必然叠加压缩。

后果：**直接看单个神经元没用**，必须先用稀疏自编码器 (SAE) 把纠缠的激活升维+稀疏化，拆成成千上万个「单义特征」，才读得懂。参见 [[SAE-视觉特征单义性-NeurIPS2025]]、[[PatchSAE-概念重映射-ICLR2025]]。

### 1.3 只有开放权重才能真扫

| 模型类型 | 能做的扫描 |
|---|---|
| 闭源 API（GPT-4、Claude、Gemini） | 只能**行为探测**：系统性构造输入看输出，拿不到内部激活 |
| 开放权重（Llama / Gemma / GPT-2 / Qwen / Mistral） | 全套内部扫描：激活、注意力、SAE、电路追踪都能做 |

**结论：动手练习一律选开放权重模型。** 入门首选 GPT-2 small（小、快、文献最多）或 Gemma 2（有官方全套预训练 SAE）。

---

## 二、三类扫描的映射

| 你的说法 | 医学含义 | LLM 里对应技术 | 回答的问题 |
|---|---|---|---|
| **核磁 / fMRI** | 哪块区域亮了 | 注意力 / 神经元 / SAE 特征激活 | 这个 prompt 点亮了**哪些**头/神经元/特征 |
| **CT 断层** | 一层层横切 | logit lens / tuned lens / 逐层探针 | **每一层**在算什么、答案在第几层成型 |
| **三维扫描** | 整体立体结构 | 电路发现 / 归因图 | 计算通路的**立体形状** |

---

## 三、从浅到深的技术栈（附可直接用的库）

### 第 1 层：注意力 & logit lens（最快，当天出图）

- **circuitsvis**：交互式可视化每层每个注意力头的注意力模式，能直接看到 induction head（负责「复读/续写」的经典电路）。
- **Logit Lens / Tuned Lens**：把每一层的残差流乘 unembedding，直接投影到词表，看「模型在第几层就已经想好要输出哪个词」。几十行代码，是最像 CT 逐层扫描的东西。

### 第 2 层：因果干预（定位能力/事实存在哪）

- **激活修补 / 路径修补 (activation / path patching)**：把 A 输入在某层的激活，替换成 B 的激活，看输出如何变化，反推哪个组件真正负责某项计算。
  - 经典应用：定位 GPT 事实存储位置（**ROME**《Locating and Editing Factual Associations in GPT》）；IOI 电路（识别「把礼物送给谁」）。
- **主力库**：**TransformerLens**（Neel Nanda，机制可解释性事实标准）。模型太大跑不动 → **nnsight / NDIF**（在远程超大模型上做干预）。

### 第 3 层：SAE 特征扫描（读懂「模型在想什么概念」）

用稀疏自编码器把某层激活拆成单义特征，再看某个 prompt 点亮了哪些特征（如「金门大桥特征」「欺骗特征」「Python 代码特征」）。

- **零门槛入口**：
  - **Neuronpedia**——网页上直接浏览/搜索已提取好的 SAE 特征，输入一句话看点亮什么，完全不用训练。
  - **Gemma Scope**（Google DeepMind 开源）——给 Gemma 2 的全套预训练 SAE，配 **SAELens** 库，是目前**动手做 LLM 特征扫描最省事**的组合。
- **原理与因果验证**见 [[SAE-视觉特征单义性-NeurIPS2025]]（视觉版但方法通用）。

### 第 4 层：归因图 / 电路追踪（最接近「全脑扫描」，2025 前沿）

Anthropic 的最新路线，也是「给 Claude 做脑扫描」的字面实现：

- 用**跨层转码器 (cross-layer transcoder)** 把模型替换成可读特征，然后针对**单个具体 prompt** 画出**归因图 (attribution graph)**——一张「这句话是怎么被一步步算出来的」的电路流程图。
- 关键论文：《**Scaling Monosemanticity**》（2024，金门大桥 Claude）、《**On the Biology of a Large Language Model / Circuit Tracing**》（2025）。里面真的扫出了 Claude 怎么做多位数加法、写诗时**提前规划押韵词**、多语言共享同一套概念特征等。
- Anthropic 已将电路追踪工具**开源**，可在开放模型上复现。

---

## 四、上手路径（选一条）

| 目标 | 最短路径 |
|---|---|
| 当天看到逐层扫描图 | GPT-2 small + TransformerLens 跑 **logit lens** → 现成脚本 [`scripts/interp/logit_lens_gpt2.py`](../scripts/interp/logit_lens_gpt2.py) |
| 不写训练代码、只想看「点亮什么概念」 | 打开 **Neuronpedia** 网页，或 Gemma Scope + SAELens → 现成脚本 [`scripts/interp/gemma_scope_features.py`](../scripts/interp/gemma_scope_features.py) |
| 复现「给 Claude 做脑扫描」那种电路图 | Anthropic 开源的 circuit-tracing 工具 + 开放模型 → 现成脚本 [`scripts/interp/circuit_tracer_attribution.py`](../scripts/interp/circuit_tracer_attribution.py)（或零代码：Neuronpedia 在线生成） |

---

## 五、工具索引速查

| 工具 / 库 | 用途 | 层级 |
|---|---|---|
| Netron | 网络结构图（骨架 X 光） | 第 0 层 |
| circuitsvis | 注意力/激活交互可视化 | 第 1 层 |
| TransformerLens | 机制可解释性主力（logit lens、patching、电路） | 第 1–4 层 |
| nnsight / NDIF | 超大模型远程干预 | 第 2 层 |
| SAELens | 训练/加载 SAE | 第 3 层 |
| Gemma Scope | Gemma 2 官方预训练 SAE | 第 3 层 |
| Neuronpedia | 在线浏览 SAE 特征，免训练 | 第 3 层 |
| circuit-tracing (Anthropic) | 归因图 / 电路追踪 | 第 4 层 |

---

## 六、一句话总结

**给 LLM 做扫描 = 在残差流上切片（CT）+ 看特征点亮（核磁）+ 还原电路通路（三维）。**
浅层当天可出图（logit lens / Neuronpedia），深层是 Anthropic 正在做的前沿（归因图）。选开放权重模型、从 GPT-2 或 Gemma 2 起步。

---

## 相关文章

- [[SAE-视觉特征单义性-NeurIPS2025]] — SAE 拆解单义特征的原理与因果干预验证（视觉版，方法通用）
- [[PatchSAE-概念重映射-ICLR2025]] — SAE 概念重映射
- [[上下文工程-注意力预算与四层解法]] — 注意力机制视角下的 context 工程
