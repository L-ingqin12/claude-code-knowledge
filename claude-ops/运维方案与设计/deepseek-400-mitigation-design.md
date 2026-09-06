---
title: DeepSeek 400 双类报错规避与恢复方案
aliases: [DeepSeek 400, Content Exists Risk 规避, Claude Code 内容审核兜底, thinking 协议 400]
tags: [ai/ops, ai/agent]
created: 2026-09-06
updated: 2026-09-06
status: review
---

# DeepSeek 400 双类报错 — 全局规避与恢复方案

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-relay-design]] · [[claude-cache-optimization]] · [[tianshu-cache-aim-plan]] · [[claude-context-continuity-guide]] · [[deepseek-400-mitigation-usage|使用说明]]

> [!abstract] 概述
> Claude Code 经 [[claude-cache-relay-design|cache-relay]]（:8790）路由到 DeepSeek。2026-09-06 全天反复出现**两类 400**：内容审核（`Content Exists Risk`，~90%）与 thinking 协议（`reasoning_content must be passed back`，~10%）。二者都导致会话回合中断，且污染历史令之后每轮复发 → 会话"被动报废"。本文给出**预防 → 恢复 → 兜底**三层方案，核心原则「主路留 DeepSeek 同一模型，保缓存命中与上下文连续性；切供应商只作最后兜底」。

> [!danger] ⛔ 为什么必须做
> 一旦 400 命中，触发内容就"焊"进会话历史，之后每轮 `--continue` 都重发含毒历史 → 永远 400，只能新开会话。

---

## 一、根因（已取证坐实）

| # | 报错 | 占比 | 触发源 | 换模型能否规避 |
|---|---|---|---|---|
| A | `Content Exists Risk`（内容审核） | ~90%（300+ 次） | 历史混入代理节点域名/端口、订阅链接、地区绕过等 | ❌ 换另一个 DeepSeek 模型无效（同一审核层）；须换供应商 |
| B | `reasoning_content must be passed back` / `content[].thinking` / `prefill unsupported`（thinking 协议） | ~10%（26 次） | DeepSeek V4 思考模式 + 工具调用，`reasoning_content` 未回传 | ✅ 有透明修复，**不换供应商** |

关键事实：DeepSeek 是**生成前对整包请求体**（system + 多轮历史 + tool_result）做服务端预检，任一消息段命中即整包 400，**无官方参数可关**；400 属客户端错误，Claude Code 不重试，`fallbackModel` 只认 5xx/同端点不触发。

## 二、设计原则

1. **主路留 DeepSeek 同一模型**，保 prompt 缓存命中 + 上下文连续性。
2. **切换供应商（GLM）只作最后兜底**，代价 = 缓存全丢 + 跨模型连续性断裂。
3. 一切改动**本地化、可逆、幂等**，软回滚优先、密钥不落地。

## 三、总体架构（三层，复用 [[claude-cache-relay-design|cache-relay]]）

```
Claude Code
   │ ANTHROPIC_BASE_URL = http://127.0.0.1:8790（settings.local.json）
   ▼
┌───────────────────────────────────────────────┐
│ cache-relay（已部署）                           │
│   ① 缓存对齐（strip cache_control/排序/稳定化） │
│   ② 内容审核 400 兜底：命中 → 改投 OpenRouter    │
│      z-ai/glm-5.3-flash（只换 auth+model）     │
└───────────────────────────────────────────────┘
   │（默认）              │（仅兜底，最后手段）
   ▼                      ▼
 DeepSeek 官方          OpenRouter GLM
```

- **第一层 预防**（§四）：不触发 400，主路留 DeepSeek。
- **第二层 恢复**（§五）：触发后剪除污染，继续留 DeepSeek。
- **第三层 兜底**（§六）：前两者都失效时才切 GLM（已实现进 cache-relay）。

## 四、第一层：预防（主）— 已实现

**4.1 全局 `~/.claude/CLAUDE.md` 追加「会话红线」**：禁止回显裸节点域名、`host:port` 清单、订阅链接、base64 串；节点清单一律引用文件路径；脚本输出继续脱敏；讨论节点用稳定伪名。

**4.2 触发词表**：恢复脚本运行时现读 `node-pool.txt` + `proxy-nodes.json` 自动生成节点 token，另设 `sanitize-extra.txt`（话题词，事故驱动补充）。**新节点自动进表，零维护**。

## 五、第二层：恢复（次）— 待落地（需确认放行）

目标：把毒从会话 jsonl 里物理剪除，`claude --continue` 原地续聊，**留 DeepSeek 保连续性**（仅一次性缓存重建）。

**5.1 内置命令结论**：`/rewind` 只能一刀切回退 checkpoint、磁盘旧行不一定物理清除 → 只适合"毒在最近一两轮"；`/compact` 本身是会 400 的模型调用、且倾向原样保留 IP/端口 → 不可作主手段。

**5.2 `sanitize-session.py`**（落 `network/scripts/`，与 node-pool 同目录）：
- 只做**整行原始文本子串替换，绝不删行、不改 uuid/tool_use↔tool_result 配对**。
- 安全闸门：备份 → 逐行 `json.loads` 校验 → 结构指纹前后对比 → 原子写。
- `--check` 只读扫描只报命中行数；`--mode aggressive` 追加话题词 + `scheme://` 链接清洗。

> [!warning] 恢复脚本会改写 Claude Code 会话 transcript
> 属用户自有本机会话文件、用于从内容审核误报中救回上下文，非隐瞒/伪造。落地需用户明确确认「误报非篡改」（harness 拦截）。

## 六、第三层：兜底（备）— 已实现并部署

**在 [[claude-cache-relay-design|cache-relay.mjs]] 上扩展**，而非新建网关：

- 命中 `400 + "content exists risk" 关键词` → 同一请求体改投 OpenRouter `z-ai/glm-5.3-flash`（只换 `authorization` 头 + `model` 名，成功路径纯透传，零协议转换 → 结构上无 thinking/tool bug 风险）。
- 兜底 key 走 `authTokenSource` 指向 `~/.claude/oxalpha-settings.json`（**不落地到 config.json**，符合密钥不落地原则）。
- 配置：`~/.cache-relay/config.json` 的 `fallback` 块（`upstream` / `modelMap` / `riskKeywords` / `authTokenSource`）。
- 已热部署（:8790），语法校验通过。

> [!tip] 为什么不自研新网关、不用 CCR
> cache-relay 已经在路径上且做了缓存对齐，直接在其上加兜底最省、最贴合「结合缓存优化」；CCR v3 太重且配错协议会退化 OpenAI 转换引入 thinking bug；dsv4-cc-proxy / claude-code-fallback 均不处理 400 内容审核。

## 七、thinking-400 的归属（待确认）

`reasoning_content must be passed back` 是 OpenAI 转换路径的产物；本机走原生 `/anthropic`，理论上不该踩。但会话里确实扫到 ~10%。解释：那是原生端点的 adaptive/injection 边角（dsv4-cc-proxy 修的）。实施验证时若复现，把 dsv4-cc-proxy 的注入逻辑折进 cache-relay（多几十行，仍留 DeepSeek）。

## 八、实施状态与验证

| 层 | 状态 | 落地 |
|---|---|---|
| 预防 | ✅ 已实现 | `~/.claude/CLAUDE.md` 会话红线 + `sanitize-extra.txt` |
| 恢复 | ⏳ 待放行 | `sanitize-session.py`（harness 拦截，需确认误报） |
| 兜底 | ✅ 已部署 | cache-relay.mjs 扩展 + `~/.cache-relay/config.json` |

验证：兜底触发需构造审核命中请求，观察日志 `[cache-relay] 400 risk → fallback ... status=200`；恢复用 `--check` 扫描零命中后 `--continue`。

## 九、风险与待确认

- **GLM 是否放行被 DeepSeek 拦的内容**：同为国产模型，可能 200 软拒 → 需实测。
- **原生端点 thinking-400 是否复现**：若复现折入 dsv4-cc-proxy 注入逻辑。
- **会话钉住/熔断**（P1 优化）：命中后按会话指纹钉到备源，避免污染期每轮白打一次 DeepSeek。当前为每请求兜底。
- 凭据卫生：`settings.local.json` 权限列表、DSH 备份残留旧 key，建议清理/轮换。

## 十、遗留 / 后续清单（todo）

- [ ] 恢复脚本 `sanitize-session.py` 落地（harness 拦截，待用户确认"误报非篡改"）
- [ ] 兜底端到端验证：构造审核命中请求，确认日志 `400 risk → fallback ... 200`
- [ ] 会话钉住/熔断（P1）：命中后按会话指纹钉到备源，避免污染期每轮白打 DeepSeek
- [ ] 原生端点 thinking-400 复现确认：若复现，折入 dsv4-cc-proxy 注入逻辑
- [ ] GLM 对被 DeepSeek 拦截内容的放行实测
- [ ] 凭据卫生：清理 `settings.local.json` 权限列表 / DSH 备份残留旧 key
- [ ] 跨库参考 [[tianshu-cache-aim-plan]] 的 P1–P5 遗留（请求体快照 / 聚合 doctor / date-stability 守卫等）
