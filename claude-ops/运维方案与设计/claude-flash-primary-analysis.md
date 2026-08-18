---
title: Flash 为主、Pro 为辅 — 深度可行性分析
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-17
updated: 2026-08-17
status: review
---

# Flash 为主、Pro 为辅 — 深度可行性分析

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-strategy]] · [[claude-streaming-forward-design]]

> 日期: 2026-06-17 | 状态: 讨论阶段，暂不落地

---

## 一、目标

最大化 flash 模型使用比例，在保证输出质量的前提下降低 token 成本。

| 模型 | 输入价格(缓存命中) | 输出价格 | 质量 |
|------|-------------------|----------|------|
| deepseek-v4-flash | $0.0028/M | $0.28/M | 中等 |
| deepseek-v4-pro | $0.145/M | $3.48/M | 高 |
| **价差** | **~50x** | **~12x** | |

---

## 二、当前流量分布

```
CC 主 session 请求构成:
  ├─ 工具调用 (Bash/Edit/Read/Agent...)  ~60%
  ├─ 含代码的分析/修改请求               ~25%
  ├─ 长消息上下文 (>300 chars)           ~10%
  └─ 纯 Q&A 简单轮次                     ~5%
```

**flash 最大可行占比: 5-10%**（简单 Q&A 轮次）

---

## 三、方案对比

### 方案A: 全量 flash 默认

```
ANTHROPIC_MODEL=deepseek-v4-flash → 所有请求先走 flash
检测到复杂度信号 → 下轮切换 pro
```

| 优点 | 缺点 |
|------|------|
| flash 占比可达 100%（简单 session） | 代码/工具请求质量可能严重下降 |
| 实现简单 (改一个 env) | 模型切换频繁 → 缓存锚点反复变化 |
| | 用户可能感知到回复质量波动 |

**可行性: ❌ 不可行** — CC 主 session 90% 请求需要 pro 质量

### 方案B: 按轮路由（当前 v2 model_router）

```
每轮独立判断: 简单 → flash, 复杂 → pro
信号: 当前轮消息长度 / 是否含代码 / 近期工具使用
```

| 优点 | 缺点 |
|------|------|
| 质量可控 | flash 占比低 (5-10%) |
| 已在生产验证 | 模型切换有缓存成本 |
| 有质量反馈升级机制 | |

**可行性: ✅ 已实现** — 收益有限但安全

### 方案C: 会话级路由

```
新 session → flash 开始
运行 N 轮后评估: 
  - 纯 Q&A 无工具 → 保持 flash
  - 出现工具调用 → 切换 pro（永久）
```

| 优点 | 缺点 |
|------|------|
| 简单 session 100% flash | 无法处理混合 session |
| 只切换一次 → 缓存成本小 | 按 session 粒度太粗 |
| | CC 默认 session 几乎不会纯 Q&A |

**可行性: ⚠️ 部分可行** — 适合短 session，不适合 CC

### 方案D: 双模型协同

```
每轮同时发 flash + pro:
  - flash 先返回 → 如果质量 OK → 用 flash 结果
  - flash 质量差 → 等 pro 返回 → 用 pro 结果
```

| 优点 | 缺点 |
|------|------|
| 质量有保障 | 成本翻倍（每次发两次请求） |
| 简单轮次 flash 够用 | 实现复杂 |
| | 抵消了 flash 的成本优势 |

**可行性: ❌ 不可行** — 成本反而增加

---

## 四、可优化措施（优先级排序）

### 1. 扩大 flash 窗口（低风险）

当前 model_router 保守策略。可以放宽：

```python
# 当前阈值
if len(last_user) > 300: return pro
if "```" in last_user: return pro

# 放宽后
if len(last_user) > 800: return pro       # 允许中等长度
if "```" in last_user and len(code) > 200: return pro  # 小代码片段仍用 flash
if "fix" in last_user or "debug" in last_user: return pro  # 显式编码意图
```

**预期**: flash 占比从 5% → 10-15%
**风险**: 低，通过质量反馈兜底

### 2. 缓存锚点对齐（中风险）

统一 flash 和 pro 的工具集+system block，使模型切换不破坏缓存：

```
permafrost 统一 tools → 9锚点工具
permafrost 统一 system → 相同格式
→ flash 和 pro 共享缓存锚点 → 切换零成本
```

**预期**: 消除模型切换的缓存惩罚
**风险**: 中，需要验证 flash 对统一 system 的兼容性

### 3. Flash 预热（低风险）

在 session 开始时用 flash 发一条空请求预热缓存：

```
首次请求 → flash 空转 → 后续简单轮次直接命中 flash 缓存
```

**预期**: flash 命中率 +20%
**风险**: 低，成本极小

### 4. 质量反馈增强（低风险）

扩展 feedback_flash_response:

```python
# 当前
if len(response) < 50: upgrade()

# 增强
if "I cannot" in response: upgrade()          # flash 拒绝
if "I don't know" in response: upgrade()      # flash 不确定
if len(response) < 200 and "?" in prompt: upgrade()  # 问答不完整
```

**预期**: 质量兜底更可靠
**风险**: 低，纯逻辑判断

---

## 五、推荐路径

```
阶段1 (当前): v2 model_router — flash 5-10%
  → 观察 1-2 周，收集 flash 实际使用数据

阶段2 (优化): 放宽阈值 + 质量反馈增强 — flash 10-15%
  → 如果阶段1 无质量投诉

阶段3 (突破): 缓存锚点对齐 + flash 预热 — flash 15-25%
  → 需要 permafrost 层改动

不推荐: Flash 作为主模型 (>50%)
  → CC 使用场景不适合，强行推行损害质量
```

---

## 六、决策点

| 决策 | 时机 | 条件 |
|------|------|------|
| 启用阶段2 | 1-2 周后 | flash 回复质量无投诉 |
| 启动阶段3 | 阶段2 稳定后 | pro 命中率 >95% |
| 放弃 flash 路线 | 任何时候 | 用户反馈质量下降 |

---

## 附: 响应延迟分析 (2026-06-17)

proxy 上游延迟是主因，非 permafrost 补丁:

| 指标 | 值 |
|------|-----|
| proxy 最小延迟 | 2.8s |
| proxy 平均延迟 | 25s |
| proxy 中位延迟 | 16s |
| proxy 最大延迟 | 76s |

原因: proxy 缓冲模式 — 收到完整响应后才发给 CC。
优化: pipe 流式转发(边收边发)，可将感知延迟减半。

permafrost 补丁处理 <1ms，本地链路 <5ms，均非瓶颈。
