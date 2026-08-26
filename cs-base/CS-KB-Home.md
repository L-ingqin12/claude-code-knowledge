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
> 语言、算法、系统、数据、工具链五大主干的知识底座，面向**面试八股 + 工程选型 + 机制级深潜**三用途。AI 应用层实战在 [[AI-Dev-KB-Home]]，网络运维实操在 [[Network-KB-Home]]；项目实证锚点（LogNet PoC）织入各篇。

## 文档地图（18 篇）

### 语言与工具链
| 文档 | 一句话 |
|------|--------|
| [[CPP-核心知识]] | RAII/移动语义/模板→concepts/内存序 + **C++11→26 新特性纵深** |
| [[LibC与动态链接]] | glibc vs musl、ELF 加载旅程、GOT/PLT、静态容器化账单 |
| [[LibC运行时排查-TLS与锁]] | dlclose 陷阱/pthread_key 析构/TLS 四模型/futex 锁族/**排障手册** |
| [[LLVM编译器基础设施]] | 三段式架构/优化 pass/Sanitizer/LTO-PGO/DWARF 符号化(→LogNet M1) |
| [[LLVM使用调优与SO优化]] | flag 分层决策/SO 符号面-体积-启动-ABI 四维优化/PGO-LTO-BOLT/回归工作流 |

### 算法
| 文档 | 一句话 |
|------|--------|
| [[数据结构与算法]] | 选型表+复杂度速查+十大题型骨架 |
| [[深度学习算法基础]] | MLP→Transformer 最小链+训练排障表 |

### 数据库分册
| 文档 | 一句话 |
|------|--------|
| [[数据库原理与调优]] | B+/LSM 对决/MVCC 机制/WAL 恢复/调优方法论+SQLite 实测 |
| [[MySQL-InnoDB精要]] | Buffer Pool 内部/两阶段提交/锁全貌/EXPLAIN 判读 |
| [[Redis原理与实践]] | 结构编码映射/持久化双路线/Cluster/分布式锁 Redlock 争议 |
| [[MongoDB原理与实践]] | WiredTiger COW-MVCC/ESR 索引法则/副本集分片/选型边界 |
| [[向量数据库与检索]] | HNSW/IVF/PQ 机制级/过滤难题/RRF 混合检索/容量速算 |

### 系统
| 文档 | 一句话 |
|------|--------|
| [[计算机组成原理]] | 流水线乱序/存储层次/MESI/SIMD/TMA 性能方法论 |
| [[操作系统八股]] | 调度/虚拟内存/锁层级/epoll→io_uring 双轨 |
| [[计算机网络八股]] | TCP 可靠性/TLS1.3/HTTP1.1→3/DNS(RFC 挂链) |
| [[高并发系统设计]] | C10K→C10M/缓存三级/限流熔断/分片 |

### 方法论
| 文档 | 一句话 |
|------|--------|
| [[设计模式实战]] | 触发信号→完整代码走读→推理链→事故现场；模式被现代 C++ 吸收的演化表 |
| [[架构设计与方案选型]] | 质量属性场景化/风格约束推导/ADR 全文范例/加权矩阵敏感性检查/POC 闸门 |

## 关系树

```
CS-KB-Home (本页)
├─ 语言工具链: CPP ─┬─▶ 参考-CPP-CPO(std-execution 专题)
│                   ├─▶ LibC与动态链接 ◀──▶ LLVM基础设施(DWARF→LogNet M1 符号化)
│                   └─▶ 参考-COM组件框架(Windows)
├─ 算法: 数据结构算法 ─▶ 深度学习算法基础 ─▶ AI大模型开发(手推)
├─ 数据: 数据库总纲 ─┬─▶ MySQL精要 / Redis / MongoDB / 向量库(四分册)
│                    └─▶ SQLite 实测锚点=LogNet PoC 基准
├─ 系统: 组成原理 ◀─▶ 操作系统 ◀─▶ 计算机网络 ─▶ 高并发设计
└─ 横向消费方: opencode-pi-base-development-analysis / agent-memory-context(L3 向量混合检索)
```

## 标签索引

- `#cs/cpp` · `#cs/toolchain`(libc/LLVM) — 语言与底座
- `#cs/algo` · `#cs/dl` — 算法两侧
- `#cs/db` — 数据库五分册
- `#cs/arch` · `#cs/os` · `#cs/net` · `#cs/system` — 系统四件套

## 阅读线索

- **面试冲刺** → 三系统八股 + MySQL/Redis 分册 + [[数据结构与算法]] §三
- **后端深化** → [[数据库原理与调优]] 总纲 → 四分册按栈取用 → [[高并发系统设计]]
- **底层硬核** → [[计算机组成原理]] → [[LibC与动态链接]] ↔ [[LLVM编译器基础设施]]
- **转 LLM 工程** → [[深度学习算法基础]] → [[向量数据库与检索]] → [[RAG检索增强生成实战]]

See also: [[AGENTS]] · [[Claude-Ops-KB-Home]] · [[SESSION-ARCHIVE-2026-08-26]]
