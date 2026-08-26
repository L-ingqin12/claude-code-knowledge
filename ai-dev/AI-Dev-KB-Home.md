---
title: AI Dev KB Home — LLM 应用开发实战专题库
aliases: [AI开发MOC, LLM应用开发首页, AI-Dev-KB]
tags: [ai, moc, ai/learning]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# AI Dev KB Home

> [!abstract] 本子库定位
> 《AI大模型应用开发工程师》课程体系的知识库落盘：**一文档一问题**，每个专题独立成文、可运行 Demo 齐备、图表统一 Excalidraw。
> 理论基础（Transformer 手推/术语解析/源码）见 [[AI大模型开发]]；本页是实战层的总入口。

## 文档地图

| # | 专题文档 | 一句话解决的问题 | 配套图 |
|---|----------|------------------|--------|
| 1 | [[Prompt-Engineering入门与Demo]] | 如何写出稳定可控的 prompt（few-shot/LtM/CoT/结构化输出） | — |
| 2 | [[Function-Calling工具调用实战]] | 让模型"说→做"：双轮调用与四大进阶挑战 | ![[Function-Calling-Sequence.excalidraw]] |
| 3 | [[RAG检索增强生成实战]] | 私域知识问答：架构演进/选型/性能优化/评估 | ![[RAG-Pipeline.excalidraw]] |
| 4 | [[GraphRAG知识图谱增强实战]] | 全局性/多跳问题：实体抽取+社区检测+Local/Global Query | ![[GraphRAG-Flow.excalidraw]] |
| 5 | [[LLM-Agent开发基础]] | Agent 四组件与手写 ReAct 循环 | ![[ReAct-Agent-Loop.excalidraw]] |
| 6 | [[MCP协议开发实战]] | 工具生态标准化：Server/Client/三种传输 | ![[MCP-Architecture.excalidraw]] |
| 7 | [[A2A多智能体协作协议]] | 跨框架 Agent 互操作：Agent Card/Task/委托 | — |
| 8 | [[LangChain-LangGraph框架实战]] | LCEL 与状态机式 Agent：State/Checkpointer/Supervisor | ![[Multi-Agent-Supervisor.excalidraw]] |
| 9 | [[LLM推理部署与量化]] | Ollama/vLLM/Ray 多机多卡与量化选型 | ![[Training-vs-Inference.excalidraw]]（复用） |
| 10 | [[LoRA参数高效微调实战]] | 低秩旁路微调原理 + Llama-Factory 实操 + 监控指标 | ![[LoRA-Principle.excalidraw]] |
| 11 | [[强化学习对齐-RLHF到GRPO]] | PPO/DPO/GRPO 对齐算法谱系与奖励模型 | ![[RLHF-GRPO-Pipeline.excalidraw]] |
| 12 | [[微调数据工程与模型蒸馏]] | SFT/COT/偏好数据集构建 + R1 式黑箱蒸馏 | ![[Training-vs-Inference.excalidraw]]（复用） |
| 13 | [[Agent-Skills技能开发实战]] | SKILL.md 规范与渐进式披露：给 Agent 写"说明书"（课程第13章补齐） | — |
| 14 | [[多模态Agent平台实战]] | 语音/视觉管线四层架构与延迟预算（课程第21章补齐） | — |
| 15 | [[LLM架构进阶-从注意力变体到推理引擎]] | MHA/GQA/MLA 演化账本、RoPE 外推、MoE 工程真相、连续批处理/PagedAttention/投机解码机制级（2026-08-26 新增） | — |

## 课程外增补雷达（2026 时效性缺口）

> 课程内容相对行业演进存在滞后，以下主题按需展开（有 ✓ 者已在本库覆盖）：

| 主题 | 一句话要点 | 状态 |
|---|---|---|
| Prompt/Context Caching | 前缀缓存可省 75-90% 输入费用；DeepSeek 自动、Anthropic 显式断点 | ✓ 见 [[LLM推理部署与量化]] 缓存节 |
| Structured Outputs | JSON Schema 强约束输出，取代"请输出 JSON"祈祷式提示 | ✓ 见 [[Prompt-Engineering入门与Demo]] |
| Agent 可观测性 | Langfuse/LangSmith 追踪每次工具调用与 token 流水，评估驱动迭代 | ⏳ 待专题 |
| Guardrails 与安全护栏 | 注入防御、输出过滤、越权工具调用的白名单治理 | ⏳ 待专题（部分见 [[Agent-Skills技能开发实战]] allowed-tools） |
| Computer/Browser Use | 截图→定位→点击的 GUI 操作型 Agent，MCP 化浏览器控制 | ⏳ 待专题 |

## 学习路径（建议顺序)

```
理论基础 [[AI大模型开发]]
   ↓
② API 开发 → ④ 提示词/FC → ⑤ Agent 基础 (5→6→7)      ← 应用层主线
   ↘ ③ 部署 (9)                                        ← 自托管支线
   ↘ ⑦ RAG (3→4) → ⑥ 框架 (8)                          ← 知识增强主线
⑧ 微调 (12→10→11)                                      ← 定制化主线
   ↓
⑨ 大型项目综合演练
```

## 项目案例地图

| 课程项目 | 综合运用的知识点 | 相关专题 |
|----------|------------------|----------|
| ChatBI / iQuery Agent | Function Calling 调 MySQL + Python 解释器 + Memory + Planning | [[Function-Calling工具调用实战]] [[LLM-Agent开发基础]] |
| 企业智能问数系统 | Milvus + Neo4j + LangGraph 多智能体（意图识别/SQL生成/校验/执行/图表） | [[LangChain-LangGraph框架实战]] [[GraphRAG知识图谱增强实战]] |
| 高性能 RAG 商业项目 | 亿级语料入库 + rerank + Ragas 评估 + 联网问答 + Agent 化 RAG | [[RAG检索增强生成实战]] |
| 企业级智能体客服 v1/v2 | 压测 + 语义缓存 + minerU PDF 解析 + GraphRAG 工程化 + Multi-Agent 护栏 | [[LLM推理部署与量化]] [[GraphRAG知识图谱增强实战]] |

## 图表索引（diagrams/）

全部为 Excalidraw 格式，绘图规范见 [[AGENTS#十一、图表与可视化约定]] 与 [[ARROW-CHECKLIST]]：

`Function-Calling-Sequence` · `ReAct-Agent-Loop` · `RAG-Pipeline` · `GraphRAG-Flow` · `MCP-Architecture` · `Multi-Agent-Supervisor` · `LoRA-Principle` · `RLHF-GRPO-Pipeline`

## 标签索引

- `#ai/learning` — 教程型专题（1,3,4,9,10,11,12,14）
- `#ai/agent` — Agent/协议类（5,6,7,8,13）
- `#moc` — 本页

## 关联入口

- [[AI大模型开发]] — 理论根基与本子库的课程映射表（课程知识地图）
- [[AI-Links-KB-Home]] — AI 链接收藏库（工程方法论综述）
- [[Claude-Ops-KB-Home]] — Agent 运维实践（Harness Engineering 的真实战例）
