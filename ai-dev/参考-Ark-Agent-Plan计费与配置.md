---
title: Ark Agent Plan 计费与配置参考
aliases: [Ark API, Agent Plan, 火山引擎]
tags: [reference/ark, reference]
created: 2026-07-22
updated: 2026-08-25
status: stable
source_urls: [https://www.volcengine.com/docs/82379, https://www.volcengine.com/docs/82379/2516283]
---

# Ark Agent Plan 计费与配置 — 知识参考

See also: [[AGENTS]] | [[AI大模型开发]]

> 本文档帮助理解火山引擎 Ark Agent Plan 的计费体系、API 配置和模型选择。
> 配合《树莓派网络故障与路由器破解完整复盘》阅读。

---

## 一、什么是 Agent Plan

Agent Plan 是火山引擎方舟平台 2026 年 5 月推出的面向个人用户的 AI 订阅服务。与按量付费（pay-per-token）不同，Agent Plan 采用 **AFP（Agent Fuel Points，Agent 燃料值）** 统一计费，覆盖文本生成、图片生成、视频生成、向量化等多模态能力。

**与 Coding Plan 的区别**：
- **Coding Plan**：面向编程场景，按"调用次数"标称（实际按 token 折算），支持 Claude Code、Cursor、TRAE
- **Agent Plan**：面向通用 Agent 场景，按 AFP 积分抵扣，支持更多模型和模态类型

---

## 二、套餐档位与定价

| 档位 | 月费 | AFP/月 | 视频生成 | 适用场景 |
|------|------|--------|---------|---------|
| **Small** | ¥40 | 20,000 AFP | 不支持 | 体验测试，轻度使用 |
| **Medium** | ¥200 | 100,000 AFP | 支持 | Agent 开发，中等用量 |
| **Large** | ¥500 | 250,000 AFP | 支持 | 多模态深度应用 |
| **Max** | ¥1,000 | 500,000 AFP | 支持 | 生产级高并发 |

**订阅规则**：
- 支持连续包月/包季/包年
- 单次最长 12 个月
- 存量 + 新购合计不超过 24 个月
- 仅支持升配，不支持降配

---

## 三、AFP 消耗刷新周期

| 周期 | 刷新规则 | 说明 |
|------|---------|------|
| **5 小时** | 首次请求时间为基准，每 5 小时刷新 | 防止短时间大量消耗 |
| **每周** | 每周一 00:00 重置 | 自然周 |
| **每月** | 订阅月第 1 日 00:00 重置 | 订阅计费周期 |
| **视觉日限额** | 图片/视频模型独立限制 | 不受 5 小时及周限额限制 |

### 实际瓶颈：周限额

**周限额是最容易被忽略但实际最紧的限制。**

以 Medium 套餐为例（月 100,000 AFP）：
- 5小时理论最大：10,000 × (720/5) = 1,440,000 AFP/月 ← **远大于月配额**
- 周限额最大：35,000 × 4.3 = 150,500 AFP/月 ← **比月配额大 50%**
- 实际可用：min(月100K, 周35K×4, 5h-10K×N) = **月 100K 通常是限制因素**

但在集中使用时（比如一天用完一周的量），会触发周限额。

**各套餐 AFP 限额明细**：

| 档位 | 月 AFP | 5小时 AFP | 周 AFP | 视觉日 AFP |
|------|:------:|:--------:|:-----:|:---------:|
| Small | 20,000 | 2,000 | 7,000 | 10,000 |
| Medium | 100,000 | 10,000 | 35,000 | 50,000 |
| Large | 250,000 | 25,000 | 87,500 | 125,000 |
| Max | 500,000 | 50,000 | 175,000 | 250,000 |

**额度耗尽**：等待下一周期自动恢复，不会额外扣费。

---

## 四、AFP 抵扣机制详解

### 文本/向量模型 AFP 计算公式

```
AFP 消耗 = (输入 tokens × 输入系数 + 输出 tokens × 输出系数) / 10,000
```

### 上下文长度分层系数

系数按上下文长度分层（不是固定的）：

| 上下文长度 | 输入 vs 输出系数 | 效果 |
|-----------|:---------------:|------|
| < 32K | 输入系数 < 输出系数 | 输入密集更便宜 |
| 32K - 128K | 输入系数 = 输出系数 | 中性 |
| 128K - 256K | 输入系数 > 输出系数 | 输出密集更便宜 |

长上下文消耗（>128K）时，输出 token 反而比输入便宜——这是为了鼓励模型生成更多内容而不是反复输入大量上下文。

### 图片生成 AFP 公式

```
AFP = 成功生成的图片数量 × 图片系数
```

### 视频生成 AFP 公式

```
AFP = (消耗的 tokens / 10,000) × 视频系数
```

### 文本/代码模型系数

| 模型 | 相对消耗 | 上下文窗口 | 最大输出 | 备注 |
|------|:------:|:---------:|:-------:|------|
| **deepseek-v4-pro** | **高** | 1,024K (1M) | 384K | Agent 最强，大上下文 |
| **deepseek-v4-flash** | **低** | 1,024K (1M) | 384K | 最经济，默认深度思考 |
| **doubao-seed-2.0-pro** | 中高 | 256K | 65K | 多模态旗舰 |
| **doubao-seed-2.0-code** | 中 | 256K | 65K | 代码生成专用 |
| **doubao-seed-2.0-lite** | 低 | 256K | 65K | 轻量快速 |
| **kimi-k2.6** | 高 | 256K | 32K | 限时折扣适用 |
| **kimi-k2.7-code** | 中 | 256K | - | 最新 Kimi 编码 |
| **glm-5.2** | 中 | ~1,000K | - | 大上下文 |
| **minimax-m3** | 高 | 1,024K (1M) | - | MiniMax 新旗舰 |
| **ark-code-latest (Auto)** | **最低** | 256K | 32K | 智能路由，统一最低扣 |

### 成本估算示例

假设使用 Medium 套餐（100,000 AFP/月，¥200）：

| 场景 | 模型 | 估算用量 | AFP 消耗 | 是否够用 |
|------|------|---------|---------|---------|
| 轻度编码 | deepseek-v4-flash | 2M tokens/天 | ~6,000 AFP/天 | ✓ 充足 |
| 中度编码 | deepseek-v4-pro | 1M tokens/天 | ~12,000 AFP/天 | ✓ 可用 8 天 |
| 重度 Agent | deepseek-v4-pro | 3M tokens/天 | ~36,000 AFP/天 | ❌ 首日即超周限额（36K/天 > 周 35K），无法连续使用 |
| 智能路由 | ark-code-latest (Auto) | 2M tokens/天 | ~3,000 AFP/天 | ✓ 最经济 |

> 注：精确系数以 Ark 控制台实时显示为准。以上为基于公开数据的估算。

---

## 五、API Base URL 对照

### Agent Plan vs 其他 Plan

| 服务类型 | Base URL | 鉴权方式 | 适用场景 |
|---------|----------|---------|---------|
| **在线推理（按量）** | `https://ark.cn-beijing.volces.com/api/v3` | Bearer API Key | 后付费，按 token 计 |
| **Coding Plan (OpenAI)** | `https://ark.cn-beijing.volces.com/api/coding/v3` | Coding Plan Key | AI 编程工具 |
| **Coding Plan (Anthropic)** | `https://ark.cn-beijing.volces.com/api/coding` | Coding Plan Key | Claude Code |
| **Agent Plan** | `https://ark.cn-beijing.volces.com/api/plan/v3` | Agent Plan Key | 通用 Agent |

### Agent Plan 支持的 API 路径

| 路径 | 协议 | 用途 |
|------|------|------|
| `/api/plan/v3/chat/completions` | OpenAI | 对话补全 |
| `/api/plan/v1/chat/completions` | OpenAI | 对话补全（旧版） |
| `/api/plan/v1/messages` | Anthropic | Claude Code 兼容 |

### ⚠️ 混用 URL 的后果

**使用 Agent Plan Key 访问 `/api/v3`（在线推理）会导致额外按量计费，不会消耗套餐 AFP 额度。**

这是用户最容易踩的坑——配置错了 Base URL，产生预期外费用。

---

## 六、Claude Code 配置

### 通过 settings.local.json（推荐）

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8788",
    "ANTHROPIC_AUTH_TOKEN": "[已脱敏]",
    "ANTHROPIC_MODEL": "deepseek-v4-pro",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-flash",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash"
  }
}
```

**关键说明**：
- `ANTHROPIC_BASE_URL` 指向本地代理（代理负责转发到 Ark API）
- `ANTHROPIC_AUTH_TOKEN` 是 Agent Plan API Key
- 代理的 `PROXY_TARGET` 应设为 `https://ark.cn-beijing.volces.com/api/plan`

### 代理转发路径

```
Claude Code
  → POST http://127.0.0.1:8788/v1/messages
  → 代理转发到 https://ark.cn-beijing.volces.com/api/plan/v1/messages
  → Ark 返回 Anthropic 格式响应
```

### Hermes Agent 配置

```bash
hermes config set model.provider custom
hermes config set model.base_url https://ark.cn-beijing.volces.com/api/plan/v3
hermes config set model.api_key ark-098fa118-xxxxx
hermes config set model.default ark-code-latest
hermes config set model.api_mode codex_responses
```

---

## 七、获取 API Key

### 通过 arkcli

```bash
# 登录火山引擎
arkcli auth login

# 获取并配置 API Key
arkcli auth apikey
# 自动拉取并保存到 ~/.arkcli/.env
```

### 通过控制台

1. 登录 https://console.volcengine.com/ark/
2. 进入「Agent Plan」→「API Key 管理」
3. 创建新的 API Key
4. 复制保存（关闭后无法再次查看明文）

---

## 八、Coding Plan 的双层计费陷阱

> 这是 Coding Plan 的问题，Agent Plan 用户不受影响。但了解这个机制有助于理解火山引擎的计费设计。

Coding Plan **标称按"次数"计费**，但实际扣费公式为：
```
扣次 = max(round(use_token / token_limit), 1)
```

各模型的隐藏倍率（相对于基准）：
- DeepSeek-V3.2：约 2x
- Doubao-Seed-2.0-Code：约 4x
- Doubao-Seed-2.0-Pro：约 6x

这意味着一次高 token 消耗的调用可能被折算为多次，快速耗尽配额。
Agent Plan 避免了这个问题——直接用 AFP 积分按 token 计费，更透明。

---

## 九、模型选择建议

### ark-code-latest (Auto 模式)

**推荐作为默认模型**。它会智能路由到最优模型组合，统一按最低 AFP 系数抵扣。

适用场景：
- 不确定用哪个模型时
- 希望自动优化成本时
- 不需要特定模型的特殊能力时

### deepseek-v4-pro

适合复杂 Agent 任务、长链推理、工具调用。AFP 消耗较高。

### deepseek-v4-flash

适合简单任务、子代理、快速响应。AFP 消耗最低，适合重度使用。

---

> **参考资源**
> - 火山引擎方舟文档: https://www.volcengine.com/docs/82379
> - Agent Plan 产品介绍: https://www.volcengine.com/docs/82379/2516283

## Related

- [[AGENTS]] — AI 协作规范
- [[AI大模型开发]] — AI 开发笔记
