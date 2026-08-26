---
title: LLM架构进阶-从注意力变体到推理引擎
aliases: [LLM进阶, 注意力变体, 推理系统]
tags: [ai/learning, ai]
created: 2026-08-26
updated: 2026-08-26
status: review
source: 论文与官方技术报告共识（FlashAttention/GQA/MLA/DeepSeek-V2V3、vLLM PagedAttention、Orca、GPTQ/AWQ/SmoothQuant）；前沿条目标待确认
fetched_at: 2026-08-26
---

# LLM 架构进阶：从注意力变体到推理引擎

> [!abstract] 定位
> [[AI大模型开发]] 手推导图的进阶续篇：现代 LLM 的结构决策（注意力变体/长上下文/MoE）与推理系统工程化（KV cache 数学、连续批处理、投机解码、量化）。每节回答"为什么这样设计"而非罗列名词。服务化实操在 [[LLM推理部署与量化]]，训练侧在 [[强化学习对齐-RLHF到GRPO]]。

See also: [[CS-KB-Home]] · [[深度学习算法基础]] · [[向量数据库与检索]] · [[AI-Dev-KB-Home]]

## 一、注意力变体：KV cache 压力驱动的演化

### 为什么变体存在：先算账
```
KV cache 显存 = 2 × layers × kv_heads × head_dim × seq_len × batch × bytes
例: 32层×32头×128维×4K seq×1 batch×fp16 = 2×32×32×128×4096×2B ≈ 2.1GB / 序列
长上下文×并发时, KV 而非权重成为显存杀手 → 所有变体都在压 kv_heads
```

| 变体 | 机制 | 代价 | 代表 |
|------|------|------|------|
| MHA | Q/K/V 各自多头 | 基线 | 原始 Transformer |
| MQA | 所有 Q 头共享 1 组 KV | 质量损失明显 | 早期 PaLM 类 |
| **GQA** | Q 分组共享 KV(如 8 组) | 质量≈MHA、显存∝组数 | Llama2-70b+/绝大多数现代模型 |
| **MLA**(DeepSeek) | KV 压成低秩隐向量, 解码时上投影 | 显存压缩一个量级+质量保持；实现复杂 | DeepSeek-V2/V3 |

直觉：GQA 砍"头数"，MLA 直接改"存储基"。选型看推理栈支持度——vLLM/SGLang 对 MLA 支持滞后于 GQA（版本相关**待确认**）。

## 二、长上下文：位置编码外推

- RoPE 是旋转位置编码：绝对位置→QK 内积中的相对旋转角
- 直接换算超训长度会崩（高频角度未见分布）→ 三代方案：
  1. **PI 线性插值**：位置整体除以缩放因子 s——高频信息被压扁
  2. **NTK-aware 缩放**：改 base 频率而非线性插值，高低频区别对待
  3. **YaRN**：按频段分段插值+注意力温度补偿——当前主流口径
- 训练期决定上限：宣称 128K 的模型其有效上下文(needle 通过率)常低于标称——评测见 RAG 课程检索章节的交叉印证

## 三、MoE：稀疏激活的工程真相

```
router(x) → softmax 打分 → Top-K 专家(典型 k=2/8) → 加权组合输出
```

- 参数多≠计算多：总参=全部专家，激活参=路由到的 k 个——容量与算力解耦
- 三大工程问题：
  1. **负载不均**：router 塌缩到少数专家 → aux loss(负载均衡) + noise routing
  2. **专家容量溢出**：token 超专家容量被丢弃(dropped) → capacity factor 调参
  3. **all-to-all 通信**：专家分布式放置后每层两次全互联——EP 并行的通信墙（对照 [[LLM推理部署与量化]] 并行章节）
- 共享专家(DeepSeek)+细粒度专家是当前配方主流

## 四、推理系统：两阶段的不对称性

| 阶段 | 性质 | 瓶颈 | 对策 |
|------|------|------|------|
| Prefill(整 prompt 一次前向) | 计算密集(AI 高强度) | 算力 | chunked prefill 与解码交错 |
| Decode(逐 token) | 访存密集(每步读全 KV/权重) | **带宽** | 连续批处理摊薄 |

Roofline 视角（[[计算机组成原理]] §七）：decode 算术强度低→在带宽墙下运行→**批越大单 token 成本越低**——这是所有推理引擎优化的第一性原理。

### 连续批处理 + PagedAttention
- 传统 static batching：整批等最长序列完成，GPU 大量空转 → **Orca 式迭代级调度**：每个 decode step 重新组批，完成即出队、新请求即插入
- KV 显存的碎片问题：按 seq 预留连续空间→内部+外部碎片 → **PagedAttention**：KV 切 block 页表化管理(类虚拟内存)，碎片近零、copy-on-write 支持 beam/前缀共享(prefix caching 命中率是新指标)

### 投机解码（speculative decoding）
```
小草稿模型连猜 γ 个 token → 大模型一次并行验证 → 按接受长度回退修正
数学保证: 采样分布与大模型单独采样完全一致(拒绝采样构造)
加速 ≈ (1-α^(γ+1))/(1-α) · c , α=草稿接受率
```
适用条件：验证并行收益 > 草稿开销；α 高的任务(代码/模板文本)收益最大。Medusa/self-speculation 变体省独立草稿模型（成熟度**待确认**）。

## 五、量化在栈里的位置

| 方案 | 类型 | 思路 |
|------|------|------|
| GPTQ | 权重 W4A16 | 基于 Hessian 的逐层误差补偿 OBQ 近似 |
| AWQ | 权重 W4A16 | 按"激活幅度"保护显著权重通道，免反传 |
| SmoothQuant | W8A8 | 把激活 outlier 的尺度迁到权重(migrate)，整型化 |
| FP8(E4M3/E5M2) | 前沿硬件原生 | H100+ 训推直用，配 per-tensor scale |

选型锚点：显存不够才量化；W4A16 主流落地质量损耗 <1% 困难任务除外——**必须带自家 eval 回归**（呼应 [[agent-evals-observability]] 评测先行）。

## 六、待确认项

> ① MLA 在各推理引擎的支持与 kernel 优化进度；② 长上下文有效长度各家评测协议统一情况(RULER 类)；③ MoE 专家并行的通信-容量联合调优公开基准；④ 线性注意力/混合架构(Mamba 系)在生产模型的占比变化。

## Related

[[CS-KB-Home]] · [[AI大模型开发]] · [[LLM推理部署与量化]] · [[深度学习算法基础]] · [[RAG检索增强生成实战]] · [[AI-Dev-KB-Home]]
