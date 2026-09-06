---
title: 通用多源缓存对齐中继设计（cache-relay）
aliases: [通用缓存中继, cache alignment relay]
tags: [ai/ops, ai/agent]
created: 2026-09-06
updated: 2026-09-06
status: review
---

# 通用多源缓存对齐中继设计（cache-relay）

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-optimization]] · [[tianshu-cache-aim-plan]] · [[PERMAFROST_MODIFICATIONS]]

> 背景：permafrost 的 `align_request()` 是为「Claude Code → DeepSeek Anthropic 端点」单一来源定制的（去 cache_control、工具排序、currentDate 稳定化、env 冻结）。本方案把它**泛化为多源缓存对齐中继**：自动识别来源 provider 类型，选对应的缓存策略，一个中继服务所有上游。要求：尽量通用、自动判源、软回滚优先、使用说明保留。

---

## 一、核心思想：按来源分派缓存策略

不同 provider 的缓存机制**本质不同**，不能一刀切：

| Provider | 缓存类型 | 命中关键 | 需要的对齐动作 |
|---|---|---|---|
| **DeepSeek** | 隐式 exact-prefix（byte 0 起逐字节） | 前缀字节稳定 | 去 cache_control、工具按 name 排序、currentDate 稳定化、env 冻结+增量 |
| **Anthropic/Claude** | 显式 `cache_control` 断点 | 断点位置稳定、稳定内容在前 | **保留**断点、把稳定块放前、易变块放断点后（不 strip） |
| **GLM/Zhipu** | 隐式前缀（deepseek-native） | 前缀字节稳定 | 同 DeepSeek：排序 + 稳定化 + 冻结 |
| **OpenRouter** | 透传（缓存由最终上游模型决定） | 取决于下游 | 仅工具排序 + 确定性 JSON（最小干预） |
| **通用 OpenAI 兼容** | 未知/无 | 保守 | 工具排序 + 确定性序列化（安全默认） |

**判源依据**：`baseUrl` host + `model` 名 + `protocol`（OpenAI `chat/completions` vs Anthropic `messages`）。

## 二、判源与分派（detect → dispatch）

```
agent 请求 ──▶ cache-relay ──▶ detectProvider(baseUrl, model, protocol)
                  │
                  ├─ deepseek   → alignDeepSeek()   (strip cache_control + sort + stabilize + freeze)
                  ├─ anthropic  → alignAnthropic()  (keep breakpoints, 稳定前置校验)
                  ├─ glm        → alignDeepSeek()   (同 DeepSeek)
                  ├─ openrouter → alignPassthrough()(sort + canonical JSON)
                  └─ default    → alignGeneric()    (sort + canonical JSON)
```

判源规则（可 env 覆盖）：

```
host 含 deepseek.com            → deepseek
host 含 anthropic.com 或 protocol=anthropic → anthropic
host 含 bigmodel.cn / zhipu     → glm
host 含 openrouter.ai           → openrouter
host 含 minimaxi.com            → deepseek（隐式前缀，同策略）
其余                             → generic
```

## 三、对齐动作（复用 permafrost 算法，按源裁剪）

| 动作 | deepseek/glm | anthropic | openrouter/generic |
|---|---|---|---|
| strip cache_control | ✅（DeepSeek 不识别，位置漂移破坏前缀） | ❌（显式断点，保留） | — |
| 工具按 name 排序 | ✅ | ✅（确定性） | ✅ |
| currentDate 稳定化 | ✅（→ 2000-01-01） | ✅（system 别插日期） | ✅ |
| env/易变块冻结+增量 | ✅（freeze_volatile） | ✅（易变块放断点后） | 可选 |
| 规范 JSON 序列化 | ✅ | ✅ | ✅ |

## 四、架构与部署

- **形态**：Node.js HTTP 中继（跨平台、无编译依赖），`cache-relay.mjs`。
- **链路**：agent → cache-relay(:8790) → 上游（baseUrl 由 agent 通过 `RELAY_UPSTREAM` 或请求头指定）。
- **多源并发**：单进程监听，按请求独立判源分派，互不污染。
- **密钥**：中继**不落地任何密钥**，透传 `Authorization`/`api-key` 头；上游地址用 env `RELAY_DEFAULT_UPSTREAM`，不硬编码。

## 五、逃生与回滚通道（软回滚优先，禁止硬删除）

| 级别      | 类型  | 操作                                                    | 场景                        |
| ------- | --- | ----------------------------------------------------- | ------------------------- |
| E0 停中继  | 逃生  | `node cache-relay.mjs stop`（读 pid kill）               | 中继异常，立即止血                 |
| S0 软回滚  | 软回滚 | `touch ~/.cache-relay/.disabled` 或 `RELAY_DISABLED=1` | 不需要缓存对齐时禁用（**不删脚本**，随时恢复） |
| P0 单源降级 | 逃生  | `RELAY_FORCE_PROVIDER=passthrough`（全部直通，不做对齐）         | 某 provider 对齐逻辑出问题，一键全直通  |
| R0 硬回滚  | 硬回滚 | `git revert <commit>`（**不 `rm`**）                     | 正式撤销部署                    |

> **软回滚原则**：停用/降级一律走 `.disabled`/env 开关，**绝不删脚本**；`RELAY_FORCE_PROVIDER=passthrough` 是「全直通」逃生阀，保证对齐层挂了也能透传。

## 六、使用说明

```bash
node cache-relay.mjs start        # 前台启动（:8790，日志 stdout）
node cache-relay.mjs daemon       # 后台（写 pid）
node cache-relay.mjs stop         # 停（读 pid）
node cache-relay.mjs doctor       # 判源自测：给定 baseUrl/model 打印判定结果
```

环境变量：`RELAY_PORT`（默认 8790）· `RELAY_DEFAULT_UPSTREAM`（默认透传请求自带的目标）· `RELAY_FORCE_PROVIDER`（可选：强制某策略，`passthrough`=全直通逃生）· `RELAY_DISABLED=1`（软回滚开关）。

## 七、测试计划（跑通再部署）

| 项 | 命令 | 通过标准 |
|---|---|---|
| 判源自测 | `node cache-relay.mjs doctor`（deepseek/anthropic/glm/openrouter/generic 各一例） | 判定正确 |
| 对齐单测 | 对每种 provider 发一个带 cache_control/乱序工具/currentDate 的样例请求 | deepseek 剥离+排序+稳定；anthropic 保留断点；generic 排序 |
| 透传逃生 | `RELAY_FORCE_PROVIDER=passthrough` 发请求 | 字节不变直通 |
| 软回滚 | `touch .disabled` 后 start | 静默退出 |

## 八、应用的本库经验教训

1. **先仓库后部署**（本 doc 先落盘）。
2. **改配置不动代码**（判源/开关全走 env，不写死）。
3. **如果没坏就别修**（对齐动作尽量保守，generic 只排序+规范序列化）。
4. **软回滚优先，禁止硬删除**（`.disabled`/`RELAY_FORCE_PROVIDER=passthrough` 双逃生阀）。
5. **只 dump/透传，不重启上游**。
6. **密钥不落地**（透传，不存储）。
