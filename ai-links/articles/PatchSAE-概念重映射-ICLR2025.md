---
title: "PatchSAE 概念重映射——ICLR 2025"
aliases: [PatchSAE, 概念重映射, SAE ICLR 2025]
tags: [ai/learning, reference]
created: 2024-12-06
updated: 2026-08-17
status: stable
source: "论文"
source_url: "https://arxiv.org/abs/2412.05276"
authors: "Hyesu Lim, Jinho Choi, Jaegul Choo, Steffen Schneider"
venue: "ICLR 2025"
date: "2024-12-06"
fetched_at: "2026-06-17"
---

# PatchSAE：Adaptation 不学新概念，只重映射旧概念——ICLR 2025 论文精读

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[SAE-视觉特征单义性-NeurIPS2025]] | [[给LLM做脑扫描-可解释性技术全景]] | [[AI大模型开发]]

> Sparse autoencoders reveal selective remapping of visual concepts during adaptation
> Hyesu Lim et al. · ICLR 2025 · [github.com/dynamical-inference/patchsae](https://github.com/dynamical-inference/patchsae)

**角色定位**：把 SAE 当作分析仪器，回答「adaptation 到底改了什么」——而不是把 SAE 本身当作研究对象。

---

## 一、和 NeurIPS 2025 (Pach et al.) 的关键差异

两篇都在 CLIP 视觉编码器上训 SAE，但挂载位置和核心问题完全不同：

| 维度 | NeurIPS 2025 (Pach et al.) | PatchSAE (Lim et al.) |
|------|---------------------------|----------------------|
| **SAE 输入** | CLS token（全局汇总向量） | **所有 token**（CLS + 577 patch tokens） |
| **空间定位** | 只知道「图里有狗」 | 知道「狗在第 3 行第 5 列 patch 上」 |
| **核心问题** | SAE 特征是不是单义的？能因果控制输出吗？ | Adaptation 时内部发生了什么？学新概念还是重用旧概念？ |
| **方法论贡献** | MS 指标 + MTurk 人类实验 + 因果干预 | 空间归因 + latent masking 消融 + adaptation 机制分析 |
| **实验下游** | LLaVA（多模态对话生成） | MaPLe prompt adaptation（few-shot 图像分类） |
| **SAE 角色** | **研究对象**（验证 SAE 本身靠不靠谱） | **分析仪器**（用 SAE 去研究另一个问题） |

---

## 二、PatchSAE 架构

### 2.1 核心设计：对所有 token 训 SAE

```
CLIP ViT 残差流输出 z ∈ ℝ^(N+1)×d  (N=577 patches + 1 CLS token, d=1024)
  → 逐 token 独立过 SAE
  → 每个 token 得到稀疏激活向量
  → 每个 SAE latent 同时有语义含义 + 空间位置信息
```

本质仍是标准 SAE：线性编码器 → ReLU → 线性解码器，L1 稀疏惩罚。唯一的架构差异是**输入是所有 token 而非仅 CLS**——这个简单的改变解锁了空间定位能力。

### 2.2 训练配置

| 项目 | 设置 |
|------|------|
| 基底模型 | CLIP ViT-L/14（frozen） |
| 钩子层 | ViT 中间层 attention block 残差流输出 |
| 训练数据 | ImageNet 训练集 |
| 稀疏策略 | L1 正则化 |
| 损失函数 | MSE (重建) + λ·L1 (稀疏) |

### 2.3 四级分析粒度

| 粒度 | 定义 | 能回答什么 |
|------|------|-----------|
| **Token 级** | 单张图上单个 SAE latent 的 patch 激活分布 | 「这个概念在图片的哪个位置？」 |
| **图像级** | 汇总全图所有 token 的 latent 激活 | 「哪些参考图片最能激活这个概念？」 |
| **类级** | 对某个类的所有图片取平均激活 | 「分类 '斑马' 主要依赖哪些概念？」 |
| **任务级** | 跨数据集比较概念使用模式 | 「adapt 前后用的是同一组概念吗？」 |

---

## 三、关键发现 1：多粒度可定位概念

**多粒度**：同一个 SAE 同时拆出——
- 低层属性：颜色、纹理、形状
- 中层部件：轮子、窗户、腿
- 高层语义：物体类别、场景类型

**可定位**：激活 patch 能准确圈出概念在图片中的物理位置——不是全局模糊判断，是精确到 3×4 个 patch 的空间映射。

**跨数据集泛化**：ImageNet 上训的 PatchSAE 放到 domain-shifted 数据集（细粒度动植物等），概念保持可解释——SAE 学的是 CLIP ViT 内部通用的视觉概念，不是 ImageNet 特供版。

---

## 四、关键发现 2：SAE latent 对分类有因果影响

**方法**：latent masking 消融
- 对某个类，找到 top activating SAE latents
- 将这些 latent 的激活值强制置零
- 观察分类准确率变化

**结果**：mask 掉关键 latent 后分类性能显著下降 → 这些概念不只在统计上和输出相关，在因果上参与了分类决策。

这一点与 NeurIPS 2025 的因果干预实验互相印证——NeurIPS 改一个 SAE 神经元能控制 LLaVA 的生成输出，PatchSAE mask 掉概念能损伤分类性能。两个都是因果性证据，一个正着做（插入/放大），一个反着做（掩码/删除）。

---

## 五、关键发现 3（核心贡献）：Adaptation = 重映射，不学新概念

### 5.1 实验设计

- **Adaptation 方法**：MaPLe（Khattak et al., 2023a）——CLIP 视觉+文本分支各加少量可学习 prompt token，联合微调
- **任务**：few-shot 图像分类（多下游数据集）
- **分析工具**：在**未 adapt 的基座 CLIP** 上训好 PatchSAE，用同一组 SAE latent 去观察 adapt 后的模型

### 5.2 两个竞争假设

| 假设 | 含义 | 如果是真，预期观察到 |
|------|------|-------------------|
| **H1：学新概念** | Adaptation 让模型学到了基座模型没有的新视觉概念 | SAE latent 激活模式 adapt 前后大幅变化 |
| **H2：重映射旧概念** | Adaptation 只是重新调整了已有概念和下游类别之间的权重 | 激活模式变化不大，但概念→类别的映射关系变了 |

### 5.3 结果：H2 胜出

- adapt 前后，同一个 SAE latent 在同一张图的同一个 patch 上的激活强度**变化很小**
- 但 adapt 后的模型对下游类的预测更多依赖「真正相关的概念」、更少依赖无关概念
- 统计：**大部分性能提升可以用基座模型已有的概念解释**

### 5.4 核心结论

> Prompt-based adaptation 的主要机制不是教会模型「看新东西」，而是教会它「做这道题时重点看哪些老东西」——这是 **selective remapping（选择性重映射）**，不是 concept learning（概念学习）。

这解释了为什么 prompt-based adaptation 只需要很少的训练样本就能生效——它不是从零学概念（那需要大量数据），只是重新加权已有概念（少量样本就够）。

---

## 六、两篇 SAE 论文串起来看

```
NeurIPS 2025 (Pach et al.):
  Q: SAE 特征可靠吗？                    → YES (MS + MTurk 82.8% + 因果干预)
  Q: 改一个特征能控制输出吗？             → YES (LLaVA steering: 综合 52.5% vs DiffMean 33.3%)
  Q: 跨编码器泛化吗？                     → YES (4 种编码器都有效)
  角色: 把 SAE 当研究对象

PatchSAE (Lim et al.):
  Q: 视觉概念能空间定位吗？               → YES (patch 级激活图)
  Q: Adaptation 学新概念还是重映射？       → 重映射 (selective remapping)
  Q: SAE 特征对分类有因果作用吗？          → YES (masking 消融)
  角色: 把 SAE 当分析仪器
```

两条线互补。NeurIPS 那篇验证了 SAE 这个工具本身靠谱（才能放心当仪器用），PatchSAE 拿这个已验证的工具去发现了 adaptation 的机制秘密。

---

## 七、局限

1. **只用 L1 稀疏**——未比较 BatchTopK/Matryoshka 等更优策略（NeurIPS 那篇已证明 BatchTopK 比 L1 好）
2. **只在分类任务上分析 adaptation**——未涉及 captioning/VQA/对话等多模态任务
3. **SAE 训练在单层**——未系统性比较多层的信息差异（NeurIPS 覆盖了 L11/17/22/23/last 五层）
4. **只分析了 MaPLe**——CoOp/CoCoOp 等其他 prompt-based 方法的内部机制可能不同
5. **仅视觉侧**——未分析文本编码器侧的 adaptation 机制

---

## 八、一句话记忆标签

> PatchSAE 让我们能看到：adaptation 不是教会模型看新东西，而是告诉它「做这道题时，看你本来就认识的那些东西里的这几个。」

> CLS 能告诉你「有狗」，patch token 能告诉你「狗在哪」——SAE 挂在 CLS 上能拆语义，挂在 patch 上还能拆空间。
