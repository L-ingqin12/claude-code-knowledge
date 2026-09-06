---
title: Claude Code auto-mode 分类器缓存分析（security monitor）
aliases: [分类器缓存, auto-mode classifier cache, security monitor 缓存]
tags: [ai/ops, ai/agent]
created: 2026-09-06
updated: 2026-09-06
status: review
---

# Claude Code auto-mode 分类器缓存分析

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-relay-design]] · [[cache-relay-deployed]] · [[claude-cache-optimization]]

> 背景：cache-relay 部署后命中率仍锁死在 ~52%（21:00-22:00：16.39M 命中 / 15.22M 未命中）。dump 定位到根因：两条「世系」在 DeepSeek 隐式前缀缓存里互相驱逐。

---

## 一、根因（dump 实证）

relay 的锚点 dump（`~/.cache-relay/dump.jsonl`，后已清除）抓到 5 条请求、**2 个唯一指纹**、交替出现：

| 指纹 | 类型 | tools | system |
|---|---|---|---|
| `b791e1f46fb6` | 主会话 | 45 个（含 13 个 `mcp__codebase-memory-mcp__*`） | "You are Claude Code..." |
| `effb55f14385` | **auto-mode 权限分类器** | 0 个 | "You are a security monitor for autonomous AI coding agents..." |

序列：`主会话 → 分类器 → 分类器 → 主会话 → 分类器`。两条世系前缀不同、交替送达 → DeepSeek byte-0 隐式缓存互相驱逐 → 命中率钉在 ~52%。

## 二、公开知识（分类器机制，来源见文末）

- **分类器是独立模型**：原生跑 **Sonnet 4.6**（即使主会话用别的模型）。独立模型 = 独立缓存命名空间，天然不与主会话互顶。
- **两阶段**：Stage 1 快速 yes/no（`max_tokens=64`+stop seq）；Stage 2 思考（仅 Stage 1 报警触发）。两者共享 system+transcript 前缀，Stage 2 命中 Stage 1 缓存。
- **缓存设计**：system prompt / CLAUDE.md / action blocks 用 `cache_control`（Anthropic 显式，1h TTL）。
- **Tier 3 才过分类器**：shell、web fetch、外部工具、subagent 派生、项目外文件操作；项目内读写（Tier 1/2）不过分类器。
- **推理盲**：分类器只看 user 消息 + tool 调用，不看 assistant 正文和 tool 结果。
- `autoMode.classifyAllShell`（v2.1.193+）：把所有 shell 命令都送分类器（否则部分安全 shell 可跳过）。

## 三、为什么在 DeepSeek 链路上失效

| 环节 | 原生 Anthropic | 用户 DeepSeek 链路 |
|---|---|---|
| 分类器模型 | Sonnet 4.6（独立模型） | deepseek-v4-pro（与主会话同模型） |
| 缓存隔离 | 不同模型 → 不同 cache 命名空间 | 同模型 + 同 key → 共享一个缓存 |
| 缓存标记 | `cache_control` 1h TTL | relay `stripCacheControl` 剥掉 → 退回隐式前缀 |

**结论**：原生设计靠「不同模型 + cache_control」隔离分类器缓存；用户链路把它俩拍扁成「同一个 deepseek-v4-pro + 隐式前缀」，于是两条世系互顶。

## 四、修复方向

1. **降分类器频率（配置层，零安全风险，优先）**：关 `autoMode.classifyAllShell` / 收窄 auto-mode 规则，减少 shell 命令触发分类器。coding agent shell 极高频，这是频率主因。
2. **relay 分流分类器到独立缓存（有安全折中）**：relay 识别「0 tools + system 含 `security monitor`」→ 改投独立上游（复用 GLM fallback）。恢复原生「独立缓存」隔离，主会话命中率应回 ~85%+。**代价**：分类器从 Sonnet 4.6 降到 GLM，安全判断力下降——省钱 vs 安全的权衡，需用户拍板。
3. **修分类器报错**：`Request was aborted`（疑似 DeepSeek 400 内容审核，分类器 transcript 含敏感内容）→ 分流 GLM 或 sanitize。

## 五、结论一句话

~52% 不是前缀漂移，是「分类器本该用独立模型隔离缓存，被同一条 deepseek 链路拍扁后和主会话互顶」。最干净解 = 让 relay 识别分类器并分流到独立上游（用户已有 GLM fallback）。

## 来源

- [Auto mode for Claude Code（官方博客）](https://claude.com/blog/auto-mode)
- [Configure auto mode（官方文档）](https://code.claude.com/docs/s/claude-code-auto-mode)
- [permission-modes.md（社区镜像）](https://github.com/ericbuess/claude-code-docs/blob/main/docs/permission-modes.md)
- [Claude Code 源码揭秘：2 阶段分类](https://cloud.tencent.cn/developer/article/2653444)
- [Simon Willison: Auto mode](https://simonwillison.net/2026/mar/24/auto-mode-for-claude-code/)
