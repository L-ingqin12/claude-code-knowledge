---
title: 家庭网络知识库
aliases: [MOC, 网络知识库, Network KB, 000 Home]
tags: [moc, network, network/moc]
cssclass: dashboard
created: 2026-07-27
updated: 2026-09-06
status: stable
---

# 家庭网络知识库

> [!abstract] 概述
> Dell G3 3590 + Xiaomi R4CM + v2rayN/xray 的完整网络优化知识库。
> 覆盖 WiFi 层、路由器层、代理策略层、协议层的诊断、优化与自动化。

## 快速导航

| 入口 | 说明 |
|------|------|
| 🚀 [[GUIDE]] | 日常使用指南 — 从这里开始 |
| 📋 [[FINAL-SUMMARY]] | 完整优化总结（含公开知识支撑） |
| 🏗️ [[ARCHITECTURE]] | 架构设计 — 4 阶段演进 + 7 个核心决策 |
| 🐛 [[OPTIMIZATION-AUDIT]] | 4 层 15 项优化 + 6 个设计漏洞 |
| 📡 [[ROUTER-FULL-CAPABILITY]] | 路由器完全能力手册 |
| 🔬 [[ROUTER-DEEP-EXPLORATION]] | 路由器深度探索报告 |
| 🔧 [[ROUTER-OPTIMIZATION]] | 路由器优化分析 |
| 📹 [[ROUTER-VIDEO-REMOTE-MONITOR]] | 远程视频监控 — 视频 QoS/远程访问/流量监测 |
| 🔍 [[network-analysis-2026-07-28]] | 初始 4 层瓶颈诊断 |
| 🐛 [[v2rayn-balancer-复盘-2026-08-09]] | Google 无法访问事故复盘（v2rayN balancer 生成 bug + watcher 修复） |
| 🛡️ [[参考-ClaudeCode网络韧性]] | Claude Code 网络韧性摘要（socket keepalive 四层消除 / 代理门控 / conntrack P0） |
| 🗂️ [[SESSION-ARCHIVE-2026-07-28]] | 会话归档 — 2026-07-27~28 全流程记录 |

## 文档关系图

![[Network-DocGraph.excalidraw]]

> 在 Obsidian Graph 视图中也可直接查看文档间 Wikilinks 关系网络。

## 按标签浏览

| 标签 | 文档 |
|------|------|
| `#network/router` | [[ROUTER-FULL-CAPABILITY]], [[ROUTER-DEEP-EXPLORATION]], [[ROUTER-OPTIMIZATION]] |
| `#network/proxy` | [[ARCHITECTURE]], [[OPTIMIZATION-AUDIT]], [[FINAL-SUMMARY]], [[参考-ClaudeCode网络韧性]] |
| `#network/guide` | [[GUIDE]] |
| `#network/analysis` | [[network-analysis-2026-07-28]], [[OPTIMIZATION-AUDIT]], [[v2rayn-balancer-复盘-2026-08-09]] |
| `#network/moc` | 本页 |

## 关键数据

| 数据 | 值 |
|------|-----|
| 笔记本 | Dell G3 3590, QCA9377, 驱动 12.0.0.1118 |
| 路由器 | Xiaomi R4CM [IP已脱敏], fw 2.14.87, SSH root@22 |
| 代理 | v2rayN + xray 26.3.27, 端口 10808, balancer 池 SG1/US1/US3/JP1（watcher 自动修规则） |
| 延迟改善 | 541ms → 113ms (-79%) |
| 状态 | ✅ 代理多节点, ✅ 路由器已调优, ⚠️ WiFi 驱动待更新 |

## 脚本

所有脚本和配置位于 `scripts/`：
- `enhance-config.ps1` — 增强脚本（当前方案）
- `v2rayn-config-hook.ps1` — FileSystemWatcher Hook（备选）
- `router_ssh.sh` — 路由器 SSH Wrapper
- `xray-config-v2-working.json` — 当前生效配置

## Dataview 仪表盘

> [!info] 需要启用 Obsidian 插件: Dataview
> 以下查询覆盖**整个知识库**（`knowledge/` 全部目录），自动从 frontmatter 提取数据。

### 全库文档（按状态）

```dataview
TABLE status, tags, file.folder as "目录"
WHERE status
SORT status ASC, file.name ASC
```

### 网络子库文档

```dataview
TABLE status, updated
FROM "network"
WHERE status
SORT updated DESC
```

### 待办任务

```dataview
TASK
WHERE !completed
SORT file.name ASC
LIMIT 20
```

### 最近更新 Top 15

```dataview
TABLE updated, file.folder as "目录"
WHERE updated
SORT updated DESC
LIMIT 15
```

## Agent 协作

本 Vault 包含 [[AGENTS]] 定义了 AI 协作规范。关键规则：
- 遵循 Wikilinks 进行关联探索
- 新文档必须包含 frontmatter + 嵌套标签
- 修改后更新 `updated` 字段和反向链接

> [!tip] 安装 Dataview 插件后，上方查询自动填充。无需额外配置。
