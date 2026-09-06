---
title: HOME — 知识库全局目录索引
aliases: [知识库首页, 全局索引, KB Home, Vault Home]
tags: [moc, meta]
created: 2026-09-06
updated: 2026-09-06
status: stable
---

# HOME — 知识库全局目录索引

> [!abstract] 定位
> 本文件是整个知识库（Vault）的**全局导航入口**：列出全部子目录、各自的一句话主题与 MOC/入口。
> AI 协作规范与协议见 [[AGENTS]]；各子库内部导航请进入各自 MOC。

## 目录结构速览

| 目录 | 一句话主题 | 入口 / MOC |
|------|-----------|-----------|
| `network/` | 家庭网络优化：WiFi / 小米路由器 / v2rayN 代理 / 排障与复盘 | [[Network-KB-Home]] |
| `ai-dev/` | LLM 应用开发实战：Prompt / RAG / Agent / MCP / 微调 等专题 | [[AI-Dev-KB-Home]] |
| `ai-links/` | AI 链接收藏与调研综述（含 DSH 插件/Hook、编码 Agent 调研报告） | [[AI-Links-KB-Home]] · [[Articles-Index]] |
| `claude-ops/` | Claude Code 无人值守运维：方案设计 / 事故复盘 / Agent 架构模式 | [[Claude-Ops-KB-Home]] · [[MEMORY-INDEX]] |
| `cs-base/` | 计算机基础：语言 / 算法 / 系统 / 数据库 / 工具链 | [[CS-KB-Home]] |
| `typora/` | Typora 无补丁激活复盘与可复用流程 | [[TYPORA-KB-Home]] |
| `diagrams/` | Excalidraw 图表库（绘图规范：禁 Mermaid） | [[ARROW-CHECKLIST]] |
| `scripts/` | 跨库脚本：claude-ops-deployments / dumps / lognet-poc | `scripts/claude-ops-deployments/README.md` |
| `_archive/` | SESSION-ARCHIVE 会话归档（原根目录 SESSION-*.md 已归入） | `_archive/` 目录 |
| `Excalidraw/` | 早期散装 Excalidraw 原图 | — |

## 根目录松散文件

归档后根目录仅剩两个 .md：

- [[AGENTS]] — 知识库 AI 协作规范（按治理约束保留在根目录的唯一原始松散 .md）
- [[HOME]] — 本全局索引文件

> [!note] 根目录非 .md 残留
> 根目录仍存在若干**非知识文档**文件，未纳入本次归档：`SDL2*.dll`、`avcodec-* / avformat-* / swscale-5 / swresample-3 / avutil-56 / avdevice-58 / avfilter-7` 等 DLL（疑似误置于库根的运行时库），以及 gitignore 的临时目录 `__pycache__/`、`_install-tmp/`。建议由人工确认后清理或移动。

## 2026-08 松散文件归档记录

原根目录松散 .md 已按主题归档。库内链接均为 basename 形式 `[[文件名]]`（全库唯一），移动不破坏任何双链。

| 原根目录文件 | 归档去向 |
|---|---|
| `2026-07-21-树莓派网络故障与路由器破解完整复盘.md` | `network/` |
| `参考-VPN代理诊断与优化.md` | `network/` |
| `参考-小米路由器API认证与利用.md` | `network/` |
| `参考-网络路由与代理排障.md` | `network/` |
| `AI大模型开发.md` | `ai-dev/` |
| `参考-Ark-Agent-Plan计费与配置.md` | `ai-dev/` |
| `参考-COM组件框架-Windows集成.md` | `cs-base/` |
| `参考-CPP-CPO定制点与std-execution.md` | `cs-base/` |
| `参考-OpenCode-技术调研报告.md` | `ai-links/` |
| `参考-Pi-Agent-技术调研报告.md` | `ai-links/` |
| `SESSION-ARCHIVE-2026-08-18.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-25.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-26.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-28.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-30.md` | `_archive/` |
