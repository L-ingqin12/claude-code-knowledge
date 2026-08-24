---
title: Hermes 缓存分析 — 现状与优化方案
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-29
updated: 2026-08-25
status: review
---

# Hermes 缓存分析 — 现状与优化方案

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-strategy]] · [[2026-06-24-hermes-feishu-outage-postmortem]]

> 分析日期: 2026-06-29 | 环境: Raspberry Pi 4B | Hermes 通过 model-router → ARK API

---

## 一、请求链路

```
┌─────────────────────────────────────────────────────────────┐
│                      Hermes 请求链路                          │
│                                                             │
│  Hermes Agent (gateway/ranzi)                               │
│      │                                                      │
│      ▼                                                      │
│  Model-Router (:18888)  ← 五层分级 (L1→L5)                  │
│      │                                                      │
│      ├── L1: doubao-seed-2-0-mini  ──┐                      │
│      ├── L2: doubao-seed-2-0-lite  ──┤                      │
│      ├── L3: deepseek-v4-flash     ──┤→ ARK API (直连)      │
│      ├── L4: deepseek-v4-pro       ──┤  ark.cn-beijing      │
│      └── L5: deepseek-v4-pro       ──┘  .volces.com         │
│                                                             │
│  ❌ 不经过 Permafrost (:8788) — 无缓存优化                    │
│  ❌ 不经过 Resilience Proxy (:8787) — 无重试/keepalive       │
│                                                             │
│  对比 Claude Code:                                           │
│  CC → Permafrost :8788 → Proxy :8787 → DeepSeek             │
│       (缓存对齐)        (韧性)                               │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、为什么 Hermes 没有缓存

### 2.1 架构差异

| 维度 | Claude Code | Hermes |
|------|:----------:|:------:|
| 模型调用路径 | CC → permafrost → proxy → DeepSeek | Hermes → model-router → ARK |
| 缓存对齐 | permafrost (去 cache_control + 工具排序 + currentDate 稳定化) | 无 |
| 网络韧性 | proxy (重试3次 + keepalive 60s) | model-router 内置降级链 |
| 工具集 | 9 锚点 + ScheduleWakeup 等变数工具 (CC 原生) | 27+ tools (Hermes 全功能) |
| 模型分层 | Pro/Flash (CC 内部) | L1-L5 (model-router 分类) |

> [!note] 口径注: 「keepalive 60s」为 TCP keepalive 内核参数；「45s」为应用层心跳间隔（MOC 口径），两层独立，勿混用。

### 2.2 核心障碍

**Permafrost 的 9 锚点工具是为 Claude Code 设计的**，Hermes 工具集完全不同：

```
CC 锚点工具:  Agent, AskUserQuestion, Bash, Edit, Read, Skill, 
              ToolSearch, Workflow, Write

Hermes 工具:  browser, clarify, code_execution, computer_use, context_engine,
              cronjob, delegation, file, image_gen, memory, messaging,
              session_search, skills, spotify, terminal, todo, tts, video,
              video_gen, vision, web, x_search, ...
```

如果 Hermes 直接接入 permafrost，`normalize_tools()` 会剥离 Hermes 的大部分工具 → 功能受损。

### 2.3 模型差异

Hermes L1/L2 使用 **doubao** 模型（火山引擎），不走 DeepSeek 缓存，天然无缓存收益。只有 L3/L4/L5 使用 deepseek 模型时才有缓存潜力。

当前统计（model-router stats）:
```
L1 (doubao-mini):  7 次   ← 无缓存可能
L2 (doubao-lite):  162 次 ← 无缓存可能
L3 (deepseek-flash): 0 次 ← 理论可缓存
L4 (deepseek-pro):   0 次 ← 理论可缓存
L5 (deepseek-pro):   0 次 ← 理论可缓存
```

**结论**: Hermes 当前几乎不使用 deepseek 模型，缓存优化的 ROI 极低。

---

## 三、优化方案

### 方案 A: 仅监控（推荐，已实施）

```
Hermes → model-router → ARK API (不变)
                │
                └── hermes-cache-monitor.sh (监控 permafrost + router)
```

- **成本**: 零（不改变架构）
- **收益**: 及时发现缓存/路由异常
- **适用**: 当前 Hermes 几乎不用 deepseek 的场景

### 方案 B: model-router 上游改为 permafrost

```
Hermes → model-router → permafrost :8788 → proxy :8787 → DeepSeek
```

- **优点**: L3/L4/L5 请求自动享受缓存
- **缺点**: 
  - permafrost 的 normalize_tools 会剥离 Hermes 非锚点工具 → **需要关闭 normalize_tools**
  - Hermes 和 CC 共享 permafrost → 不同工具集会破坏彼此的缓存锚点
  - 需要改造 permafrost 支持多租户（不同 session 使用不同锚点集）
- **风险**: 高 — 可能破坏 CC 缓存
- **建议**: 仅在 Hermes 大量使用 deepseek 模型时考虑

### 方案 C: Hermes 独立 permafrost 实例

```
Hermes → model-router → permafrost-hermes :8789 → DeepSeek
CC     → permafrost-cc :8788 → proxy :8787 → DeepSeek
```

- **优点**: 完全隔离，互不影响
- **缺点**: 
  - 双倍 permafrost 进程（~50MB 内存 × 2）
  - 需要配置 Hermes 专用锚点工具集
  - Hermes L1/L2 用 doubao 不走此路径
- **建议**: 仅在 Hermes deepseek 流量占比 >50% 时考虑

---

## 四、监控设置

### 4.1 缓存监控守护

```bash
# 手动检查
bash /home/pi/hermes-cache-monitor.sh once

# 后台守护 (每 60s 检查)
bash /home/pi/hermes-cache-monitor.sh daemon

# 查看状态
bash /home/pi/hermes-cache-monitor.sh status
```

### 4.2 监控阈值

| 指标 | 告警 | 触发 dump |
|------|:----:|:---------:|
| permafrost 命中率 | <75% | <60% |
| model-router 状态 | ≠ ok | ≠ ok |
| router 错误增量 | — | >5 |
| 前缀变化 | — | ≥2 |

### 4.3 与 CC 监控的关系

| 维度 | claude-cache-monitor.sh | hermes-cache-monitor.sh |
|------|:----------------------:|:-----------------------:|
| 监控对象 | permafrost 缓存命中率 | permafrost + model-router |
| 命中率 dump 阈值 | <70% | <60%（更宽松） |
| 独有功能 | proxy 502 检测 | router 健康检测 |
| 监控目录 | ~/.permafrost/monitor/ | ~/.hermes-cache/monitor/ |

---

## 五、DeepSeek 后台缓存检查

Hermes 的 L3/L4/L5 请求（deepseek 模型）在 DeepSeek 后台的理论缓存行为：

1. **前提**: 请求前缀 ≥ 64 tokens 且逐字节匹配
2. **实际**: Hermes 每次请求的 system prompt + tools 不同 → 前缀不匹配 → **缓存命中率 ~0%**
3. **验证方法**: 在 DeepSeek/ARK 后台按 API key 过滤，对比 CC 和 Hermes 的缓存命中率

---

## 六、决策记录

| 日期 | 决策 | 原因 |
|------|------|------|
| 2026-06-29 | Hermes 不接入 permafrost | 工具集不兼容，且当前流量几乎全走 doubao |
| 2026-06-29 | 部署 hermes-cache-monitor.sh | 低成本监控，异常时及时感知 |
| 2026-06-29 | 方案 B/C 标记为「待评估」 | 等 Hermes deepseek 流量占比增加后再考虑 |
