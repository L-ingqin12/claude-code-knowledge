---
title: GraphRAG知识图谱增强实战
aliases: [GraphRAG实战, 知识图谱RAG, 图谱增强检索, Microsoft GraphRAG]
tags: [ai, ai/learning]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# GraphRAG知识图谱增强实战

> 一句话定位：GraphRAG（Graph + Retrieval-Augmented Generation，图谱增强检索生成）把文档语料先构建为"实体-关系"知识图谱再回答，补上向量 RAG 跨文档多跳推理失效与全局性总结（Global Question）两大短板。

> [!abstract]
> 本文对应课程第 26 章：从传统 RAG 的两大痛点出发，介绍知识图谱三元组、GraphRAG 产品对比（Microsoft GraphRAG/LightRAG/neo4j-llm）、环境部署与核心参数配置，随后逐层拆解 Index 索引源码流程（实体关系抽取 → Leiden 社区检测 → 社区报告）与 Query 查询流程（Local Search vs Global Search），并以"10 条 Cypher 常用语句 + networkx 迷你实现"代替昂贵的真实索引跑通教学闭环。原理图嵌入 `GraphRAG-Flow.excalidraw`（见 [[#原理剖析]]）。前情见 [[RAG检索增强生成实战]]，框架编排对比见 [[LangChain-LangGraph框架实战]]。

## 核心概念

### 传统 RAG 的两大痛点

| 痛点 | 典型问题 | 失败原因 |
|------|----------|----------|
| 跨文档多跳推理失效 | "《三体》作者刘慈欣的母校是哪所大学？" | 答案需要"刘慈欣 → 作者 → 学校"跨多个片段的推理链，向量相似度只召回局部相似片段，拼不出推理路径 |
| 全局性总结问题（Global Question） | "这个数据集主要讲了哪些主题？" | 这类问题需要对**整个语料**归纳，而不是找某个最相似的片段；TopK 检索只返回局部片段，天然答不了 |

### 什么是知识图谱

知识图谱（Knowledge Graph）用三元组（Triple）描述世界：`(实体, 关系, 实体/属性值)`。

| 组成 | 说明 | 示例 |
|------|------|------|
| 实体（Entity） | 现实世界中的对象或概念 | 张三、GraphRAG、微软 |
| 关系（Relation） | 实体之间的语义连接 | 任职于、开发了、是同事 |
| 属性（Attribute） | 实体的特征键值对 | 张三.职位 = 研发工程师 |

把语料抽成图谱后，"跨多跳推理"变成图上的路径搜索（多跳可达），"全局总结"变成对图社区（Community）的归纳——这正是 GraphRAG 的思路。

### GraphRAG 产品对比

| 产品 | 特点 | 适用 |
|------|------|------|
| Microsoft GraphRAG | 微软开源，Leiden 社区检测 + 社区报告，Local/Global 双查询模式，功能最全 | 企业级、追求效果上限 |
| LightRAG | 轻量级，双粒度（实体/关系 + 原 chunk）检索，图结构更简单、成本更低 | 中小项目快速落地 |
| neo4j-llm | Neo4j 官方 LLM 生态（LLM Knowledge Graph Builder / neo4j-graphrag Python 包），从非结构化文本抽取实体关系建图并查询 | 已有 Neo4j 基建的团队 |

### 环境部署与核心参数配置

**安装**：`pip install graphrag`，然后 `graphrag init --root ./ragtest` 生成 `settings.yaml` 等配置骨架；把文档放入 `input/` 后 `graphrag index` 建索引、`graphrag query` 提问。

**indexing 相关参数**（控制建索引）：

| 参数 | 所属 | 说明 |
|------|------|------|
| entity_extraction | LLM 调用 | 实体/关系抽取的提示词与模型配置，含 gleanings（多轮补抽）次数 |
| community_detection | 图算法 | Leiden 分层社区检测参数，如 max_cluster_size、resolution |
| claims | 抽取选项 | 是否抽取"声明"（claims）并附到实体，用于事实核查 |
| chunk size / overlap | 切分参数 | 文本切分窗口大小与重叠，默认约 1200/100 token |

**query 相关参数**（控制查询方式）：

| 参数 | 说明 |
|------|------|
| local_search | 局部检索：围绕少量相关实体展开邻居与社区报告，答具体问题 |
| global_search | 全局检索：Map-Reduce 遍历社区报告归纳，答宏观问题 |
| community_level | 用哪一层级的社区报告（分层聚类产生多层社区） |

### Microsoft GraphRAG 原理总览

GraphRAG 分两阶段：**Index（离线建索引）** 把文档语料转成"知识图谱 + 社区报告 + 向量索引"三件套；**Query（在线查询）** 用 Local Search 或 Global Search 从这三件套里组织证据生成答案。索引阶段是成本大头（每篇文档多次 LLM 调用），查询阶段则与索引产物解耦。

## 原理剖析

![[GraphRAG-Flow.excalidraw]]

> [!info] 图解 GraphRAG 两条管道
> 图左侧是 **Index 索引管道**：文档加载切分后，LLM 从 chunk 中抽取实体与关系，去重合并成知识图谱（KG），随后 Leiden 算法对图谱做分层社区检测，再逐层调用 LLM 为每个社区生成"社区报告"（Community Report），最后把实体/关系/报告全部向量化，形成完整索引。图右侧是 **Query 查询管道**，分上下两支：上支 Local Search（实体匹配 → 邻居展开 → 社区报告 → 提示词 → 生成）答具体细节问题；下支 Global Search（Map-Reduce 遍历社区报告）答宏观总结问题。

### Index 源码流程九步

1. **初始化（init）**：`graphrag init` 生成 `settings.yaml`、`.env`（模型 key）、`input/` 目录与默认提示词。
2. **文档加载（格式与策略）**：支持文本/CSV/JSON，CSV 可指定列作为正文；策略上要求文档自带标题/边界，便于后续切分与溯源。
3. **文本切分（chunk size/overlap）**：按 token 窗口切 chunk（默认约 1200 token、100 token overlap），chunk 是实体抽取的最小输入单元。
4. **实体和关系抽取（LLM + 提示词）**：每个 chunk 调用 LLM，按"实体类型/描述"提示词抽 `(实体, 关系, 实体)` 三元组，多轮 gleanings 补漏。
5. **实体关系摘要生成**：同名实体/关系跨 chunk 合并去重，LLM 为每个实体生成一条综合描述（摘要）。
6. **社区检测（Leiden 分层聚类）**：在图谱上用 Leiden 算法（分层社区检测算法）迭代聚类，产出大社区套小社区的多层社区结构。
7. **合并知识图谱**：把分散在各 chunk 的抽取结果合并为全局一致的实体表、关系表与声明表（parquet 格式）。
8. **社区报告生成（逐层 LLM 摘要）**：对每一层社区，LLM 汇总该社区成员与关系，生成标题、摘要、评分（rating）等报告。
9. **索引结构向量化**：实体描述、关系描述、报告文本分别嵌入，形成向量索引，供查询阶段实体匹配与报告召回。

### Query 源码篇：Local vs Global

| 维度 | Local Search | Global Search |
|------|--------------|---------------|
| 流程 | 用户问题 → 实体匹配 → 邻居展开 → 取社区报告 → 构建提示词 → 生成 | 用户问题 → Map（各社区报告独立回答）→ Reduce（汇总归纳）→ 生成 |
| 证据来源 | 少量相关实体 + 一跳邻居 + 所在社区报告 + 相关文本单元 | 全部（或抽样）社区报告 |
| 适合问题 | 具体细节："张三参与了哪些项目？" | 宏观总结："这个数据集主要主题是什么？" |
| 成本 | 低：只动局部 | 高：遍历全量报告，Map-Reduce 多轮 LLM 调用 |

### 静态社区 vs 动态社区

- **静态社区（Static Community）**：Index 阶段一次性算好的 Leiden 社区，索引产物固化；查询时直接使用，零额外计算，但知识库更新需重建索引才能反映新结构。
- **动态社区（Dynamic Community）**：查询时围绕问题相关实体**临时**做社区发现（如局部 Leiden/谱聚类），能适配实时变化的图谱与个性化问题，代价是每次查询都要付一次图算法开销。GraphRAG 默认走静态社区，增量更新场景可考虑动态方案。

## 最小可运行 Demo

> [!info] 说明
> 真实索引成本高（每 chunk 数次 LLM 调用，全量语料常需数小时 + 大量 token），本文用两段替代教学闭环：①Neo4j 中操作图谱的 10 条常用 Cypher 语句；②networkx 实现"实体抽取 → 建图 → 社区发现 → 局部查询"迷你版（LLM 抽取可接 DeepSeek）。

### ① 10 条常用 Cypher 语句清单

```cypher
// 1. 创建实体节点（带属性）
CREATE (:Entity {id: "张三", type: "person", description: "研发工程师"});

// 2. 在两个实体间创建关系
MATCH (a:Entity {id: "张三"}), (b:Entity {id: "GraphRAG"})
CREATE (a)-[:RELATED {description: "参与"}]->(b);

// 3. 批量导入 entities 表（GraphRAG 输出 parquet 导出 csv 后）
LOAD CSV WITH HEADERS FROM 'file:///entities.csv' AS row
CREATE (:Entity {id: row.id, type: row.type, description: row.description});

// 4. 批量导入 relationships 表
LOAD CSV WITH HEADERS FROM 'file:///relationships.csv' AS row
MATCH (a:Entity {id: row.source}), (b:Entity {id: row.target})
CREATE (a)-[:RELATED {description: row.description, weight: toInteger(row.weight)}]->(b);

// 5. 创建社区节点并关联实体（communities 表）
LOAD CSV WITH HEADERS FROM 'file:///communities.csv' AS row
MATCH (e:Entity {id: row.entity})
MERGE (c:Community {id: row.community})
CREATE (e)-[:IN_COMMUNITY]->(c);

// 6. 导入社区报告并挂到社区节点（community_reports 表）
LOAD CSV WITH HEADERS FROM 'file:///community_reports.csv' AS row
MATCH (c:Community {id: row.community})
SET c.title = row.title, c.summary = row.summary, c.rating = toFloat(row.rating);

// 7. 查某实体的一跳邻居（局部证据展开）
MATCH (a:Entity {id: "张三"})-[r:RELATED]-(b)
RETURN a.id, r.description, b.id;

// 8. 查两跳路径（跨文档多跳推理）
MATCH p = (a:Entity {id: "张三"})-[*1..2]-(b)
RETURN p LIMIT 20;

// 9. 查实体所在社区及同社区其他实体
MATCH (a:Entity {id: "张三"})-[:IN_COMMUNITY]->(c:Community)<-[:IN_COMMUNITY]-(other)
RETURN c.id, collect(DISTINCT other.id);

// 10. 模糊/全文检索实体
MATCH (e:Entity)
WHERE e.id CONTAINS "张三" OR e.description CONTAINS "工程师"
RETURN e;
```

### ② networkx 迷你 GraphRAG（约 60 行）

```python
# -*- coding: utf-8 -*-
"""
迷你 GraphRAG 教学实现：实体抽取 → 建图 → 社区发现 → 局部查询
依赖: pip install networkx
生产环境把 extract() 换成 LLM 抽取(可调 DeepSeek)，此处用规则示例跑通全流程
"""
import networkx as nx

# 1. 语料（模拟多篇文档）
docs = [
    "张三是研发工程师，所在团队为数据智能组。",
    "张三参加了 GraphRAG 项目，GraphRAG 由微软开源。",
    "李四是张三的同事，负责向量检索模块。",
]

# 2. 实体/关系抽取：生产用 LLM 按提示词抽三元组，这里规则演示
def extract(docs):
    triples = []
    for d in docs:
        if "张三" in d and "工程师" in d:
            triples.append(("张三", "职位", "研发工程师"))
        if "张三" in d and "数据智能组" in d:
            triples.append(("张三", "所属", "数据智能组"))
        if "张三" in d and "GraphRAG" in d:
            triples.append(("张三", "参与", "GraphRAG"))
        if "GraphRAG" in d and "微软" in d:
            triples.append(("GraphRAG", "开发者", "微软"))
        if "李四" in d and "张三" in d:
            triples.append(("李四", "同事", "张三"))
        if "李四" in d and "向量检索" in d:
            triples.append(("李四", "负责", "向量检索"))
    return triples

triples = extract(docs)
print("抽取三元组:", triples)

# 3. 建图：实体=节点，关系=边（对应 Index 管道的知识图谱）
G = nx.Graph()
for h, r, t in triples:
    G.add_edge(h, t, relation=r)

# 4. 社区发现：Louvain 简化版（对应 GraphRAG 的 Leiden 分层聚类）
communities = nx.community.louvain_communities(G, seed=42)
for i, c in enumerate(communities):
    print(f"社区{i}: {sorted(c)}")

# 5. 局部查询：实体匹配 → 邻居展开 → 组装证据（对应 Local Search）
def local_search(G, entity, depth=1):
    if entity not in G:
        return []
    seen = {entity}
    frontier = {entity}
    for _ in range(depth):                      # BFS 收集 depth 跳内邻居
        frontier = {nb for n in frontier for nb in G.neighbors(n)} - seen
        seen |= frontier
    evidence = []
    for h, t, d in G.edges(data=True):          # 邻居相关边作为证据
        if h in seen or t in seen:
            evidence.append(f"{h} --{d['relation']}--> {t}")
    return evidence

q = "张三参与了什么项目？"
matched = [n for n in G.nodes if "张三" in n]   # 向量/模糊匹配实体
print("\n问题:", q)
print("匹配实体:", matched)
print("局部证据:", local_search(G, matched[0]))
# 6. 收尾（生产做法）：把 evidence 拼进 Prompt 交给 LLM 生成答案
```

## 进阶实践与常见坑

### 图数据库篇：Neo4j 落地要点

- **创建节点与属性**：`CREATE (:Entity {id: "张三", type: "person", description: "..."})` —— 节点标签（Label）定类型，`{}` 内是属性键值对。
- **创建关系与属性**：`MATCH ... CREATE (a)-[:RELATED {description: "参与"}]->(b)` —— 关系同样可带属性（描述、权重）。
- **导入 GraphRAG 产物**：`entities.csv` → 建 Entity 节点；`relationships.csv` → 建 RELATED 边；`communities.csv` → 建 Community 节点并连 `IN_COMMUNITY` 边；`community_reports.csv` → 用 `SET` 把报告字段挂到社区节点（见 Demo ① 语句 3~6）。
- **建索引加速**：`CREATE INDEX entity_id FOR (e:Entity) ON (e.id)`，批量导入前先建索引，避免逐行全表扫描。

### 常见坑速查

| 坑 | 症状 | 对策 |
|----|------|------|
| 抽取成本失控 | 全量语料索引跑数小时、token 账单惊人 | 先小语料试跑校准提示词；分层抽取（先标题后正文）；用 LightRAG 降本 |
| 实体爆炸/粒度混乱 | "张三"和"张三先生"被当两个实体 | 提示词限定实体类型清单 + 合并步骤去重；必要时加实体消歧 |
| 社区报告空泛 | 报告千篇一律，回答没增量信息 | 调 community_detection 的 resolution/max_cluster_size，报告提示词要求量化细节 |
| 把 GraphRAG 当默认方案 | 简单单跳问答反而更贵更慢 | 先 RAG 后 GraphRAG：单跳用向量检索，多跳/全局问题再上图谱 |
| Local Search 证据不足 | 邻居展开为空，答案退化成通用回复 | 实体匹配加模糊/别名召回；降低 community_level 用更大社区报告兜底 |
| 索引与查询模型不一致 | 实体匹配向量与索引向量来自不同模型 | 全链路锁定同一 embedding 模型与版本（同 RAG 坑） |

## 相关文档

- [[AI大模型开发]] — 大模型原理与开发笔记总入口
- [[AI-Dev-KB-Home]] — AI 开发实战专题库首页（本课程文档地图）
- [[RAG检索增强生成实战]] — 向量 RAG 全流程与选型，GraphRAG 的出发点
- [[LangChain-LangGraph框架实战]] — 框架编排能力，图状态机视角看 Local/Global 双查询

## 参考资料

> [!info] 以下 URL 均为本文写作时经 web_search 实际检索核对的公开资料（检索日期 2026-08-25）。

- Microsoft GraphRAG 官方仓库 — Query 系统总览（Local/Global Search 机制）：<https://github.com/microsoft/graphrag/blob/main/docs/query/overview.md>
- Microsoft GraphRAG 官方仓库 — Index 数据流（切分/抽取/社区/报告）：<https://github.com/microsoft/graphrag/blob/main/docs/index/default_dataflow.md>
- Microsoft GraphRAG 默认配置源码（chunks 默认 1200/100 出处）：<https://github.com/microsoft/graphrag/blob/main/graphrag/config/defaults.py>
- GraphRAG settings.yaml 核心参数配置详解：<https://blog.csdn.net/wayle123/article/details/159380356>
- GraphRAG 社区规模参数（community_detection）：<http://theneuralbase.com/graphrag/learn/beginner/community-size-parameters/>
- GraphRAG chunk size 对实体抽取的影响：<https://theneuralbase.com/graphrag/learn/intermediate/chunk-size-impact-on-extraction/>
- LightRAG 双粒度图检索介绍（阿里云开发者社区）：<https://developer.aliyun.com/article/1691105>
- Neo4j LLM Knowledge Graph Builder 官方开发者指南：<https://neo4j.com/developer/genai-ecosystem/llm-graph-builder/>
- Neo4j 官方教程 — 用 Cypher 导入 CSV：<https://neo4j.ac.cn/graphgists/importing-csv-files-with-cypher/>
- Neo4j graphgist — 数据导入实践：<https://neo4j.com/graphgists/0123-importing-data/>
- networkx 官方文档 — louvain_communities 函数：<https://networkx.org/documentation/stable/reference/algorithms/generated/networkx.algorithms.community.louvain.louvain_communities.html>
