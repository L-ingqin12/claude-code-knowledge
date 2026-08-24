---
title: 箭头连接检查清单
aliases: [Arrow Checklist]
tags: [reference]
created: 2026-07-28
updated: 2026-08-25
status: stable
---

See also: [[AGENTS]] (绘图规范) | [[Network-DocGraph.excalidraw]] (文档关系图)

# Excalidraw 箭头连接检查清单

> [!note] 本清单已覆盖 6 张核心图的**箭头校验**（下表逐一列出）；其余新增图请在绘制时按本规范自检：逐项核对源/目标元素与方向，修复悬空、错位箭头。绘图规范见 [[AGENTS#十一、图表与可视化约定]]。

> 操作：在 Obsidian 中打开 `.excalidraw.md` → 按 `A` 选箭头工具 → 从源矩形边缘拖到目标矩形边缘（自动吸附对齐）→ 保存

---

## 1. Transformer-Architecture

| # | 箭头 | 从 | 到 | 方向 |
|---|------|----|----|:--:|
| 1 | Input → Encoder | `Input (today is sunny)` 右 | `Encoder` 框左 | → |
| 2 | Embedding → Encoder | `Token Embedding` 右 | `Multi-Head Self-Attention` 左 | → |
| 3 | +PE → Encoder | `+ Positional Encoding` 右 | `Multi-Head Self-Attention` 左 | → |
| 4 | MHSA → AddNorm | `Multi-Head Self-Attention` 底 | `Add & Norm`(第1个) 顶 | ↓ |
| 5 | AddNorm → FFN | `Add & Norm`(第1个) 底 | `Feed Forward` 顶 | ↓ |
| 6 | FFN → AddNorm | `Feed Forward` 底 | `Add & Norm`(第2个) 顶 | ↓ |
| 7 | Encoder → Decoder | `Add & Norm`(第2个) 右 | `Decoder` 框左 | → |
| 8 | MSA → AddNorm | `Masked Self-Attention` 底 | `Add & Norm`(第3个) 顶 | ↓ |
| 9 | AddNorm → CA | `Add & Norm`(第3个) 底 | `Cross-Attention` 顶 | ↓ |
| 10 | CA → AddNorm | `Cross-Attention` 底 | `Add & Norm`(第4个) 顶 | ↓ |
| 11 | AddNorm → FFN | `Add & Norm`(第4个) 底 | `Feed Forward`(解码器) 顶 | ↓ |
| 12 | FFN → AddNorm | `Feed Forward`(解码器) 底 | `Add & Norm`(第5个) 顶 | ↓ |
| 13 | Decoder → Output | `Add & Norm`(第5个) 右 | `Linear + Softmax` 左 | → |
| 14 | Linear → Predict | `Linear + Softmax` 底 | `Predict Next Token` 顶 | ↓ |

---

## 2. GPT-DecoderOnly

| # | 箭头 | 从 | 到 | 方向 |
|---|------|----|----|:--:|
| 1 | Input → Embedding | `Input Token IDs` 底 | `Token Embedding + RoPE` 顶 | ↓ |
| 2 | Embedding → Decoder | `Token Embedding + RoPE` 底 | `Decoder Layer` 框顶 | ↓ |
| 3 | Decoder → LM Head | `Decoder Layer` 框底 | `LM Head` 顶 | ↓ |
| 4 | LM Head → Softmax | `LM Head` 底 | `Softmax + Sampling` 顶 | ↓ |
| 5 | Softmax → Output | `Softmax + Sampling` 底 | `Next Token` 顶 | ↓ |
| 6 | Loop | `Next Token` 右 | 回到 Decoder 框右 | ↻ (虚线) |

---

## 3. SelfAttention-Flow

| # | 箭头 | 从 | 到 | 方向 |
|---|------|----|----|:--:|
| 1 | X → Q | `Input X` 右 | `Q = XWq` 左 | → |
| 2 | X → K | `Input X` 右 | `K = XWk` 左 | → |
| 3 | X → V | `Input X` 右 | `V = XWv` 左 | → |
| 4 | Q → Scores | `Q = XWq` 右 | `Scores = Q×K^T` 左 | → |
| 5 | K → Scores | `K = XWk` 右 | `Scores = Q×K^T` 左下 | → |
| 6 | Scores → Scale | `Scores = Q×K^T` 底 | `÷√d_k` 顶 | ↓ |
| 7 | Scale → Mask | `÷√d_k` 底 | `+ Mask` 顶 | ↓ |
| 8 | Mask → Softmax | `+ Mask` 底 | `Softmax` 顶 | ↓ |
| 9 | Softmax → Weights | `Softmax` 右 | `Attention Weights` 左 | → |
| 10 | Weights → WSum | `Attention Weights` 底 | `Weighted Sum` 顶 | ↓ |
| 11 | V → WSum | `V = XWv` 右 | `Weighted Sum` 左 | → (虚线) |
| 12 | WSum → Output | `Weighted Sum` 底 | `Output` 顶 | ↓ |

---

## 4. MultiHead-Attention

| # | 箭头 | 从 | 到 | 方向 |
|---|------|----|----|:--:|
| 1 | Input → Split | `Input X` 底 | `Split into h heads` 顶 | ↓ |
| 2 | Split → Head1 | `Split` 左 | `Head_1` 顶 | ↙ |
| 3 | Split → Head2 | `Split` 中 | `Head_2` 顶 | ↓ |
| 4 | Split → Headh | `Split` 右 | `Head_h` 顶 | ↘ |
| 5 | Head1 → Attn1 | `Head_1` 底 | `Self-Attention_1` 顶 | ↓ |
| 6 | Head2 → Attn2 | `Head_2` 底 | `Self-Attention_2` 顶 | ↓ |
| 7 | Headh → Attnh | `Head_h` 底 | `Self-Attention_h` 顶 | ↓ |
| 8 | Attn1 → Concat | `Self-Attention_1` 底 | `Concat` 顶 | ↘ |
| 9 | Attn2 → Concat | `Self-Attention_2` 底 | `Concat` 顶 | ↓ |
| 10 | Attnh → Concat | `Self-Attention_h` 底 | `Concat` 顶 | ↙ |
| 11 | Concat → Project | `Concat` 底 | `Project` 顶 | ↓ |
| 12 | Project → Output | `Project` 底 | `Output` 顶 | ↓ |

---

## 5. Training-vs-Inference

| # | 箭头 | 从 | 到 | 方向 |
|---|------|----|----|:--:|
| 1 | Full text → Forward | `Full text` 底 | `Forward` 顶 | ↓ |
| 2 | Forward → Predict | `Forward` 底 | `Predict` 顶 | ↓ |
| 3 | Predict → Loss | `Predict` 底 | `Loss` 顶 | ↓ |
| 4 | Loss → Backward | `Loss` 底 | `Backward` 顶 | ↓ |
| 5 | Prompt → Forward | `Prompt` 底 | `Forward`(推理) 顶 | ↓ |
| 6 | Forward → Sample | `Forward`(推理) 底 | `Sample` 顶 | ↓ |
| 7 | Sample → Append | `Sample` 底 | `Append` 顶 | ↓ |
| 8 | Append → Loop | `Append` 底 | `Loop` 顶 | ↓ |
| 9 | Loop → Forward | `Loop` 右 | `Forward`(推理) 右 | ↻ (虚线) |

---

## 6. Attention-Matrix-Flow

| # | 箭头 | 从 | 到 | 方向 |
|---|------|----|----|:--:|
| 1 | X → Q | `Input X (4×512)` 右 | `Q (4×64)` 左 | → |
| 2 | X → K | `Input X (4×512)` 右 | `K (4×64)` 左 | → |
| 3 | X → V | `Input X (4×512)` 右 | `V (4×64)` 左 | → |
| 4 | Q → Scores | `Q (4×64)` 右 | `Scores (4×4)` 左 | → |
| 5 | K → Scores | `K (4×64)` 右 | `Scores (4×4)` 左 | → |
| 6 | Scores → Scale | `Scores (4×4)` 底 | `Scale` 顶 | ↓ |
| 7 | Scale → Mask | `Scale` 底 | `+ Mask` 顶 | ↓ |
| 8 | Mask → Softmax | `+ Mask` 底 | `Softmax (4×4)` 顶 | ↓ |
| 9 | Softmax → Weights | `Softmax (4×4)` 右 | `Attention Weights (4×4)` 左 | → |
| 10 | Weights → WSum | `Attention Weights (4×4)` 底 | `Weighted Sum (4×64)` 顶 | ↓ |
| 11 | V → WSum | `V (4×64)` 右 | `Weighted Sum (4×64)` 左 | → (虚线) |
| 12 | WSum → Output | `Weighted Sum (4×64)` 底 | `Output (4×64)` 顶 | ↓ |

---

> **总计: 65 条箭头连接** — Transformer(14) + GPT(6) + SelfAttn(12) + MultiHead(12) + Training(9) + MatrixFlow(12)
