---
title: AI 大模型开发笔记
aliases: [AI开发, LLM, 云服务器]
tags: [ai, reference]
created: 2026-07-24
updated: 2026-08-25
status: review
---
# AI 大模型开发笔记

See also: [[AGENTS]] · [[AI-Dev-KB-Home]] — LLM 应用开发实战专题库（本文件"在线大模型开发实战"的深入展开）

## 云 GPU 环境 (AutoDL)

> [!info] 原始笔记整理
> 平台: www.autodl.com。以下为作者使用经验，补充说明见各条目后括号。

- 尽量按量计费比较划算 （按卡时计费、随开随关，适合实验；包月/包日仅在长期连续训练时更划算）
- 西北B区 北京B区 北京A区 （区域决定库存与价格波动；同一账号不同区域互不相通数据盘，选离自己近/有货的区域即可）
- 4090 正常情况下1卡 （单卡 RTX 4090 24GB 显存，7B 模型 FP16 推理 / LoRA 微调的主力配置）
- PyTorch/2.1.0/3.10/12.1 （镜像含义 = PyTorch 2.1.0 + Python 3.10 + CUDA 12.1，三者版本必须互相兼容；驱动由平台管理）

## 大白话解释大模型原理

1. 成语接龙和暴力穷举（类似，而并非真实穷举，根据向量？）

   > [!info] AI 补充 — 准确表述
   > LLM 的生成像"成语接龙"：每步只预测**下一个 token**，但不是暴力穷举所有句子——而是给词表中每个候选 token 打分 (logit)，经 softmax 变成概率分布后采样一个。词表只有几万~十几万项，每步只是"一次前向 + 一次采样"，与"穷举整句话"的指数爆炸完全不同。"根据向量"的直觉是对的：打分依据正是上下文经 Transformer 编码后的向量表示。详见 [[#4. Softmax & Temperature (温度)]] 与 [[#9. Logits → 下一个 Token 预测]]。

2. 大模型根据什么理解人类语言？
   二进制的机器语言 从现实问题转化为数学问题，找到数学和实际直接的联系，让电脑知道存的是什么东西

   > [!info] AI 补充 — 一句话概括
   > 核心思路：**把语言变成向量（几何空间中的点），把"理解"变成向量之间的运算**——语义相近 → 距离相近；类比推理 → 向量加减；上下文关系 → 注意力加权。这样语言问题就完全落在数学的可计算范围内。

   - **向量化** 科学的方法

     > 1.  东西 --> 数字组合 ： 方便电脑处理，寻找规律 >
     > 2. 找到维度（通过计算距离，不断调整位置）
     > 3. 向量可计算 --> 结果 通过结果比较和正确结果的差距 向量化后可以通过数学方法（梯度等最快缩减）得到损失函数（差距）然后不断收敛
     > 4. word2vec 算法 2013年提出 将词汇转化为向量

   - **信息压缩和特征提取**（避免无效的维度使用以及维度过大）
   
     > 1. 图片--> 卷积神经网络(CNN) 投入应用难度较大原因 （找不到比的提取语言特征的方法） 
     > 2. 循环神经网络（RNN）可能续写错误是因为根据附近语义进行预测，长文句子内可能无问题，但不符合通篇语义（按顺序去寻找，无法找到正确的词向量）
     > 3. 2017年谷歌论文 transformer-->解决了自然语言的特征提取难题《 Attention is All you need 》自注意力机制（让句子里的词根句子里的所有词都做向量计算然后去训练）
   
   - 通用人工智能领域的一座高山 自然语言：理解整个文明的成果的能力，和人类无缝交流的能力

     > [!tip] AI 补充 — CNN/RNN 局限的准确说法
     > - **CNN 用于文本**：卷积核只能覆盖局部窗口（3~5 词），捕捉不了长距离依赖——即"找不到像提取图像特征那样有效的方法来提取语言的长程特征"；且 CNN 的平移不变性契合图像空间结构，不契合语言的长依赖结构。
     > - **RNN 的两个硬伤**：① 按时间步串行计算无法并行、训练慢；② 长序列信息多步传递会衰减遗忘（LSTM 门控只是缓解）。原文"按附近语义预测、不符合通篇语义"正是长距离依赖丢失的表现。
     > - **Transformer 的解法**：自注意力让任意两词**一步直达**（路径 O(1)）且整段可并行，同时解决"长依赖 + 并行化"。

### 向量化到梯度下降 — 直观流程图

![[AI-Word2Vec-LossGradient.excalidraw]]

> 上图展示了从"向量化"到"梯度下降收敛"的完整路径：东西→向量→计算结果→与正确结果对比→计算差距(损失函数)→数学方法(梯度下降)缩小差距→不断收敛。

### Word2Vec 与梯度下降最小 Demo

> [!info] 对应上图的可运行代码
> 用 PyTorch 实现 skip-gram Word2Vec，直观看到"向量 → 打分 → 损失 → 梯度收敛"全流程。CPU 上几秒即可跑完。

```python
import torch
import torch.nn as nn
import torch.nn.functional as F

# 语料: 5 个词的小词表, 演示用
vocab = ["我", "爱", "自然", "语言", "处理"]
word2idx = {w: i for i, w in enumerate(vocab)}

# 训练样本 (中心词, 上下文词) —— 真实场景由滑动窗口扫描语料得到
pairs = [(0, 1), (1, 2), (2, 3), (2, 4), (1, 3), (3, 4)]

class Word2Vec(nn.Module):
    """Skip-gram: 用中心词预测上下文词。
    两个矩阵: W_in (嵌入层, 查表得中心词向量)
              W_out (输出投影, 给每个候选词打分)
    """
    def __init__(self, vocab_size=5, dim=8):
        super().__init__()
        self.W_in  = nn.Embedding(vocab_size, dim)   # 词 → 向量
        self.W_out = nn.Linear(dim, vocab_size, bias=False)  # 向量 → 各词打分

    def forward(self, center_ids):
        v = self.W_in(center_ids)          # (batch, dim)  ← "东西变向量"
        logits = self.W_out(v)             # (batch, vocab) ← "向量可计算, 打分"
        return logits

model = Word2Vec()
optimizer = torch.optim.SGD(model.parameters(), lr=0.05)

centers  = torch.tensor([p[0] for p in pairs])
contexts = torch.tensor([p[1] for p in pairs])

for epoch in range(200):
    logits = model(centers)
    loss = F.cross_entropy(logits, contexts)   # ← "与正确结果的差距"
    optimizer.zero_grad()
    loss.backward()                            # ← "梯度: 最快缩减差距的方向"
    optimizer.step()                           # ← "不断收敛"
    if epoch % 50 == 0:
        print(f"epoch {epoch:3d}  loss={loss.item():.4f}")

# 训练完成后: W_in 权重矩阵就是每个词的稠密向量 (语义坐标)
emb = model.W_in.weight.detach()
sim = F.cosine_similarity(emb[2].unsqueeze(0), emb)  # 与"自然"的相似度
for w, s in zip(vocab, sim.tolist()):
    print(f"cos('自然', {w}) = {s:+.3f}")
```

> [!tip] 观察点
> - `loss` 单调下降 = 梯度下降在收敛；`W_in.weight` 就是学到的嵌入矩阵。
> - 这正是 [[#2. Embedding (嵌入/词向量)]] 中"查表"的来源：`nn.Embedding` 本质是可学习的查找表。
> - 局限印证 [[#前置知识]]：每个词只有一个静态向量，"苹果"(水果/公司) 无法区分 → 引出 ELMo/Transformer 的动态表示。

## 手推 Transformer

> [!abstract] 核心公式
> $Attention(Q,K,V) = softmax(\frac{QK^T}{\sqrt{d_k}})V$

> [!info] 架构图均为 Excalidraw
> 本节所有架构/流程图已使用 Excalidraw 绘制（`diagrams/` 目录），在 Obsidian 中点击嵌入即可查看，可自由标注。绘图规范见 [[AGENTS#十一、图表与可视化约定]] 与 [[ARROW-CHECKLIST]]。

### 整体架构图

![[Transformer-Architecture.excalidraw]]

> 🟡 Attention | 🟠 Cross-Attention | 🔵 输入 | 🟢 输出

### GPT 类 Decoder-Only 架构 (当前 LLM 主流)

> [!info] Excalidraw 版: ![[GPT-DecoderOnly.excalidraw]]

现代大模型 (GPT-4, Claude, DeepSeek, LLaMA) 只用 Decoder 部分：
![[GPT-DecoderOnly.excalidraw]]

### 前置知识

1. **独热编码 (One-Hot)**
   - 单词之间无关联，正交
   - 维度爆炸，存储浪费
2. **Word2Vec**
   - 嵌入矩阵 $W_{embed}$（原笔记中称为 Q 矩阵，非 Attention 的 Q）将独热向量映射到低维稠密空间
     $\begin{bmatrix} 0 & 0 & 0 & 1 & 0\end{bmatrix} \cdot W_{embed} = \text{稠密词向量}$
   - 优点: 降维 + 语义相近的词向量距离近
   - 缺点: 静态嵌入，无法处理多义词
   > [!warning] 术语澄清
   > 这里的 Q/W 是 **Word2Vec 的嵌入矩阵**，与 Transformer Self-Attention 中的 **Query (Q) 是完全不同的概念**。Attention 中的 Q 是输入 X 经过 $W_q$ 线性投影得到，用于"查询"其他词。
3. **ELMo** (Embeddings from Language Models)
   - 基于上下文的动态词嵌入
   - 双层双向 LSTM 预训练
   - 提取: 句法特征 + 语义特征 + 单词特征

### Self-Attention 详解

**Q/K/V 三个向量:**

| 向量 | 含义 | 计算 |
|------|------|------|
| Query (Q) | 当前词在"找什么" | $Q = X \cdot W_q$ |
| Key (K) | 当前词"提供什么"来匹配 | $K = X \cdot W_k$ |
| Value (V) | 当前词"贡献什么"信息 | $V = X \cdot W_v$ |

**计算步骤:**
1. 计算注意力分数: $S = QK^T$
2. 缩放: $S / \sqrt{d_k}$ (防止梯度消失)
3. Softmax 归一化 → 概率分布
4. 加权求和: $Output = softmax(S/\sqrt{d_k}) \cdot V$

> [!tip] 为什么除以 √d_k — 精确原因
> 假设 Q、K 各分量是均值 0、方差 1 的独立随机变量，则点积 $q \cdot k = \sum_{i=1}^{d_k} q_i k_i$ 的方差为 $d_k$。$d_k=64$ 时分数标准差达 8，喂给 softmax 会落入饱和区（输出接近 one-hot），反向传播梯度趋近 0。除以 $\sqrt{d_k}$ 把方差拉回 1，softmax 保持"有梯度的中间状态"。这是原论文 3.2.1 节的原始论证。

### Self-Attention 计算流程图

![[SelfAttention-Flow.excalidraw]]

### 矩阵维度变换流 (数据形状追踪)

![[Attention-Matrix-Flow.excalidraw]]

> 上图标注了每一步的矩阵维度：
> - X: `(seq_len, d_model)` → 经过 Wq/Wk/Wv → Q/K/V: `(seq_len, d_k)`
> - Q×K^T → Scores: `(seq_len, seq_len)` attention 矩阵
> - Softmax × V → Output: `(seq_len, d_v)` 最终表示

### Multi-Head Attention 结构图

![[MultiHead-Attention.excalidraw]]

### Multi-Head Attention

多个注意力头并行，每个头关注不同的关系模式:
- 语法关系 (主谓宾)
- 语义关系 (同义/反义)
- 位置关系 (远近依赖)

> [!info] 为什么每个头会学到不同模式？
> 每个头有**独立的** $W_q, W_k, W_v$（见源码节 [[#2. Multi-Head Attention — 多头拆分与合并]]）。初始化随机 + 各头只看到自己那份 64 维子空间，训练中自然分化出互补的"视角"；可视化研究（如 *What Does BERT Look At?*）证实部分头专门追踪语法依存、部分头关注相邻位置。
>
> **代价与收益**：8 个头总计算量 ≈ 1 个 512 维头（因为拆分后每头只有 64 维），但表达能力 = 8 个不同子空间的组合——"同样的算力，多个视角"。

### Positional Encoding (位置编码) — 深度理解

> [!question] 核心问题
> "我吃饭" 和 "饭吃我" 包含完全相同的三个 token。Transformer 并行处理所有词，**如何区分顺序？**

**直观类比 — 给每个位置一个独特的"节奏指纹"：**

把 d_model 维拆成多个"频率通道"。每个位置在低频通道上变化慢，在高频通道上变化快：

```
位置:    0        1        2        3        4
─────────────────────────────────────────────────
PE_dim0:  0.00     0.84     0.91     0.14    -0.76   ← 低频, 变化慢
PE_dim1:  1.00     0.54    -0.42    -0.99    -0.65   ← 中低频
PE_dim3:  0.00    -0.96     0.28     0.96     0.28   ← 中高频
PE_dim7:  1.00    -0.28    -0.96    -0.28     0.96   ← 高频, 变化快
```

**数值实例 — 手算位置 3 的前 8 维 PE：**

```
d_model=512, pos=3, 取 i=0,1,2,3:

i=0 (维度0): PE(3,0) = sin(3 / 10000^(0/512)) = sin(3/1)    =  0.141
i=0 (维度1): PE(3,1) = cos(3 / 10000^(0/512)) = cos(3/1)    = -0.990
i=1 (维度2): PE(3,2) = sin(3 / 10000^(2/512)) = sin(3/1.04) =  0.260
i=1 (维度3): PE(3,3) = cos(3 / 10000^(2/512)) = cos(3/1.04) = -0.966
i=2 (维度4): PE(3,4) = sin(3 / 10000^(4/512)) = sin(3/1.08) =  0.370
i=2 (维度5): PE(3,5) = cos(3 / 10000^(4/512)) = cos(3/1.08) = -0.929
i=3 (维度6): PE(3,6) = sin(3 / 10000^(6/512)) = sin(3/1.12) =  0.468
i=3 (维度7): PE(3,7) = cos(3 / 10000^(6/512)) = cos(3/1.12) = -0.884
```

> [!tip] PE 的关键性质
> **任意两个位置的关系是固定的**——pos+k 的 PE 可以由 pos 的 PE 线性变换得到。模型不需要记住每个绝对位置，只需要学会看"相距多远"。

**为什么 sin/cos 而不是可学习 Embedding？**
- sin/cos 天然支持**任意长度**序列（训练 512 → 推理 1024 也有效）
- 可学习 Embedding 只见过训练时的最大位置，超长直接"失明"
- RoPE 结合了两者优点：可学习 + 相对位置 + 可外推更长序列

![[Transformer-PositionalEncoding.excalidraw]]

现代 LLM 多使用 **RoPE** (Rotary Position Embedding)，在 Attention 计算时旋转 Q/K 向量来编码相对位置。

---

### 残差连接 — 深度理解

> [!question] 核心问题
> GPT-3 有 96 层。梯度从第 96 层传到第 1 层，经过约 200 次乘法。每次乘 0.9 → 第 1 层梯度 = $0.9^{200} \approx 7 \times 10^{-10}$ → 前面层学不到任何东西。

**数值实例 — 梯度如何消失 vs 残差如何拯救：**

```
没有残差 (96层, 每层梯度衰减到原来的 0.9):
  第96层: dp = 1.0
  第95层: dp = 0.9
  第50层: dp = 0.9^46  = 0.008   ← 梯度已很小
  第 1层: dp = 0.9^95  = 0.000045 ← 基本为零, 完全不学

有残差 (梯度通过"高速路"直传):
  第96层: dp = 1.0
  第95层: 主路 0.9 + 高速路 1.0 = 1.9
  第50层: 主路 0.008 + 高速路 1.0 = 1.008  ← 梯度几乎不变!
  第 1层: 主路 ~0 + 高速路 1.0 = 1.0       ← 和顶层一样强!
```

**具体计算实例：**

```
输入:  x = [0.5, -0.3, 0.8]
Attention 输出: f(x) = [2.1, -1.5, 0.3]     ← 数值范围变大了

残差: Output = f(x) + x = [2.1+0.5, -1.5+(-0.3), 0.3+0.8]
                         = [2.6, -1.8, 1.1]

关键观察:
  - 如果 f(x)≈0 (注意力没学到东西): Output ≈ x  ← 至少不退化
  - 如果 f(x) 学到了: Output = 新信息 + 旧信息  ← 两者兼得
```

> [!tip] 残差的本质
> 不是"多了一条路"，而是让网络的**默认行为 = 恒等映射**。Attention 只需要学"和输入差多少"（残差），而不是"输出应该是什么"。学残差比学绝对输出容易得多——大多数情况下只要微调就行。

![[Transformer-ResidualConnection.excalidraw]]

> 左侧无残差：梯度指数衰减（0.9^95 ≈ 0）。右侧有残差：高速路直传梯度（≈1.0），前面层也能学到。

---

### Layer Normalization — 深度理解

> [!question] 核心问题
> 经过 Attention 后，输出的数值范围可能从 [-1,1] 变成 [-100,100]。如果不归一化，**下一层的 softmax 会完全饱和** ($e^{100}$ 溢出)，无法训练。

**数值实例 — 完整计算过程：**

```
某层输出向量: x = [85.0, -42.0, 3.0, -60.0]

Step 1 — 算均值 μ:
  μ = (85 + (-42) + 3 + (-60)) / 4 = -14 / 4 = -3.5

Step 2 — 算方差 (每个值偏离均值多少):
  (85+3.5)² + (-42+3.5)² + (3+3.5)² + (-60+3.5)²
  = 7832 + 1482 + 42 + 3192 = 12548
  σ² = 12548/4 = 3137
  σ  = √3137 ≈ 56.0

Step 3 — 归一化: y = (x - μ) / σ
  y₁ = (85 - (-3.5))  / 56.0 =  1.58
  y₂ = (-42 - (-3.5)) / 56.0 = -0.69
  y₃ = (3 - (-3.5))   / 56.0 =  0.12
  y₄ = (-60 - (-3.5)) / 56.0 = -1.01

结果: y = [1.58, -0.69, 0.12, -1.01]  ← 均值≈0, 标准差≈1

Step 4 — 可学习的 γ, β 让模型"恢复"有用的数值幅度:
  Output = γ · y + β   (γ 默认=1, β 默认=0, 然后训练中调整)
```

**为什么 NLP 用 LayerNorm 而不用 BatchNorm？**

| | BatchNorm | LayerNorm |
|---|---|---|
| 归一化维度 | 同一特征, 不同样本 | 同一样本, 不同特征 |
| 受 batch size 影响 | 是 (batch=1 退化) | **否 (完全独立于 batch)** |
| 推理时需要缓存 | 需要 running mean/var | **无需缓存, 直接计算** |
| 序列长度不等时 | 需要 padding 处理 | **每个 token 独立** |

> [!tip] 完整 Block 的数值流
> ```
> 输入:      [0.5, -0.3, 0.8]        ← 稳定范围
>   ↓ Attention (可能放大)
> attn:      [2.1, -1.5, 0.3]        ← 范围扩大
>   ↓ + 残差 (Input 直接加回来)
> resid:     [2.6, -1.8, 1.1]        ← 进一步偏移
>   ↓ LayerNorm (拉回来)
> norm:      [1.2, -0.9, 0.4]        ← 回到稳定范围
>   ↓ FFN (非线性变换)
> ffn:       [3.5, -2.1, 1.8]        ← 再次扩大
>   ↓ + 残差
> resid:     [4.0, -2.4, 2.6]
>   ↓ LayerNorm
> out:       [1.1, -0.7, 0.8]        ← 又回到稳定范围
> ```

![[Transformer-BlockNumericalFlow.excalidraw]]

> Attention 放大数值 → 残差叠加 → LayerNorm 拉回稳定 → FFN 再次放大 → 残差叠加 → LayerNorm 再次拉回。**两个 LayerNorm 是关键：防止数值逐层失控。**

### Transformer Block — 组装完整一层

```
Input → Self-Attention → Add&Norm → FFN → Add&Norm → Output
          ↑ 残差连接                   ↑ 残差连接
```

> [!info] Block = "交流" + "思考" 两步
> 一个 Transformer 层干两件事：
> 1. **Self-Attention（词间交流）**：每个 token 从全序列收集相关信息，解决"谁和谁有关"
> 2. **FFN（逐词思考）**：对收集完信息的每个位置独立做非线性变换，解决"这些信息意味着什么"——FFN 参数量约占整层 2/3，模型的"知识"主要存储在 FFN 权重中
>
> 两者各配一对"残差 + LayerNorm"，保证深叠 N 层时梯度健康、数值稳定（见上文数值流实验）。

| 组件 | 职责 | 类比 |
|------|------|------|
| Self-Attention | 信息聚合（横向） | 开会收集各方意见 |
| FFN | 特征变换（纵向） | 会后独立消化整理笔记 |
| 残差 | 保留原始信息通道 | 原始记录不被覆盖 |
| LayerNorm | 数值稳定器 | 音量归一 |

- Encoder Block: Self-Attention + FFN（双向可见），代表: BERT
- Decoder Block: Masked Self-Attention + Cross-Attention + FFN（只看过去），代表: GPT
- 现代 LLM 的差异点集中在：Pre-Norm/Post-Norm、激活函数 (ReLU→SwiGLU)、位置编码 (绝对→RoPE/ALiBi)，对比见 [[#不同模型对应不同的结构 训练数据 训练目标 训练时间]]

## 核心术语深度解析

> [!info] 阅读指引
> 本节将每个术语拆解为三层：(1) **直觉类比** (2) **数学形式** (3) **为什么这样设计**。
> 适合在手推公式后，建立系统性的深层理解。

---

### 1. Token (词元)

| 层 | 解释 |
|----|------|
| **直觉** | 把句子切碎的最小单位。不是"字"也不是"词"，而是"经常一起出现的字符块" |
| **数学** | 整数 ID，范围 0 ~ vocab_size (通常 32000~128000) |
| **为什么** | 英文用 subword (如 "playing" → "play" + "ing")，中文用字或词。BPE (Byte Pair Encoding) 算法自动找出最优切分 |

```
"我喜欢学习人工智能"
  → Tokenizer →
[我, 喜欢, 学习, 人工智能]  →  [105, 287, 419, 2847]
```

> [!tip] 关键
> Token ≠ 词。Token 是模型"看到的"最小原子。Vocab size 越大 → 每个 token 携带更多信息，但计算更慢。GPT-4 的 vocab 约 100K。

---

### 2. Embedding (嵌入/词向量)

| 层 | 解释 |
|----|------|
| **直觉** | 给每个 token 分配一个"意义坐标"。语义相近的词，坐标也相近 |
| **数学** | 查表: `Embedding[token_id]` → d_model 维向量 (如 768/4096 维) |
| **为什么** | 独热编码 100K 维太稀疏。嵌入把 100K 维压缩到 768 维，且保留了语义结构 |

```
king  → [0.3, 0.8, -0.2, ...]
queen → [0.28, 0.82, -0.18, ...]    ← 离 king 很近
apple → [0.9, -0.5, 0.7, ...]       ← 离 king 很远
```

著名的类比: `king - man + woman ≈ queen` — 嵌入能捕捉语义运算。

---

### 3. Q/K/V — 数据库检索类比

这是 Transformer 最难理解的部分。用"图书馆查资料"来类比：

| 角色 | 类比 | Transformer 中 |
|------|------|---------------|
| **Query (Q)** | 你的**检索需求** | "我想找关于机器学习的内容" |
| **Key (K)** | 每本书的**索引标签** | "本书讲机器学习/深度学习/NLP" |
| **Value (V)** | 每本书的**实际内容** | 书中的具体知识 |
| **$QK^T$** | 你的需求与每本书标签的**匹配度** | "机器学习" 匹配 "机器学习" 高分, "烹饪" 低分 |
| **Softmax** | 把匹配度转为概率 | 70% 看这本, 20% 看那本, 10% 看另外的 |
| **Softmax × V** | 按概率**加权汇总**实际内容 | 综合多本书的知识输出 |

```
具体例子: "她吃了一个苹果"

"苹果"的 Q 去查所有词的 K:
  "吃"    → 高匹配 (苹果可以被吃)
  "她"    → 中匹配 (施事者)
  "一个"  → 低匹配 (量词,不重要)
  "苹果"  → 自身匹配 (自己关注自己)

最终 "苹果" 的表示 = 0.6×V_吃 + 0.2×V_她 + 0.1×V_一个 + 0.1×V_苹果
```

> [!tip] 为什么 Q/K 要分开？
> 如果 Q=K，那 "苹果" 对 "吃" 的关注度 必须等于 "吃" 对 "苹果" 的关注度。但实际语言中，**关注是不对称的** — "苹果" 更依赖 "吃" 来消歧义，而 "吃" 没那么依赖 "苹果"。Q≠K 给了模型表达不对称关系的能力。

---

### 4. Softmax & Temperature (温度)

| 层 | 解释 |
|----|------|
| **直觉** | Softmax = 把任意分数变为概率 (总和=1)。Temperature = 控制概率分布的"尖锐度" |
| **数学** | $softmax(x_i) = e^{x_i} / \sum e^{x_j}$ |
| **加温度** | $softmax(x_i / T)$ — T 越高 → 分布越平 (更随机); T 越低 → 分布越尖 (更确定) |

```
原始分数: [3.0, 1.0, 0.5]

T=0.5 (低温, 更确定):  [0.92, 0.06, 0.02]  → 几乎只选第一个
T=1.0 (标准):          [0.71, 0.20, 0.09]  → 按比例选
T=2.0 (高温, 更随机):  [0.48, 0.29, 0.23]  → 相对均匀
```

> [!tip] 这就是为什么 LLM 有时"胡说八道"
> 高温 → 更"有创意" (但更容易跑偏)。低温 → 更"保守" (但可能重复)。**"暴力穷举"不是真的列出所有可能，而是用 softmax+采样来高效选择。**

---

### 5. Self-Attention vs Cross-Attention (自注意 vs 交叉注意)

| 类型 | Q 来源 | K,V 来源 | 作用 |
|------|--------|----------|------|
| **Self-Attention** | 当前序列 | 当前序列(自己) | 理解序列内部关系 |
| **Cross-Attention** | Decoder | Encoder 输出 | 翻译时"看原文" |
| **Causal/Masked** | 当前序列 | 当前序列(只看到过去) | 生成时不能偷看未来 |

```
Self-Attention:  "我 爱 北京 天安门"
  "北京" 去查所有词 → 发现和 "天安门" 紧密相关

Cross-Attention: 翻译 "I love Beijing"
  Decoder 生成 "我" 时, 去查 Encoder 中 "I" 的表示
  Decoder 生成 "爱" 时, 去查 Encoder 中 "love" 的表示
```

---

### 6. 残差连接 (Residual Connection) — 高速公路

| 层 | 解释 |
|----|------|
| **直觉** | 给信息开一条"高速公路"，让原始输入可以直接跳到输出端，不被中间层"卡住" |
| **数学** | $Output = Layer(Input) + Input$ |
| **为什么** | 深层网络(>100层)训练时梯度会消失。残差让梯度可以通过"高速路"直接回传。没有残差，GPT-3 的 96 层根本训练不动 |

```
没有残差:  Input → [Layer1] → [Layer2] → ... → Output  (梯度越传越小)
有残差:    Input → [Layer1] → +Input → [Layer2] → +Input → Output
                    ↑ 高速路直通          ↑ 高速路直通
```

---

### 7. Layer Normalization (层归一化)

| 层 | 解释 |
|----|------|
| **直觉** | 把每个样本的特征值"压"到均值为 0、标准差为 1 的范围，防止数值爆炸 |
| **数学** | $y = \frac{x - \mu}{\sqrt{\sigma^2 + \epsilon}} \cdot \gamma + \beta$ |
| **为什么** | 深层网络各层输出的数值范围会逐渐失控。LayerNorm 让每一层都在稳定范围内工作 |

> BatchNorm vs LayerNorm: BatchNorm 在 batch 维度做归一化(受 batch size 影响)。LayerNorm 在 feature 维度做(不受 batch size 影响, 更适合 NLP)。

---

### 8. FFN (Feed-Forward Network / 前馈网络)

| 层 | 解释 |
|----|------|
| **直觉** | Attention 负责"查资料" (聚合信息)，FFN 负责"思考消化" (变换表示) |
| **数学** | $FFN(x) = ReLU(xW_1 + b_1)W_2 + b_2$ 或 SwiGLU 变体 |
| **为什么** | Attention 只是线性加权，无法引入非线性变换。FFN 的 4x 扩展-压缩结构给模型"思考空间" |

```
Attention: "我看到了'苹果'与'吃'的关系"         ← 信息聚合
FFN:       "在这个上下文中，'苹果'是水果不是公司" ← 特征变换
```

---

### 9. Logits → 下一个 Token 预测

| 层 | 解释 |
|----|------|
| **直觉** | 模型对"每个词出现的可能性"打分，分数最高(或采样到)的词成为输出 |
| **数学** | `logits = Output × W_vocab` → `probs = softmax(logits / T)` → `next_token = [已脱敏](probs)` |

```
输入: "今天天气真"
Logits:  [好: 8.2, 差: 2.1, 热: 5.3, 冷: 3.8, ...]
Softmax: [好: 0.72, 热: 0.15, 冷: 0.07, 差: 0.03, ...]
采样:    "好" (72%概率), 或 "热" (15%概率), ...
输出:    "今天天气真好"
```

> [!tip] 这就是"成语接龙"的数学本质
> 不是真的穷举所有可能，而是用概率分布来高效采样。温度控制着"敢不敢冒险选低概率的词"。

---

### 10. 训练 vs 推理

| 阶段 | 做什么 | 关键区别 |
|------|--------|----------|
| **训练** | 给模型看海量文本, 让它预测下一个 token, 算误差, 更新参数 | 并行, 知道"正确答案", 反向传播 |
| **推理** | 给模型一个 prompt, 逐个生成 token, 每个新 token 拼回去再生成下一个 | 串行, 不知道对错, 自回归 |

```
训练: "今天天气真___"  → 模型预测 "好" → 对比答案 → 修正参数
推理: "今天天气真"     → 生成 "好" → "今天天气真好" → 生成 "！" → ...
```

![[Training-vs-Inference.excalidraw]]

## Transformer 源码学习 (PyTorch 实现)

> [!info] 学习目标
> 阅读本节前，建议先理解上方"手推 Transformer"和"核心术语深度解析"两节。源码中每个类上方标注了对应的理论章节。

### 0. 完整代码结构速览

```
Transformer (顶层容器)
├── Encoder × N
│   ├── MultiHeadAttention (Self-Attention, Q=K=V=X)
│   ├── Add & Norm (残差 + LayerNorm)
│   └── FeedForward (非线性变换)
├── Decoder × N
│   ├── MultiHeadAttention (Masked Self-Attention)
│   ├── MultiHeadAttention (Cross-Attention, Q=Dec, K=V=Enc)
│   ├── Add & Norm × 3
│   └── FeedForward
├── Embedding + PositionalEncoding (输入层)
└── Linear + Softmax (输出投影)
```

### 1. Scaled Dot-Product Attention — 核心计算

对应章节: [[#Self-Attention 详解]] / [[#Q/K/V — 数据库检索类比]]

```python
import torch
import torch.nn as nn
import torch.nn.functional as F
import math

def scaled_dot_product_attention(Q, K, V, mask=None):
    """
    Q, K, V 的形状: (batch, n_heads, seq_len, d_k)
    
    对应公式: Attention(Q,K,V) = softmax(QK^T / sqrt(d_k)) · V
    
    计算步骤:
      1. scores = Q @ K^T           → 每对 token 的匹配分数 (seq_len × seq_len)
      2. scores = scores / sqrt(d_k) → 缩放, 防止 softmax 饱和
      3. if mask: scores += mask    → Decoder 遮盖未来 token (设为 -inf)
      4. attn = softmax(scores)     → 分数 → 概率分布
      5. output = attn @ V          → 按概率加权汇总 Value
    """
    d_k = Q.size(-1)                              # key 的维度, 如 64
    
    # Step 1-2: 计算缩放后的注意力分数
    scores = (Q @ K.transpose(-2, -1)) / math.sqrt(d_k)
    # scores shape: (batch, n_heads, seq_len, seq_len)
    # scores[i,j] = token_i 对 token_j 的关注程度
    
    # Step 3: 应用 mask (Decoder 特有)
    # mask 中未来位置为 -inf, softmax(-inf) → 0, 实现"不能偷看未来"
    if mask is not None:
        scores = scores.masked_fill(mask == 0, float('-inf'))
    
    # Step 4: Softmax 归一化
    attn_weights = F.softmax(scores, dim=-1)
    # 每一行 sum = 1: 一个 token 对所有 token 的关注权重和为 1
    
    # Step 5: 加权求和
    output = attn_weights @ V
    # output shape: (batch, n_heads, seq_len, d_k)
    
    return output, attn_weights  # 返回 weights 用于可视化
```

> [!tip] 为什么返回 `attn_weights`？
> 训练时通常不返回（浪费显存）。但可视化分析时极其有用——可以看到模型在关注哪些词，是 Transformer 可解释性的核心。

---

### 2. Multi-Head Attention — 多头拆分与合并

对应章节: [[#Multi-Head Attention]] / [[#Multi-Head Attention 结构图]]

```python
class MultiHeadAttention(nn.Module):
    """
    将 d_model 拆成 h 个头, 每个头独立做 Attention, 最后拼接。
    
    维度变化:
      输入:  (batch, seq_len, d_model=512)
      拆分:  (batch, h=8, seq_len, d_k=64)  ← 每个头只看 1/8 的信息
      输出:  (batch, seq_len, d_model=512)  ← 拼接后投影回原维度
    """
    def __init__(self, d_model=512, n_heads=8):
        super().__init__()
        assert d_model % n_heads == 0, "d_model 必须能被 n_heads 整除"
        
        self.d_model = d_model          # 总维度, 如 512
        self.n_heads = n_heads          # 头数, 如 8
        self.d_k = d_model // n_heads   # 每头维度, 如 64
        
        # Wq, Wk, Wv: 将输入投影到 Q/K/V 空间
        # 技巧: 一次性算出所有头的 Q/K/V, 然后 reshape 分头
        self.W_q = nn.Linear(d_model, d_model)  # 512 → 512 (= 8×64)
        self.W_k = nn.Linear(d_model, d_model)
        self.W_v = nn.Linear(d_model, d_model)
        
        # W_o: 将所有头的输出拼接后投影回 d_model
        self.W_o = nn.Linear(d_model, d_model)
    
    def forward(self, Q, K, V, mask=None):
        batch_size = Q.size(0)
        
        # 1. 线性投影: X @ W → (batch, seq_len, d_model)
        Q = self.W_q(Q)
        K = self.W_k(K)
        V = self.W_v(V)
        
        # 2. 拆分为多头: (batch, seq_len, d_model) → (batch, h, seq_len, d_k)
        # 这一步是理解 Multi-Head 的关键:
        #   view:  把 512 维切成 8 段, 每段 64 维
        #   transpose: 把 "头"维移到 batch 后面, 方便并行计算
        Q = Q.view(batch_size, -1, self.n_heads, self.d_k).transpose(1, 2)
        K = K.view(batch_size, -1, self.n_heads, self.d_k).transpose(1, 2)
        V = V.view(batch_size, -1, self.n_heads, self.d_k).transpose(1, 2)
        
        # 3. 每个头独立做 Attention
        attn_output, attn_weights = scaled_dot_product_attention(Q, K, V, mask)
        
        # 4. 合并所有头: (batch, h, seq_len, d_k) → (batch, seq_len, d_model)
        attn_output = attn_output.transpose(1, 2).contiguous()
        attn_output = attn_output.view(batch_size, -1, self.d_model)
        
        # 5. 最终投影
        output = self.W_o(attn_output)
        return output
```

> [!note] 为什么拆分 + 合并不会丢信息？
> 每个头的 Wq/Wk/Wv/Wo 都是可学习的。不同头训练后会关注不同的语言特征（语法/语义/位置）。拆分只是计算上的并行化手段——信息总量不变，但"视角"变多了。

---

### 3. Positional Encoding — 注入位置信息

对应章节: [[#Positional Encoding (位置编码) — 深度理解]]

```python
class PositionalEncoding(nn.Module):
    """
    因为 Transformer 并行处理所有词, 没有"先后顺序"的概念。
    PE 给每个位置加上一个独特的向量, 让模型知道 token 在第几个位置。
    
    核心公式:
      PE(pos, 2i)   = sin(pos / 10000^(2i/d_model))   ← 偶数维度
      PE(pos, 2i+1) = cos(pos / 10000^(2i/d_model))   ← 奇数维度
    """
    def __init__(self, d_model=512, max_len=5000):
        super().__init__()
        
        # 预计算所有位置的 PE (只要算一次, 推理时直接查表)
        pe = torch.zeros(max_len, d_model)          # (5000, 512)
        position = torch.arange(0, max_len).unsqueeze(1)  # (5000, 1)
        
        # div_term: 不同频率的缩放因子
        # 形状: (d_model/2,), 值从 1.0 逐渐增大到 10000
        div_term = torch.exp(
            torch.arange(0, d_model, 2).float() * 
            (-math.log(10000.0) / d_model)
        )
        
        # 偶数维度用 sin, 奇数维度用 cos
        pe[:, 0::2] = torch.sin(position * div_term)  # 低频 → 高频
        pe[:, 1::2] = torch.cos(position * div_term)
        
        # 增加 batch 维度: (1, max_len, d_model)
        pe = pe.unsqueeze(0)
        
        # register_buffer: 不是训练参数, 但会随模型保存/加载
        self.register_buffer('pe', pe)
    
    def forward(self, x):
        # x: (batch, seq_len, d_model)
        # 直接把预计算的 PE 加到输入上
        return x + self.pe[:, :x.size(1), :]
```

> [!warning] 容易混淆的点
> `register_buffer` 的内容**不参与梯度更新**（不是可学习参数），但会随 `model.state_dict()` 保存。`nn.Parameter` 才是可学习的。

---

### 4. FeedForward — 非线性变换

对应章节: [[#8. FFN]]

```python
class FeedForward(nn.Module):
    """
    FFN(x) = ReLU(x·W1 + b1)·W2 + b2
    
    维度变化:
      输入:  (batch, seq_len, d_model=512)
      中间:  (batch, seq_len, d_ff=2048)    ← 4x 扩展, 给模型"思考空间"
      输出:  (batch, seq_len, d_model=512)   ← 压缩回来
    """
    def __init__(self, d_model=512, d_ff=2048):
        super().__init__()
        self.linear1 = nn.Linear(d_model, d_ff)   # 512 → 2048
        self.linear2 = nn.Linear(d_ff, d_model)   # 2048 → 512
    
    def forward(self, x):
        return self.linear2(F.relu(self.linear1(x)))
```

> [!tip] 为什么是 4x 扩展？
> 这是原论文的超参数。扩展到 4x 再压缩回来, 给了模型足够的"中间表示空间"来学习非线性模式。太小则表达能力不足, 太大则过拟合 + 计算慢。现代 LLM 多用 SwiGLU 替代 ReLU。

---

### 5. Encoder Layer — 拼装 Attention + FFN + 残差 + LayerNorm

```python
class EncoderLayer(nn.Module):
    """
    一个 Encoder 层 = Self-Attention → Add&Norm → FFN → Add&Norm
    
    对应架构图: [[Transformer-Architecture.excalidraw]] 中 Encoder 框内部分
    """
    def __init__(self, d_model=512, n_heads=8, d_ff=2048, dropout=0.1):
        super().__init__()
        self.self_attn = MultiHeadAttention(d_model, n_heads)
        self.ffn = FeedForward(d_model, d_ff)
        self.norm1 = nn.LayerNorm(d_model)   # Attention 后的 LayerNorm
        self.norm2 = nn.LayerNorm(d_model)   # FFN 后的 LayerNorm
        self.dropout = nn.Dropout(dropout)
    
    def forward(self, x, mask=None):
        # Sublayer 1: Self-Attention + 残差 + LayerNorm
        attn_out = self.self_attn(x, x, x, mask)  # Q=K=V=x (Self-Attention)
        x = self.norm1(x + self.dropout(attn_out))  # 残差 + Dropout + Norm
        
        # Sublayer 2: FFN + 残差 + LayerNorm
        ffn_out = self.ffn(x)
        x = self.norm2(x + self.dropout(ffn_out))
        return x
```

> [!note] Post-Norm vs Pre-Norm
> 原论文用 Post-Norm (先 Sublayer 后 Norm)。现代 LLM 多用 **Pre-Norm** (先 Norm 后 Sublayer), 训练更稳定: `x = x + attn(norm(x))`。DeepSeek/GPT-4/Claude 都用 Pre-Norm。

---

### 6. Decoder Layer — 比 Encoder 多一个 Cross-Attention

```python
class DecoderLayer(nn.Module):
    """
    Decoder = Masked-SA → Add&Norm → Cross-Attn → Add&Norm → FFN → Add&Norm
    
    和 Encoder 的区别:
      1. 第一个 Attention 是 Masked (不能看未来)
      2. 多了 Cross-Attention: Q 来自 Decoder, K,V 来自 Encoder 输出
    """
    def __init__(self, d_model=512, n_heads=8, d_ff=2048, dropout=0.1):
        super().__init__()
        self.masked_attn = MultiHeadAttention(d_model, n_heads)
        self.cross_attn  = MultiHeadAttention(d_model, n_heads)
        self.ffn = FeedForward(d_model, d_ff)
        self.norm1 = nn.LayerNorm(d_model)
        self.norm2 = nn.LayerNorm(d_model)
        self.norm3 = nn.LayerNorm(d_model)
        self.dropout = nn.Dropout(dropout)
    
    def forward(self, x, enc_output, src_mask=None, tgt_mask=None):
        # Sublayer 1: Masked Self-Attention (只看自己和前面的 token)
        x = self.norm1(x + self.dropout(
            self.masked_attn(x, x, x, tgt_mask)))  # tgt_mask 遮盖未来
        
        # Sublayer 2: Cross-Attention (Q=Decoder, K,V=Encoder 输出)
        x = self.norm2(x + self.dropout(
            self.cross_attn(x, enc_output, enc_output, src_mask)))
        
        # Sublayer 3: FFN
        x = self.norm3(x + self.dropout(self.ffn(x)))
        return x
```

> [!tip] 两个 mask 的区别
> - `tgt_mask` (target mask): 下三角矩阵, 阻止 Decoder 在当前步看到未来的 token
> - `src_mask` (source mask): 处理 padding, 让 Attention 忽略 `<PAD>` token

---

### 7. 完整 Transformer 模型

```python
class Transformer(nn.Module):
    """
    完整架构: Embedding + PE → Encoder×N → Decoder×N → Linear + Softmax
    
    对应: [[Transformer-Architecture.excalidraw]]
    """
    def __init__(self, src_vocab_size, tgt_vocab_size,
                 d_model=512, n_heads=8, n_layers=6, d_ff=2048, dropout=0.1):
        super().__init__()
        
        # 输入层
        self.encoder_embed = nn.Embedding(src_vocab_size, d_model)
        self.decoder_embed = nn.Embedding(tgt_vocab_size, d_model)
        self.pos_encoding = PositionalEncoding(d_model)
        
        # Encoder × N
        self.encoder_layers = nn.ModuleList([
            EncoderLayer(d_model, n_heads, d_ff, dropout)
            for _ in range(n_layers)
        ])
        
        # Decoder × N
        self.decoder_layers = nn.ModuleList([
            DecoderLayer(d_model, n_heads, d_ff, dropout)
            for _ in range(n_layers)
        ])
        
        # 输出投影: d_model → vocab_size (预测每个 token 的概率)
        self.output_proj = nn.Linear(d_model, tgt_vocab_size)
        self.dropout = nn.Dropout(dropout)
    
    def encode(self, src, src_mask=None):
        """Encoder 前向: 输入序列 → 上下文表示"""
        x = self.dropout(self.pos_encoding(self.encoder_embed(src)))
        for layer in self.encoder_layers:
            x = layer(x, src_mask)
        return x  # 作为 Decoder Cross-Attention 的 K, V
    
    def decode(self, tgt, enc_output, src_mask=None, tgt_mask=None):
        """Decoder 前向: 已生成 token + Encoder 输出 → 下一个 token 的概率"""
        x = self.dropout(self.pos_encoding(self.decoder_embed(tgt)))
        for layer in self.decoder_layers:
            x = layer(x, enc_output, src_mask, tgt_mask)
        return x
    
    def forward(self, src, tgt, src_mask=None, tgt_mask=None):
        enc_output = self.encode(src, src_mask)
        dec_output = self.decode(tgt, enc_output, src_mask, tgt_mask)
        return self.output_proj(dec_output)  # (batch, seq_len, vocab_size)
```

---

### 8. 推理：逐个生成 Token (自回归)

```python
@torch.no_grad()
def greedy_decode(model, src, max_len=100, start_token=2, end_token=3):
    """
    推理过程: 给定源序列, 逐个生成目标序列的 token。
    
    对应架构图: [[GPT-DecoderOnly.excalidraw]] (GPT 只用 Decoder, 这里展示完整 Encoder-Decoder)
    
    流程:
      1. Encoder 处理源序列 → enc_output (只算一次)
      2. Decoder 从 <START> token 开始
      3. 每一步: Decoder 预测下一个 token → 选概率最高的 → 拼回去
      4. 遇到 <END> 或达到 max_len 停止
    """
    model.eval()
    enc_output = model.encode(src)                        # Step 1
    
    # Step 2: 从起始 token 开始
    tgt = torch.ones(1, 1).fill_(start_token).long()
    
    for _ in range(max_len):
        # 生成 causal mask (下三角全 1)
        tgt_mask = torch.tril(torch.ones(tgt.size(1), tgt.size(1))).bool()
        
        # Step 3: Decoder 预测
        output = model.decode(tgt, enc_output, tgt_mask=tgt_mask)
        logits = model.output_proj(output[:, -1, :])  # 只看最后一步的输出
        next_token = [已脱敏](dim=-1).unsqueeze(1)  # 贪心选最高概率
        
        # Step 4: 拼接并检查终止
        tgt = torch.cat([tgt, next_token], dim=1)
        if next_token.item() == end_token:
            break
    
    return tgt
```

> [!tip] 训练 vs 推理的关键差异
> - **训练**: `forward(src, tgt)` 一次性输入完整目标序列, 并行计算所有位置的预测
> - **推理**: 必须逐个生成, 因为第 N 个 token 依赖前 N-1 个 token (自回归)
> - 这就是为什么训练快（GPU 并行）而推理慢（串行依赖）

---

### 9. SwiGLU — 现代替代 ReLU 的激活函数

对应章节: [[#2024-2025 效率优化]]

```python
class SwiGLU(nn.Module):
    """
    GPT-4/LLaMA/DeepSeek 使用的 FFN 激活函数。
    
    SwiGLU(x) = (x·W1) · SiLU(x·W2) · W3
    
    和原版 ReLU FFN 的区别:
      - SwiGLU 有"门控"机制 (SiLU 输出在 0~1 之间)
      - 比 ReLU 更平滑, 梯度流动更好
      - 缺点: 参数量多 50% (需要 3 个权重矩阵而非 2 个)
    """
    def __init__(self, d_model, d_ff):
        super().__init__()
        self.W1 = nn.Linear(d_model, d_ff)
        self.W2 = nn.Linear(d_model, d_ff)   # 门控权重
        self.W3 = nn.Linear(d_ff, d_model)
    
    def forward(self, x):
        # SiLU(x) = x * sigmoid(x)
        gate = F.silu(self.W2(x))            # 门控信号: 0~1
        hidden = self.W1(x)                  # 主路径
        return self.W3(hidden * gate)         # 门控 × 主路径
```

---

### 10. 关键维度追踪表

| 组件 | 输入形状 | 输出形状 | 说明 |
|------|----------|----------|------|
| Embedding | `(B, seq)` | `(B, seq, 512)` | 查表 + 缩放 `√d_model` |
| PositionalEncoding | `(B, seq, 512)` | `(B, seq, 512)` | 加法, 形状不变 |
| MultiHeadAttention | `(B, seq, 512)` | `(B, seq, 512)` | 内部拆分 8头×64维 |
| FeedForward | `(B, seq, 512)` | `(B, seq, 512)` | 内部扩展到 2048 |
| Add & Norm | `(B, seq, 512)` | `(B, seq, 512)` | 形状不变 |
| Output Projection | `(B, seq, 512)` | `(B, seq, vocab)` | 投影到词表大小 |

> [!info] 维度不变性
> 注意：除了 Embedding 和 Output Projection, **所有中间层的输入输出形状都是 `(batch, seq_len, d_model)`**。这就是为什么残差连接能简单做加法——张量形状完全匹配。

> [!success] 学习检查
> 试着回答: 如果把 `n_heads` 从 8 改成 16, 哪些代码需要改？为什么 `d_model` 必须能被 `n_heads` 整除？

### 架构变体

| 类型 | 代表模型 | 特点 |
|------|----------|------|
| Encoder-Only | BERT, RoBERTa | 双向注意力, 理解任务 |
| Decoder-Only | GPT-4, LLaMA, DeepSeek-V3 | 因果(单向)注意力, 生成任务 |
| Encoder-Decoder | T5, BART | 翻译/摘要 |

### 2024-2025 效率优化

- **FlashAttention** — IO 优化, 2-4x 加速, 已成 PyTorch 标准
- **GQA** (Grouped Query Attention) — 多 Q 头共享 K/V, 减少 KV 缓存
- **MLA** (Multi-Head Latent Attention, DeepSeek-V3) — 低维潜在空间投影
- **MoE** (Mixture of Experts) — 每次仅激活部分 FFN 参数

> [!tip] 关键理解
> Self-Attention 的核心创新: 每个词直接与序列中所有词交互，权重是**动态的、输入相关的**，而非固定权重。这是 Transformer 超越 RNN/LSTM 的根本原因。

### 进化路线

```
One-Hot → Word2Vec → ELMo → Transformer → BERT/GPT → GPT-4/Claude/DeepSeek
 静态    静态嵌入   动态嵌入   自注意力     预训练      大语言模型(LLM)
```

### Transformer 算法演进全景

![[Transformer-Evolution.excalidraw]]

> 从 Encoder-Decoder 翻译模型 → 规模扩展（参数/层数/数据）→ 涌现智能 → GPT 系列生成式 LLM。原图作者笔记，2026-07-23。



## GPT 不同版本对比

### 不同模型对应不同的结构 训练数据 训练目标 训练时间

> [!info] 表格解读
> 纵向看是"架构选型"的演进：位置编码从绝对 (sinusoidal/learned) → 相对 (RoPE/ALiBi)；激活从 ReLU → 平滑门控 (SwiGLU/GeGLU)；Norm 从 Post → Pre。每一项改进都指向同一个目标：**更深网络下的训练稳定性 + 长上下文外推能力**（原理见 [[#Positional Encoding (位置编码) — 深度理解]]、[[#Layer Normalization — 深度理解]]）。

| 模型            | 结构            | 位置编码       | 激活函数 | layer normal方法 |
| --------------- | --------------- | -------------- | -------- | ---------------- |
| 原生Transformer | Encoder-Decoder | sinusoidal编码 | ReLU     | Post layer norm  |
| BERT            | Encoder         | 绝对位置编码   | GeLU     | Post layer norm  |
| LLaMA           | Causal Decoder  | RoPE           | SwiGLU   | Pre Layer norm   |
| ChatGLM-6B      | Prefix decoder  | RoPE           | GeGLU    | Post Deep Norm   |
| Bloom           | Causal Decoder  | ALiBi          | GeLU     | Pre Layer Norm   |

> [!note] 三种 Decoder 变体的区别
> - **Causal Decoder** (GPT 系)：因果掩码自回归，只看左侧上下文——当前 LLM 主流
> - **Prefix Decoder** (ChatGLM/PaLM 前身)：前缀部分双向可见，生成部分单向
> - **Encoder-Decoder** (T5/BART)：完整原架构，翻译/摘要类任务仍常用

### GPT系列对比

| 对比维度        | GPT-1                                                        | GPT-2                                                        | GPT-3                                                        | GPT-3.5                 | GPT-4        |
| --------------- | ------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ | ----------------------- | ------------ |
| 模型规模        | 117M                                                         | 1.5B                                                         | 175B                                                         | 175B                    | ~1.8T (未官方证实) |
| Transformer层数 | 12                                                           | 48                                                           | 96                                                           | 96                      | 120          |
| 主要贡献        | 1）提出基于生成式预训练的语言理解方法<br />2)展示预训练模型在多种下游任务上的性能提升 | 1）提出无监督多任务学习的语言模型<br />2）扩展了模型规模和预训练数据集规模 | 1）引入少样本学习的能力<br />2）提出prompt engineering<br />3)进一步增大了模型规模和训练数据集规模 | 发布世界级产品 ChatGPT（引入 RLHF 对齐对话能力） | AI多模态模型（图文输入） |
| 发布时间        | 2018                                                         | 2019                                                         | 2020                                                         | 2022                    | 2023         |

> [!warning] 数据口径说明
> - GPT-3.5 官方未公布参数量，表中 175B 为社区普遍推测（基于与 GPT-3 同源）
> - GPT-4 的 1.8T 参数为泄露传闻（MoE 架构，8×220B 专家），OpenAI 从未官方确认；层数同理
> - 规模数字的意义在于**数量级的跃迁**：117M→1.5B→175B，每一步都带来质的涌现能力（in-context learning 等）

# 在线大模型开发实战

## Completion API和Chat Completion API

> Completion模型本质是文本补全模型，核心功能为根据提示词（prompt）进行提示语句的补全
>
> chat模型是Completion模型的升级，核心优势在于理解人类意图的能力，带来了更低的交互门槛，核心功能是对话能力

> [!info] AI 补充 — 两代 API 的精确对比
> | 维度 | Legacy Completion (`/v1/completions`) | Chat Completion (`/v1/chat/completions`) |
> |------|------|------|
> | 输入 | 单个字符串 `prompt` | `messages` 数组 (role + content) |
> | 角色感知 | ❌ 无，靠文本约定 | ✅ system / user / assistant 结构化角色 |
> | 多轮对话 | 需手动拼接全文，模型分不清"谁说的" | 天然按轮次组织，上下文边界清晰 |
> | 训练目标差异 | 纯文本续写分布 | 对话分布（RLHF 对齐后更听指令） |
> | 现状 | **已废弃** (OpenAI 已标记 legacy，新模型不再支持) | 行业标准：OpenAI/DeepSeek/Moonshot/GLM/Ark 全部兼容此格式 |
>
> **本质区别**：Chat API 不只是"格式变了"——chat 模型是在对话数据上继续训练并对齐过的，同一套 Transformer 骨架，但 token 分布已完全不同。用补全方式调用 chat 模型会得到答非所问的结果。

### 消息角色 (roles) 语义

| role | 含义 | 典型用途 |
|------|------|----------|
| `system` | 设定身份、规则、边界（权重之外的"人设"） | "你是资深翻译，只输出译文" |
| `user` | 终端用户输入 | 提问、指令 |
| `assistant` | 模型历史回复 | 多轮上下文回传；few-shot 示例 |
| `tool` | 工具执行结果回传（配合 function calling） | 见 [[Function-Calling工具调用实战]] |

### 最小可用 Demo

```python
# pip install openai>=1.0   — OpenAI SDK 格式已是行业通用协议
from openai import OpenAI

client = OpenAI(
    api_key="[已脱敏]",
    base_url="https://api.deepseek.com",  # 换 base_url 即可切换 DeepSeek/Kimi/GLM 等兼容服务
)

response = client.chat.completions.create(
    model="deepseek-chat",
    messages=[
        {"role": "system",    "content": "你是一位严谨的技术翻译。"},
        {"role": "user",      "content": "把下句译成英文: 大模型正在改变软件开发。"},
        {"role": "assistant", "content": "LLMs are transforming software development."},  # few-shot 示例轮
        {"role": "user",      "content": "把下句译成英文: 注意力机制是核心创新。"},
    ],
    temperature=0.2,   # 翻译要确定性强 → 低温
    max_tokens=200,
)
print(response.choices[0].message.content)
print(response.usage)   # prompt_tokens / completion_tokens → 计费依据, 见 [[参考-Ark-Agent-Plan计费与配置]]
```

等价 curl：

```bash
curl https://api.deepseek.com/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{
    "model": "deepseek-chat",
    "messages": [{"role":"user","content":"你好"}],
    "temperature": 0.7
  }'
```

### 关键采样参数速查

| 参数 | 作用 | 经验值 |
|------|------|--------|
| `temperature` | 分布尖锐度（原理见 [[#4. Softmax & Temperature (温度)]]） | 翻译/抽取 0~0.3；创作 0.7~1.0 |
| `top_p` (nucleus) | 只从累计概率 ≥p 的候选中采样，与 temperature 二选一调 | 默认 1.0，一般不动 |
| `max_tokens` | 输出长度上限（截断时 finish_reason=length） | 按需设置，防跑飞 |
| `stop` | 停止序列 | 解析结构化输出时常用 |
| `stream=True` | SSE 流式返回 token | 聊天界面必备，首字延迟 ↓ |

### 流式输出 Demo

```python
stream = client.chat.completions.create(
    model="deepseek-chat",
    messages=[{"role": "user", "content": "用三句话解释 KV Cache"}],
    stream=True,                       # 服务端逐 token 推送 (SSE)
)
for chunk in stream:                   # 每个 chunk 是增量 delta
    delta = chunk.choices[0].delta.content
    if delta:
        print(delta, end="", flush=True)
```

> [!warning] 常见坑
> 1. **无状态**：API 不记历史，多轮对话必须把历史 messages 每次完整回传——这正是 [[Claude-Code记忆机制源码拆解]] 中"记忆 = 上下文拼接"的原因
> 2. **上下文窗口有限**：历史太长要做截断/摘要策略，见 [[上下文工程-注意力预算与四层解法]]
> 3. **计费双向**：输入+输出都计费，长 system prompt 反复发送很贵 → 提示词缓存 (prompt caching) 可降本
> 4. **finish_reason 必查**：`length`=被截断, `stop`=正常结束, `tool_calls`=需执行工具后回传结果

### 本文件后续实战路线图

> [!abstract] 从"会用 API"到"工程化开发"的六个专题
> 以上只是最基础的单轮调用。完整的 LLM 应用开发知识树按"一文档一问题"原则拆分为独立专题文档：
>
> | 专题 | 文档 | 解决什么问题 |
> |------|------|--------------|
> | 提示工程 | [[Prompt-Engineering入门与Demo]] | 如何写好 prompt：few-shot / CoT / 结构化输出 |
> | 工具调用 | [[Function-Calling工具调用实战]] | 让模型调用函数/API，从"说"到"做" |
> | 检索增强 | [[RAG检索增强生成实战]] | 接入私有知识，解决幻觉与时效性 |
> | Agent | [[LLM-Agent开发基础]] | 循环决策 + 工具编排，ReAct 模式 |
> | 微调 | [[LoRA参数高效微调实战]] | 用领域数据定制模型行为 |
> | 推理部署 | [[LLM推理部署与量化]] | vLLM 自托管、KV Cache、量化压缩 |
>
> 入口 MOC: [[AI-Dev-KB-Home]]









## 统一多模态模型：Janus 系列的解耦视觉编码（课程第 29 章）

> [!abstract] 一句话定位
> DeepSeek 的 Janus / Janus-Pro 回答了一个根本问题：**能不能用一个 Transformer 同时做好"看懂图"和"画出图"？** 它的答案是——LLM 骨干统一，但**视觉编码解耦**：理解走 SigLIP（高层语义），生成走 VQ tokenizer（底层像素），两条通路汇入同一个自回归骨架做统一的 next-token 预测。

### 为什么必须"解耦"

此前统一多模态的两条路线各有一个死结：

| 路线 | 代表 | 死结 |
|---|---|---|
| 单编码器离散化 | Chameleon | 理解需要高层语义抽象，生成需要细粒度像素细节，一个 VQ 编码器顾此失彼——理解任务被生成需求拖累 |
| 扩散外挂 | GPT-4o 原版 + DALL·E | 理解用 Transformer、生成交给扩散模型，两套目标函数、两套权重，谈不上"统一" |

Janus 的洞察：冲突不在"任务"，而在**表征需求的矛盾**——把视觉编码拆成两个独立编码器，冲突就地消解；而 LLM 骨干仍然共享，理解与生成可以互相增益（论文消融显示解耦后理解与生成双双提升，而非此消彼长）。

### 架构与训练

```
图像 ─┬─ SigLIP 编码器(理解) ──语义 token──┐
      └─ VQ tokenizer(生成) ──码本 token──┤
文本 ────── Llama 分词器 ─────────────────┤
                                          ▼
                    统一 Transformer(Llama3 兼容) ← 自回归 next-token 预测
                                          │
                              文本头输出 / 图像反量化→去噪解码器出图
```

训练三阶段（Janus-Pro 调整了各阶段配比并扩充数据）：①适配器 + 图像头在 ImageNet 上对齐 → ②图文统一预训练（含文生图数据）→ ③指令微调。Janus-Pro 相对初代的三项改进 = 训练策略（阶段配比）、数据规模与配比、模型放大到 **1B / 7B** 两档开源权重（HuggingFace `deepseek-ai/Janus-Pro-*`）。

### 成绩单

| 基准 | Janus-Pro-7B | 说明 |
|---|---|---|
| GenEval（文生图一致性） | **0.80** | 发布时超过 SDXL / SD3 / DALL·E 3 同口径成绩 |
| MMBench（多模态理解） | **79.2** | 与专职理解模型同档，证明"解耦"没有牺牲理解 |

> [!tip] 与本库其他知识的连接
> - "统一 next-token 预测"思想与上文 [[#大白话解释大模型原理]] 的自回归采样一脉相承——图像生成也被收编为 token 预测
> - 开源权重可按 [[LLM推理部署与量化]] 的 Ollama/vLLM 思路本地化部署（需支持其自定义架构的推理栈）
> - 三阶段训练法是 [[微调数据工程与模型蒸馏]] 中 SFT 流程的多模态放大版

参考资料：
- [Janus: Decoupling Visual Encoding for Unified Multimodal Understanding and Generation (arXiv:2410.13848)](https://arxiv.org/abs/2410.13848)
- [Janus-Pro: Unified Multimodal Understanding and Generation with Data and Model Scaling (arXiv:2501.17801)](https://arxiv.org/abs/2501.17801)
- [deepseek-ai/Janus-Pro-1B (HuggingFace)](https://huggingface.co/deepseek-ai/Janus-Pro-1B)
- [Awesome-VLM-Architectures: Janus-Pro 解耦架构条目](https://github.com/gokayfem/awesome-vlm-architectures)

## 课程知识地图 — 2026 AI 大模型应用开发工程师系统课

> [!abstract] 来源与用法
> 本节将《西瓜老师·2026 年 AI 大模型应用开发工程师【系统课】》38 个章节映射为本库学习路径：理论部分保留在本文件上半部；实战部分按"一文档一问题"原则拆分至 [[AI-Dev-KB-Home]] 专题库；配套流程图统一为 Excalidraw（`diagrams/` 目录）。

| 学习阶段 | 课程章节 | 对应文档 |
|----------|----------|----------|
| ① 理论基础 | 1 导读/云 GPU · 2 大模型基础/手推 Transformer/GPT 对比 | 本文件上文各节 |
| ② API 开发 | 3 在线大模型开发 · 28 DeepSeek API 实战 | [[#Completion API 和 Chat Completion API]] · [[Function-Calling工具调用实战]] |
| ③ 私有化部署 | 4 Ollama · 5 vLLM · 6 Ray 多机多卡 | [[LLM推理部署与量化]] |
| ④ 提示词与 FC | 7 提示词工程和 Function 进阶 | [[Prompt-Engineering入门与Demo]] · [[Function-Calling工具调用实战]] |
| ⑤ Agent 基础 | 8 Agent 架构 · 9 ReAct · 10/11 MCP · 12 A2A · 13 Skills · 15 Harness Engineering | [[LLM-Agent开发基础]] · [[MCP协议开发实战]] · [[A2A多智能体协作协议]] · [[Agent-Skills技能开发实战]] |
| ⑥ 框架 | 16 Dify · 17/18 LangChain · 19 LangGraph | [[LangChain-LangGraph框架实战]] |
| ⑦ RAG | 23 架构演进 · 24 选型 · 25 性能优化 · 26 GraphRAG · 27 商业项目 | [[RAG检索增强生成实战]] · [[GraphRAG知识图谱增强实战]] |
| ⑧ 微调 | 30 行业微调 · 31 蒸馏 · 33 LoRA/QLoRA · 34 RLHF/DPO/GRPO · 35 数据工程 · 36 Llama-Factory · 37 Embedding 微调 · 38 金融垂直大模型 | [[LoRA参数高效微调实战]] · [[强化学习对齐-RLHF到GRPO]] · [[微调数据工程与模型蒸馏]] |
| ⑨ 大型项目 | 20 ChatBI · 21 多模态 Agent 平台 · 22 企业智能问数 · 32 企业智能体客服 | 各专题文档内嵌项目注解 + [[多模态Agent平台实战]] + [[AI-Dev-KB-Home]] 项目地图 |

> [!note] 未单独成文的知识点
> - **14 OpenClaw 二次开发 / 15 Harness Engineering**：其方法论与本库 [[Loop-Engineering-深度拆解-从产品功能集到方法论包装]]、[[Anthropic-Skill系统深度分析]] 及 claude-ops 子库高度重叠，建议对照阅读互为印证
> - **29 统一多模态模型**（DeepSeek Janus 系）：已展开，见上文 [[#统一多模态模型：Janus 系列的解耦视觉编码（课程第 29 章）]]
> - **13 Skills / 21 多模态 Agent 平台**：课程标注"即将更新"，已按公开规范与社区实践先行补齐为 [[Agent-Skills技能开发实战]] 与 [[多模态Agent平台实战]]；课程上线后对照增补
> - **时效性缺口雷达**（课程内容相对 2026 行业演进可能滞后）：Prompt Caching、Agent 可观测性、Guardrails、Computer/Browser Use 等——覆盖状态见 [[AI-Dev-KB-Home]] 的"课程外增补雷达"

## Related

- [[AGENTS]] — AI 协作规范
- [[参考-Ark-Agent-Plan计费与配置]] — Ark API 参考
- [[AI-Links-KB-Home]] — AI 链接收藏库（Agent/Skills/推理工程综述）
- [[AI-Dev-KB-Home]] — LLM 应用开发实战专题库 MOC
