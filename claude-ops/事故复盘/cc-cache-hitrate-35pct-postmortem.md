---
title: CC 缓存命中率 35.5% 问题排查复盘
aliases: []
tags: [ai/ops, incident]
created: 2026-06-29
updated: 2026-08-17
status: stable
---

# CC 缓存命中率 35.5% 问题排查复盘

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-postmortem-2026-06-13]] · [[claude-cache-incident-postmortem]]

> 日期: 2026-06-29 | CC 版本: v2.1.177 | 影响: 缓存命中率从 ~97% 骤降至 35.5%

---

## 一、问题概述

| 指标 | 发现时 | 修复后（预期） |
|------|:------:|:------:|
| 命中率 | 35.5% | >85% |
| 命中 tokens | 75,776 | — |
| 未命中 tokens | 137,612 | — |
| 费用节省 | 33.9% | >80% |
| 请求数 | 10 (4天内) | — |
| Permafrost 版本 | 原版 (628行) | 补丁版 (663行) |

## 二、根因分析

### 直接原因

**部署的 permafrost 缺少 `normalize_tools()` 补丁。**

CC v2.1.177 引入了 WebSearch、WebFetch 等新工具（从 v2.1.174 的 10 个增加到 12+ 个），不同 session 获得不同工具集：

- **Pro 主会话**: 完整工具集（12+ tools）
- **Flash 子 agent**: 精简工具集（可能只有 Bash、Read、Write 等）

不同工具集 → 不同缓存锚点（`sha256(tools + system + params)`）→ 无法跨 session 共享前缀缓存。

### 深层原因

permafrost 的 `normalize_tools()` 函数作用是将所有 session 的工具集归一化为 9 个锚点工具，非锚点工具按关键词按需加载。但当前部署的 permafrost 是 npm 原版，不包含此补丁。

### 对比验证

| 功能 | 部署版 (628行) | 仓库补丁版 (663行) |
|------|:--:|:--:|
| `stabilize_current_date()` | ✅ | ✅ |
| `sort_tools()` | ✅ | ✅ |
| `normalize_tools()` | ❌ | ✅ |
| `_ANCHOR_TOOLS` (9锚点) | ❌ | ✅ |
| `_wanted_tools()` (按需保留) | ❌ | ✅ |
| `import os` | ❌ | ✅ |

## 三、修复过程

### 3.1 安全部署流程（吸取 06-16/06-17 事故教训）

```bash
# 1. 备份当前版本
cp permafrost_align.py → permafrost_align.py.bak-20260629-000324

# 2. 从 repo 权威补丁部署
cp patches/permafrost_align.py → 部署路径 (663行)

# 3. 清除 .pyc 缓存（关键！否则旧字节码继续运行）
rm -rf __pycache__/

# 4. 语法验证
python3 -m py_compile permafrost_align.py ✅

# 5. 函数验证
grep 'def normalize_tools' → 1 ✅
grep '_ANCHOR_TOOLS' → 3 ✅
grep 'stabilize_current_date' → 2 ✅

# 6. 重启 permafrost
kill permafrost_proxy.py → sleep 2 → 重启

# 7. Doctor 验证
curl /permafrost/doctor → tools_sorted: True ✅
```

### 3.2 同时建立的监控

| 脚本 | 位置 | 用途 |
|------|------|------|
| `claude-cache-monitor.sh` | 已存在 | CC permafrost 缓存监控 |
| `hermes-cache-monitor.sh` | 新建 | Hermes model-router + permafrost 联合监控 |

## 四、Hermes 缓存现状（同步分析）

Hermes 请求链路：`Hermes Agent → model-router (:18888) → ARK API (直连)`

**Hermes 不经过 permafrost**，原因：
1. Hermes 工具集与 CC 完全不同（~38 tools vs 12 tools）
2. permafrost 的 9 锚点工具是为 CC 设计的
3. Hermes L1/L2 使用 doubao 模型，不走 DeepSeek 缓存
4. 直接接入会破坏 CC 的缓存锚点

**决策**: 仅监控不接入。创建 `hermes-cache-monitor.sh` 监控 model-router + permafrost 双重状态。

## 五、教训

1. **版本升级前检查工具集变化** — v2.1.174→v2.1.177 新增 WebSearch/WebFetch，触发了锚点分裂
2. **补丁部署必须验证** — 部署不等于生效，需要 doctor 端点确认
3. **Python .pyc 缓存陷阱** — 源码更新后不清缓存 = 旧代码继续运行（06-16 同样踩过）
4. **单点真相来源** — repo `patches/` 目录是唯一权威版本
5. **监控先于排查** — 如果 permafrost 有自动命中率告警，问题会更早暴露

## 六、相关文件

| 文件 | 说明 |
|------|------|
| `patches/permafrost_align.py` | 权威补丁（663行，含 normalize_tools） |
| `hermes-cache-analysis.md` | Hermes 缓存分析 + 方案 A/B/C |
| `hermes-cache-monitor.sh` | Hermes 缓存监控脚本 |
| `pi-vs-termux-guide.md` | Pi vs Termux 部署差异指南 |
