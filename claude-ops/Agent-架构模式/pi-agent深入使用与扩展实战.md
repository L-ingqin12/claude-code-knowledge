---
title: Pi-Agent深入使用与扩展实战
aliases: [pi实战, pi二开指南]
tags: [ai/agent, ai/ops]
created: 2026-08-26
updated: 2026-08-26
status: review
source: 基于库内实机核验结论（@earendil-works/pi-coding-agent@0.84.3 全源码）整理；版本敏感处标待确认，事实口径以 [[参考-Pi-Agent-技术调研报告]] §11 为准
fetched_at: 2026-08-26
---

# Pi Agent 深入使用与扩展实战

> [!abstract] 定位
> 调研报告回答"Pi 是什么"，本文回答"怎么嵌入/怎么扩展/怎么排障"：库优先三层 API、TypeBox 自定义 tool 全码、steer/followUp 双队列语义与代码、extension 事件面、RPC 模式协议、JSONL 会话格式解析（可喂给 LogNet！）。选型论证见 [[opencode-pi-base-development-analysis]]。

See also: [[Claude-Ops-KB-Home]] · [[参考-Pi-Agent-技术调研报告]] · [[opencode-深入使用与扩展实战]] · [[main-subagent-realtime-interaction]]

## 一、库优先：三层 API 心智图

```
L1 createAgentSession(cfg)          ← 产品级: 自带循环/UI 粘合
L2 AgentSession(低阶)               ← 库级: 完全掌控回合与队列 (推荐二开层)
L3 流原语(streamFn+tools)           ← 极客层: 自己当 harness
```

- 二开建议钉在 **L2**：拿得到事件流与双队列，又不背 UI 包袱
- 无内置权限内核（默认放行）→ **宿主进程必须自建闸门**（secure_read 类工具 + 进程沙箱），对照 [[agent-harness-anatomy]] §2.4

## 二、自定义 Tool 全码（TypeBox 契约）

```typescript
import { Type, defineTool } from "@earendil-works/pi-coding-agent" // 具名导出面以 0.84.x 为准

const LogQuery = defineTool(
  {
    name: "lognet_query",
    description: "FTS5 全文检索日志库, 返回带 rowid 引用的结构化命中",
    parameters: Type.Object({
      q: Type.String({ description: "FTS5 MATCH 表达式" }),
      limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 50 }))
    }),
    returns: Type.Object({ hits: Type.Array(Type.Object({
      rowid: Type.Integer(), ts: Type.Number(), line: Type.String() })) })
  },
  async (args) => queryLogs(dbPath, args.q, args.limit ?? 20)   // 复用 LogNet PoC!
)
```

- 契约即提示词：description/字段 description 都会进模型上下文——**写工具=写微型系统提示词**
- 返回结构体优于拼字符串（模型可按字段推理）；错误抛 Error 带 `code` 前缀便于模型自纠

## 三、steer / followUp 双队列（实时交互核心语义）

```typescript
session.prompt("开始解析这个包")            // 入队新回合
session.steer("只看 hilog, 跳过 kmsg")      // 注入当前进行中的回合 → 模型下一思考点看到
session.followUp("完成后输出摘要")          // 排队为紧随的后续回合
session.abort()                             // AbortSignal 打断当前流
```

| 队列 | 语义 | 对应交互原语 |
|------|------|-------------|
| steer | 当轮内改道（模型已启动，下次"呼吸"时读到） | T1.5 当轮注入（[[main-subagent-realtime-interaction]]） |
| followUp | 回合后追加 | 邮箱通知类 |
| abort | 流级打断+AbortSignal 传播 | T2 打断抢占 |

- 实战规则：**纠偏用 steer，追加任务用 followUp，紧急停止用 abort**——三者混用是交互混乱之源
- 看门狗集成：超时未产出 → 先 steer 提示收敛 → 再 followUp 要求落盘中间态 → 最后 abort（T0→T2 升阶梯的库内实现路径）

## 四、Extension 事件面（25+ 事件选讲）

| 事件 | 用途示例 |
|------|---------|
| session start/end | 会话审计落 JSONL（喂 LogNet 的数据源！） |
| message start/update/end | token 计量、流式转发到自有 UI |
| tool_call before/after | 权限闸门(自定义 allow/deny)/结果脱敏——**补齐无内核权限的关键位** |
| agent steering | 收到 steer 时打标，评估改道有效性 |

写法：`pi.extend(({ on }) => { on("tool_call", async (ev) => {...}) })` 形态（签名以 0.84.x d.ts 为准，**待确认**逐字口径）。

## 五、RPC 模式与嵌入式集成

- `--mode rpc`：stdin/stdout JSON-RPC 行协议——把 Pi 当子进程引擎嵌进任何宿主（Python/Electron/Go）
- 消息族：请求(prompt/interrupt)+响应(result)+异步事件(event) 三类帧；宿主负责重连与背压
- 与 OpenCode serve/SSE 的取舍：stdio RPC 更适合**单机桌面 Sidecar**（零端口暴露），HTTP/SSE 适合 Web 多用户（[[opencode-pi-base-development-analysis]] 跨平台矩阵）

## 六、JSONL 会话格式解析 → LogNet 数据源

- 会话树状 JSONL：每行一个事件(session/message/toolCall/…)，parent 字段构成树
- 解析要点：① 树重建靠 parent id；② toolCall 结果可能跨行引用；③ 0.x 版本 schema 变更风险→解析器带 version 分支
- 本库映射：把 Pi/OpenCode 会话行事件映射成 LogNet EventNode（ts=时间戳, entity=sessionId, content=text），复用 PoC 的折叠+FTS5 即得"Agent 会话根因检索器"——M1 后备数据通道之一

## 七、排障速查

| 症状 | 处置 |
|------|------|
| 工具参数校验不过 | TypeBox schema 写严了(min/max)；模型重试链看 event 流 |
| steer 不生效 | 当前无进行中回合（应走 followUp/prompt）；或模型已完成该步 |
| Windows 路径/编码异常 | 已知坑清单见调研报告 §Windows；统一 UTF-8 + 正斜杠 API |
| 升级破坏 | 0.84.x 锁版本；changelog diff 驱动回归脚本 |
| 嵌入端内存涨 | 会话树不裁剪→定期 fork 截断+归档 JSONL 到 LogNet |

## 八、待确认项

> ① defineTool/extend 的导出符号精确路径（以 node_modules d.ts 为准复核）；② RPC 帧完整 schema 文档化程度；③ 多模态输入(图片)的工具返回约定；④ 作用域包迁移(@earendil-works)后的旧包维护期。

## Related

[[参考-Pi-Agent-技术调研报告]] · [[pi-agent-framework-knowledge]] · [[opencode-深入使用与扩展实战]] · [[main-subagent-realtime-interaction]] · [[lognet-rootcause-multiagent-architecture]] · [[agent-harness-anatomy]]
