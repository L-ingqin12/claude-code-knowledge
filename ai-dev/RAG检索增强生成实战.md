---
title: RAG检索增强生成实战
aliases: [RAG实战, 检索增强生成, RAG入门, Naive RAG, Advanced RAG]
tags: [ai, ai/learning]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# RAG检索增强生成实战

> 一句话定位：RAG（Retrieval-Augmented Generation，检索增强生成）以"先检索、后生成"的两段式管线把外部知识库接入大模型，是治理幻觉（Hallucination）、时效性不足、私域知识缺失与答案不可溯源四大落地痛点的首选方案。

> [!abstract]
> 本文对应课程第 23/24/25 章：从 RAG 全流程剖析（离线索引 + 在线查询两条管道）入手，梳理大模型应用落地痛点、Naive RAG → Advanced RAG 的架构演进、微调 vs RAG 方案选型、技术选型（向量库/开源框架/评估工具）与性能优化十二式，并配套纯 Python + FAISS 最小可运行 Demo（含 Ragas 评估思路伪代码）。原理图嵌入 `RAG-Pipeline.excalidraw`（见 [[#原理剖析]]）。选型与进阶可交叉阅读 [[GraphRAG知识图谱增强实战]]、[[LoRA参数高效微调实战]]、[[LLM推理部署与量化]]。

## 核心概念

### RAG 关键术语表

| 术语 | 全称 | 说明 |
|------|------|------|
| RAG | Retrieval-Augmented Generation | 检索增强生成：外部知识召回 + 大模型生成 |
| Embedding | 向量化/嵌入 | 把文本映射为稠密向量，语义相近则向量距离近 |
| Chunk | 文本片段 | 文档按语义切分后的最小检索单元，粒度决定召回质量 |
| Vector DB | 向量数据库 | 存储向量并支持近似最近邻（ANN，Approximate Nearest Neighbor）检索 |
| TopK | 召回数量 | 相似度排名前 K 的候选片段，K 常取 3~8 |
| Rerank | 重排序 | 用精排模型对召回的 K 个片段二次打分排序 |
| Naive RAG | 朴素 RAG | 只含"检索→拼接→生成"三步的基础管线 |
| Advanced RAG | 高级 RAG | 在朴素管线前后加查询优化与检索后优化的管线 |
| HyDE | Hypothetical Document Embeddings | 先让 LLM 生成假设答案再嵌入检索，缓解查询-文档措辞差异 |
| RRF | Reciprocal Rank Fusion | 倒数排名融合：多路召回结果按排名倒数加权合并 |

### 大模型应用落地四大痛点

| 痛点 | 具体表现 | RAG 的对策 |
|------|----------|------------|
| 幻觉（Hallucination） | 参数记忆不可靠，一本正经地编造不存在的细节 | 用检索到的真实片段约束生成，要求"只依据参考资料回答" |
| 时效性 | 参数冻结在训练时刻，不知道训练截止后发生的事 | 知识入库即生效，增量更新即可跟上最新信息 |
| 私域知识 | 企业内部文档不在公开预训练语料中 | 私域文档切片嵌入本地向量库，数据不出域也可用 |
| 溯源（Traceability） | 黑盒回答无法定位依据，用户不敢信 | 召回片段随答案一起返回，逐条给出引用来源 |

### RAG 两条管道速览

| 阶段 | 步骤 | 产物 |
|------|------|------|
| 离线索引（写入时） | 加载 → 切分 → 嵌入 → 入库 | 向量库（chunk 文本 + 向量 + 元数据） |
| 在线查询（回答时） | 查询嵌入 → 召回 TopK → 拼接 Prompt → 生成 | 带引用的答案 |

## 原理剖析

![[RAG-Pipeline.excalidraw]]

> [!info] 图解 RAG 两条管道
> 图上半部分是**离线索引管道**（蓝色输入侧）：多格式文档加载后经切分器切成 chunk，逐块送入 Embedding 模型得到向量，连同原文与元数据写入向量数据库，一次写入、多次查询复用。图下半部分是**在线查询管道**（绿色输出侧）：用户问题先做查询优化（改写/HyDE/扩展），嵌入后到向量库做 ANN 检索召回 TopK，再经 Rerank 精排与上下文压缩，把精选片段与问题拼成 Prompt 交给 LLM，最终生成带引用来源的回答。

### 离线索引管道（写入时）

1. **加载（Load）**：从 PDF/Word/Markdown/网页等源读取文档，清洗格式噪声（页眉页脚、乱码、表格样式）。
2. **切分（Split）**：按句/段/标题层级切成 chunk，常用 256~512 token、重叠（overlap）10%~20%；粒度太细丢上下文，太粗则召回噪声大。
3. **嵌入（Embed）**：每个 chunk 经嵌入模型编码为向量（中文推荐 bge/m3e 系列，见 [[#Embedding 中文模型对比]]）。
4. **入库（Index）**：向量 + 元数据（来源、页码、标题）写入向量库，建立 ANN 索引（HNSW/IVF 等）。

### 在线查询管道（回答时）

1. **查询嵌入**：把用户问题用**同一个**嵌入模型编码，保证与库内向量同分布、同维度（混用模型是相似度噪声的头号来源）。
2. **召回 TopK**：ANN 检索取相似度前 K 个 chunk（K 常为 3~8，太小证据不足、太大引入噪声且撑爆上下文窗口）。
3. **拼接 Prompt**：把 K 个片段按相似度排序拼接为"参考资料"，套入约束性提示词模板（"只依据参考资料回答，没有就说不知道"）。
4. **生成**：LLM 基于 Prompt 输出答案，产品层再把引用来源、页码、相似度一并展示（可解释性）。

### Naive RAG → Advanced RAG 架构演进

Naive RAG 三步管线有三大硬伤：查询表述与文档措辞不匹配（词面 gap）、召回精度不够（噪声片段拉低答案）、生成时被无关上下文干扰。Advanced RAG 在管线前后加"查询前优化 + 检索后优化"：

| 优化位置 | 手段 | 解决的问题 |
|----------|------|------------|
| 查询前 | 查询改写（Query Rewriting） | 口语/省略指代改写成检索友好的完整表达 |
| 查询前 | HyDE | 先让 LLM 生成假设答案再嵌入，缓解查询-文档分布差异 |
| 查询前 | 查询扩展（Query Expansion） | 同义词/多视角扩写，扩大召回面 |
| 检索后 | 重排序（Rerank） | bge-reranker 等交叉编码器对 TopK 精排，把真正相关的提到前面 |
| 检索后 | 上下文压缩（Context Compression） | 剔除与问题无关的片段内容，省 token 且降噪 |

## 最小可运行 Demo

> [!info] 纯 Python + FAISS 本地知识库最小实现
> 依赖：`pip install faiss-cpu numpy requests`（可选 `sentence-transformers` 用于 bge-small-zh）。约 80 行（含注释与空行）跑通"3 段示例文档 → 句子切分 → 嵌入 → FAISS 索引 → Top3 召回 → 拼 Prompt → DeepSeek 生成"全流程；无 GPU、无向量数据库服务也可运行。

```python
# -*- coding: utf-8 -*-
"""
RAG 最小可运行 Demo：纯 Python + FAISS 本地知识库
离线索引: 示例文档 -> 句子切分 -> Embedding -> FAISS 入库
在线查询: 问题嵌入 -> 召回 Top3 -> 拼接 Prompt -> DeepSeek 生成
"""
import hashlib

import numpy as np

# 1. 示例文档（模拟 3 段私域知识）
DOCS = [
    "DeepSeek-R1 通过强化学习(RL)训练推理能力，推理时会输出思维链(CoT)。",
    "DeepSeek-V3 采用 MoE(Mixture of Experts，混合专家)架构，总参数 671B、激活参数 37B，训练成本约 557 万美元。",
    "知识库采用 RAG 方案时，切分粒度与相似度阈值需要按业务数据调优。",
]

# 2. 句子切分：按中文句号切成 chunk（真实项目用 tiktoken/语义切分）
def split_sentences(docs):
    chunks = []
    for doc in docs:
        for sent in doc.replace("。", "。\n").split("\n"):
            sent = sent.strip()
            if sent:
                chunks.append(sent)
    return chunks

chunks = split_sentences(DOCS)

# 3. Embedding：优先加载 bge-small-zh；环境受限时用哈希伪向量降级演示
def embed(texts):
    try:  # 需要 pip install sentence-transformers，首次会联网下载模型
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer("BAAI/bge-small-zh-v1.5")
        return np.asarray(model.encode(texts, normalize_embeddings=True), dtype="float32")
    except Exception:
        print("[降级] 未安装/未下载 bge 模型，改用哈希伪向量（仅供流程演示）")
        vecs = []
        for t in texts:
            seed = int(hashlib.md5(t.encode("utf-8")).hexdigest()[:8], 16)  # 文本 -> 随机种子
            v = np.random.default_rng(seed).standard_normal(64).astype("float32")  # 64 维伪向量
            vecs.append(v / (np.linalg.norm(v) + 1e-9))  # L2 归一化，内积即余弦相似度
        return np.stack(vecs)

chunk_vecs = embed(chunks)          # 离线索引：chunk -> 向量
query = "DeepSeek-R1 的推理能力是怎么训练的？"
q_vec = embed([query])              # 在线查询：问题 -> 向量（必须同一模型）

# 4. FAISS 索引入库（IndexFlatIP = 暴力内积检索，演示足够）
import faiss
index = faiss.IndexFlatIP(chunk_vecs.shape[1])
index.add(chunk_vecs)

# 5. 召回 Top3：返回相似度与 chunk 下标
k = 3
scores, ids = index.search(q_vec, k)
recalled = [(chunks[i], float(s)) for s, i in zip(scores[0], ids[0])]

# 6. 拼接 Prompt：召回片段做"参考资料"，约束生成行为（治理幻觉）
context = "\n".join(f"- {t}（相似度 {s:.2f}）" for t, s in recalled)
prompt = (
    "你是一个严谨的问答助手，只依据下方参考资料回答；"
    "资料中没有的信息，请直接回答“不知道”，不要编造。\n\n"
    f"参考资料：\n{context}\n\n"
    f"问题：{query}\n\n回答："
)
print("===== 召回片段 =====")
print(context)
print("\n===== 最终 Prompt =====")
print(prompt)

# 7. 调 DeepSeek 生成（OpenAI 兼容接口；未配置 key 时不发请求）
def ask_deepseek(prompt, api_key=None):
    if not api_key:
        print("\n[跳过生成] 未提供 DEEPSEEK_API_KEY，仅演示到 Prompt 构造")
        return ""
    import requests
    resp = requests.post(
        "https://api.deepseek.com/chat/completions",
        headers={"Authorization": f"Bearer {api_key}"},
        json={"model": "deepseek-chat",
              "messages": [{"role": "user", "content": prompt}],
              "temperature": 0.3},
        timeout=60,
    )
    return resp.json()["choices"][0]["message"]["content"]

if __name__ == "__main__":
    answer = ask_deepseek(prompt, api_key=None)
    if answer:
        print("\n===== DeepSeek 回答 =====")
        print(answer)
```

### Ragas 评估思路（伪代码）

```python
# Ragas 自动评估 RAG 效果（pip install ragas）
# 变量 query/answer/recalled 沿用上方 Demo 的产物
from ragas import evaluate
from ragas.metrics import faithfulness, answer_relevancy, context_precision
from datasets import Dataset

eval_data = Dataset.from_dict({
    "question": [query],                              # 测试问题
    "answer": [answer],                               # 系统生成的回答
    "contexts": [[t for t, _ in recalled]],           # 实际召回的片段
})
result = evaluate(eval_data, metrics=[faithfulness, answer_relevancy, context_precision])

# faithfulness       忠实度:     回答中能被上下文支持的陈述占比 —— 直接度量幻觉
# answer_relevancy   答案相关性: 回答与问题的语义相关度
# context_precision  上下文精度: 召回片段里"真有用"的比例 —— 度量检索质量
```

> [!note] Ragas 版本差异（已核实）
> 上方伪代码对应 Ragas **v0.1.x** API（小写函数式导入 `from ragas.metrics import faithfulness`）。Ragas v0.2+ 改为类式导入并实例化（`from ragas.metrics import Faithfulness; Faithfulness()`），官方迁移指南见文末 [[#参考资料]]。

## 进阶实践与常见坑

### 微调 vs RAG 方案选型

| 维度 | RAG | 微调（Fine-tuning） |
|------|-----|---------------------|
| 知识更新频率 | 高频场景：入库即生效，秒级更新 | 低频场景：需重新训练/增量训练 |
| 可控性 | 高：直接增删文档、改提示词即可干预 | 低：权重是黑盒，行为只能靠数据引导 |
| 成本 | 低：向量库 + API 推理即可起步 | 高：GPU 卡时 + 高质量标注数据 |
| 可解释性 | 强：答案可逐条溯源到片段 | 弱：无法指出知识来自哪条训练数据 |
| 典型用途 | 企业知识问答、文档助手、客服 | 固化风格/格式/领域行为（如 LoRA，见 [[LoRA参数高效微调实战]]） |

> [!tip] 经验法则
> 知识类问题优先 RAG；"怎么说话/按什么格式输出"类行为问题才考虑微调。两者可叠加：先微调定风格、再 RAG 补知识。

### RAG 应用落地场景

- **企业知识库问答**：制度/流程/手册类文档问答，员工秒级查政策
- **智能客服**：产品文档 + 历史工单做知识底座，降低转人工率
- **专业领域助手**：法律条文、医疗指南、金融研报问答，附带原文引用
- **代码库问答**：仓库源码切片入库，问"这个接口在哪定义"直接给文件行号
- **联网搜索增强**：搜索结果当召回源，缓解模型时效性问题

### 技术选型对比

**向量数据库 vs 知识图谱**：向量库擅长"语义相近"的模糊召回，但表达不了实体间的多跳关系（"张三的领导的部门"这种跨片段推理）；知识图谱擅长结构化推理与全局归纳，但构建成本高。两者互补——这正是 [[GraphRAG知识图谱增强实战]] 的出发点。

**开源框架对比**：

| 框架 | 定位 | 特点 |
|------|------|------|
| LangChain | 全栈编排框架 | 生态最大、组件最全（LCEL 链式编排），但抽象层厚、学习曲线陡 |
| LlamaIndex | 数据索引优先 | 索引/查询引擎抽象清晰，文档解析与结构化数据支持好，RAG 专用性强 |
| Haystack | 生产级管线 | 组件化 Pipeline 稳定可扩展，适合企业部署 |

**向量数据库对比**：

| 向量库 | 形态 | 特点 | 适用规模 |
|--------|------|------|----------|
| Milvus | 分布式服务 | 十亿级向量、索引类型全、运维体系完善 | 大规模生产 |
| FAISS | 进程内库 | Meta 出品，纯计算无服务，性能基线 | 离线/嵌入式/研究 |
| Chroma | 嵌入式 | 零部署、API 简单，LangChain 默认搭档 | Demo/小规模 |
| Qdrant | Rust 服务 | 高性能、过滤查询（payload filter）强 | 中小规模生产 |

**效果评估工具对比**：

| 工具 | 特点 |
|------|------|
| Ragas | RAG 专用指标集（faithfulness/answer_relevancy/context_precision 等），支持自动合成测试集 |
| TruLens | 可观测 + 评估一体（RAG triad 三指标），带实验对比 UI |

### 性能优化十二式

| # | 招式 | 要点 |
|---|------|------|
| 1 | 多路召回方案 | 向量召回 + BM25 关键词召回（+可选知识图谱召回）并行，用 RRF（Reciprocal Rank Fusion）融合排序，兼顾语义与精确词匹配 |
| 2 | Embedding 模型选择 | 中文检索优先 bge-large-zh-v1.5（配 bge-reranker 最佳）；轻量用 m3e-small；句对相似度场景用 text2vec |
| 3 | 表格数据处理方案 | 表格按行切分易丢表头，改为"行 + 表头列名拼接"或生成表格摘要向量；复杂聚合问句走 Text2SQL |
| 4 | 相似度不准问题 | 余弦相似度是相对分数不可跨查询比较；设阈值过滤低分片段，混入负样本校准，检索质量用 context_precision 度量 |
| 5 | 幻觉问题治理 | 提示词强约束"资料没有就说不知道"；要求答案逐句标注引用；用 faithfulness 指标回归测试 |
| 6 | 高性能模型管理 | 推理用 vLLM/TensorRT-LLM 加速，嵌入模型量化（int8）后批处理，吞吐显著提升 |
| 7 | 语义缓存一致性方案 | 相似问题命中缓存直接返回；缓存键绑定知识库版本号，库更新即整体失效，防止"旧答案" |
| 8 | 反馈机制设计 | 点赞/点踩落库形成 badcase 集，定期回流：补文档、调阈值、改 Prompt，形成飞轮 |
| 9 | 可解释性设置 | 答案附带来源标题/页码/相似度，支持点击跳转原文；来源缺失时显式标注"无依据" |
| 10 | 推理资源设计 | 问答型服务重读轻写：嵌入 GPU 与生成 GPU 分池，限制并发与最长输出，防止长问题打爆队列 |
| 11 | 图文知识库方案 | 图片先 OCR + 生成图注，图注文本与正文同库嵌入；检索命中图片时返回原图引用 |
| 12 | 效果评估指标 | 上线前用 Ragas 跑 faithfulness（忠实度）、answer_relevancy（答案相关性）、context_precision（上下文精度）三项基线，每次变更回归对比 |

### Embedding 中文模型对比

| 模型 | 机构 | 维度 | 特点 |
|------|------|------|------|
| bge-large-zh-v1.5 | BAAI（智源） | 1024 | 中文 MTEB 榜单常客，检索能力强，配 bge-reranker 效果最佳 |
| m3e-small/base | Moka AI | 512/768 | 轻量中文句向量，社区热度高，便于二次微调 |
| text2vec-base-chinese | shibing624 | 768 | 老牌中文句向量，句对/相似度任务成熟稳定 |

### 常见坑速查

| 坑 | 症状 | 对策 |
|----|------|------|
| 嵌入模型不一致 | 查询与库用了不同模型，相似度全是噪声 | 全链路锁定同一模型名与版本 |
| chunk 过粗 | 答案被无关段落带偏、上下文超限 | 按语义切 256~512 token，加 overlap |
| TopK 拍脑袋 | K 太大引入噪声，太小证据不足 | 用 context_precision/recall 扫描 K 取拐点 |
| 只调向量一种召回 | 精确词（型号/编号）召回失败 | 加 BM25 多路召回 + RRF 融合 |
| 不设相似度阈值 | 低分噪声片段也进 Prompt | 按业务数据标定阈值，低于即拒答 |
| 缓存不随库失效 | 文档更新后仍返回旧答案 | 缓存键绑定库版本，更新即失效 |

## 相关文档

- [[AI大模型开发]] — 大模型原理与开发笔记总入口（Transformer/微调/推理基础）
- [[AI-Dev-KB-Home]] — AI 开发实战专题库首页（本课程文档地图）
- [[GraphRAG知识图谱增强实战]] — 当向量相似度不够用时的知识图谱增强方案
- [[LoRA参数高效微调实战]] — 与 RAG 互补的参数微调路线
- [[LLM推理部署与量化]] — 生成与嵌入模型的高性能部署（优化十二式第 6 式展开）
- [[Prompt-Engineering入门与Demo]] — RAG Prompt 模板设计的提示词工程基础

## 参考资料

> [!info] 以下 URL 均为本文写作时经 web_search 实际检索核对的公开资料（检索日期 2026-08-25）。

- Ragas 官方文档 — v0.1.x 评估用法（evaluate + 小写指标导入）：<https://docs.ragas.io/en/v0.1.21/getstarted/evaluation.html>
- Ragas 官方迁移指南 — v0.1 → v0.2 API 变化（类式指标）：<https://github.com/vibrantlabsai/ragas/blob/main/docs/howtos/migrations/migrate_from_v01_to_v02.md>
- Ragas 指标参考（faithfulness/answer_relevancy/context_precision 定义）：<https://eval-hub.github.io/adapters/ragas/metrics/>
- BAAI bge-large-zh-v1.5 官方模型卡（含 bge-reranker 搭配建议）：<https://www.modelscope.cn/models/BAAI/bge-large-zh-v1.5>
- Moka AI m3e-base 官方模型卡：<https://huggingface.co/moka-ai/m3e-base>
- 中文 RAG 嵌入模型选型与 C-MTEB 对比：<https://github.com/ForceInjection/AI-fundamentals/blob/main/07_rag_and_tools/rag_basics/chinese_rag_embedding_model_selection.md>
- DeepSeek API 官方文档（Chat Completions 接口）：<https://api-docs.deepseek.com/zh-cn/api/create-chat-completion/>
- DeepSeek-V3 参数与训练成本报道（Demo 文档中 671B/557 万美元数字来源）：<http://www.c114.com.cn/ai/5339/a1281091.html>
