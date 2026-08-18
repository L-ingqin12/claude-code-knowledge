---
title: Proxy 内建缓存优化 — 评估结论：已废弃
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-12
updated: 2026-08-17
status: review
---

# Proxy 内建缓存优化 — 评估结论：已废弃

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-optimization]] · [[claude-cache-strategy]]

> 评估日期: 2026-06-12 | 原任务: #2 "在 resilience proxy 中内建 DeepSeek 前缀缓存优化"

---

## 原始计划

在 `/root/claude-resilience-proxy.py`（当时的 Python 代理）中新增 CacheOptimizer 模块，做三件事：

| 规则 | 操作 |
|------|------|
| R1 | 递归删除 `cache_control` 键 |
| R2 | `tools[]` 按 `name` 排序 |
| R3 | 规范 JSON 序列化 |

## 为什么废弃

Permafrost v0.3.0 已完整覆盖上述全部功能，且做得更多：

| 功能 | Proxy 内建方案 | Permafrost | 结论 |
|------|---------------|------------|------|
| 去 cache_control | 递归删除 | `strip_cache_control()` | 重复 |
| 工具排序 | 按 name | `sort_tools()` — 按 (name, canonical-json) | 重复且更完善 |
| 规范序列化 | sort_keys | `canonical_dumps()` — compact + UTF-8 | 重复 |
| env 块冻结 | ❌ 不支持 | `freeze_volatile()` — 仅传增量 | permafrost 独占 |
| 冷锚点合并 | ❌ 不支持 | `Coalescer` — 并行子 agent 共享预热 | permafrost 独占 |
| 空闲保活 | ❌ 不支持 | `Keepalive` — 防缓存淘汰 | permafrost 独占 |
| 命中率监控 | ❌ 不支持 | `/permafrost/stats` + `/permafrost/doctor` | permafrost 独占 |
| 前缀变化诊断 | ❌ 不支持 | anchor fingerprint + divergence diff | permafrost 独占 |

## 架构决策

```
原方案 (耦合):     CC → Proxy (韧性 + 缓存优化) → DeepSeek
                      ↑ 单点, 任一模块出问题影响全局

当前方案 (分层):    CC → Permafrost (缓存对齐) → Proxy (韧性) → DeepSeek
                      ↑ 关注点分离, 独立逃生
```

在每个代理上叠加缓存逻辑会：
1. **增加复杂度** — 韧性代理的核心价值是简单可靠，加缓存逻辑引入新故障点
2. **破坏逃生通道** — 缓存代码出问题时无法单独绕过
3. **重复劳动** — permafrost 已经过真实流量验证（85-97% 命中率）

## 结论

**此任务关闭，不再推进。** 缓存优化职责完全由 permafrost 承担，proxy 保持最简（透明转发 + 重试 + keepalive），各层独立可替换。
