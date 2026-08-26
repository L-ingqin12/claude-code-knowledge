---
title: CS-KB-Home
aliases: [计算机基础库, CS知识库, cs-base-MOC]
tags: [moc, cs]
created: 2026-08-26
updated: 2026-08-26
status: review
---

# CS-KB-Home — 计算机基础子库 MOC

> [!abstract] 定位
> 语言（C++）、算法（数据结构/深度学习）、系统（OS/网络/高并发）三大主干的知识底座。面向**面试八股 + 工程选型**双用途；AI 应用层实战在 [[AI-Dev-KB-Home]]，网络运维实操在 [[Network-KB-Home]]，两处互链不重复。

## 文档地图

| 文档 | 主题 | 一句话 |
|------|------|--------|
| [[CPP-核心知识]] | 语言 | RAII/移动语义/模板/concepts/内存模型六档 |
| [[数据结构与算法]] | 算法 | 结构选型表+复杂度速查+十大题型骨架 |
| [[深度学习算法基础]] | AI 算法 | MLP→Transformer 最小链+归一化+训练排障表 |
| [[操作系统八股]] | 系统 | 进程线程/虚拟内存/锁层级/epoll→io_uring |
| [[计算机网络八股]] | 网络 | TCP 可靠性/TLS1.3/HTTP1.1→3/DNS |
| [[高并发系统设计]] | 架构 | C10K→C10M/缓存三级/限流熔断降级/分片 |

## 关系树

```
CS-KB-Home (本页)
├─ 语言: CPP-核心知识 ──▶ 参考-CPP-CPO定制点与std-execution(专题)
│                    └─▶ 参考-COM组件框架-Windows集成(平台专题)
├─ 算法: 数据结构与算法 ─┬─▶ 深度学习算法基础 ─▶ AI大模型开发(手推导)
│                       └─▶ lognet-rootcause(图遍历工程映射)
├─ 系统: 操作系统八股 ─┬─▶ 计算机网络八股
│                      ├─▶ 高并发系统设计
│                      └─▶ log-analysis-agent-windows-architecture(实践)
└─ 横向: 全部 ▶ opencode-pi-base-development-analysis(Sidecar 工程消费方)
```

## 标签索引

- `#cs/cpp` — C++ 语言与专题
- `#cs/algo` — 数据结构与算法
- `#cs/dl` — 深度学习算法
- `#cs/os` / `#cs/net` / `#cs/system` — 系统三件套

## 阅读线索

- **面试冲刺** → 三篇八股（OS/网络/高并发）+ [[数据结构与算法]] §三题型骨架
- **C++ 深化** → [[CPP-核心知识]] → [[参考-CPP-CPO定制点与std-execution]]
- **转 LLM 工程** → [[深度学习算法基础]] → [[AI大模型开发]] → [[LLM-Agent开发基础]]

See also: [[AGENTS]] · [[Claude-Ops-KB-Home]] · [[SESSION-ARCHIVE-2026-08-26]]
