---
title: 主Agent与Subagent实时交互方案设计
aliases: [实时交互方案, subagent看门狗, 主子agent心跳与唤醒, Realtime Interaction]
tags: [ai/ops, ai/agent]
created: 2026-08-25
updated: 2026-08-26
status: review
---

# 主Agent与Subagent实时交互方案设计

> [!abstract] 概述
> 当前主流编码 Agent（OpenCode task 工具、Claude Code Agent 工具、Pi Agent 手动编排）的主↔子调用本质是**单向黑盒**：父级发出 prompt 后阻塞等待最终报告，中途既感知不到子级是否卡死，也无法注入新指令。本文把"实时交互"拆解为四个正交原语——**活性感知、邮箱通知、打断抢占、断点恢复**，给出分层卡死判定矩阵、升级式干预阶梯（observe → nudge → interrupt → kill）、checkpoint 协议与 OpenCode/Pi Agent 落地蓝图。

See also: [[opencode-multi-agent-architecture]] · [[fan-out-subagent-pattern]] · [[state-machine-quality-gate-loop]] · [[pi-agent-framework-knowledge]] · [[A2A多智能体协作协议]] · [[Claude-Ops-KB-Home]]

## 一、问题定义：单向黑盒的三类痛点

```
现状（主流 task 调用）:
  主Agent ──prompt──→ [Subagent 黑盒运行 ??? ] ──最终报告──→ 主Agent
                        ↑ 中途不可见 / 不可说 / 不可停
```

| 痛点 | 场景 | 后果 |
|------|------|------|
| **卡死无感知** | 子 agent 工具调用挂死（网络阻塞、交互式命令等待 stdin）、模型死循环复读 | 父级无限等待，整条流水线停摆 |
| **无法纠偏** | 父级在子级运行中发现了新信息（如需求变更、发现子级方向错误） | 只能等子级跑完再返工，浪费 token 与时间 |
| **无法抢占** | 出现更高优先级任务，或用户手动叫停 | 缺少优雅取消语义，只能杀进程 |

关键洞察：**卡死是常态而非异常**。无人值守场景（见 [[claude-unattended-methodology]]）下，任何"假设子任务总会正常完成"的编排都会在长尾失败上崩溃。控制面必须与业务面分离设计。

## 二、核心模型：四个正交原语

任何主↔子实时交互体系都可拆成四个独立原语，分别解决"看见、说话、打断、续作"：

| 原语 | 回答的问题 | DSH Harness 语义 | OpenCode 对应 | Pi Agent 对应 | A2A 对应 |
|------|-----------|------------------|---------------|---------------|----------|
| **Liveness 感知** | 它还活着吗？ | `job_output`(poll/wait) + 完成通知 | `GET /event` SSE 订阅 `message.part.updated`/`session.idle` | `session.subscribe()` 事件流 | `tasks/get` 轮询 + SSE `status-update` |
| **Mailbox 通知** | 我说的话它何时听到？ | `send_message`：排队，当前轮结束后投递 | SDK 向子会话追加 user 消息（排队）+ 插件 hook 注入未读提示 | `followUp()`（下轮交付）；`steer()` 更强——直接注入**当前轮**（见下方 tip） | 向 working 态 Task 追加 Message |
| **Interrupt 抢占** | 如何让它立刻停下？ | `interrupt_agent`：仅停止当前轮，队列保留 | Server abort 端点中止会话当前轮 | AbortSignal 贯穿 LLM 流与工具执行 + `interrupt()` 优雅中断（允许清理） | `canceled` 终态 |
| **Checkpoint 恢复** | 停了之后怎么便宜地继续？ | 任务状态文件 + 共享工作区记忆 | 会话 JSONL 持久化 + 产物落盘 | 树状 JSONL 可 fork 分支恢复 | Artifact 已交付部分不回收 |

> [!tip] 设计原则
> 四原语正交意味着可独立演进：先用文件轮询实现 Liveness（零依赖），Mailbox 可以先于 Interrupt 落地（更安全），Checkpoint 则是其余三个原语的"安全网"。参考 [[interactive-aware-subagent-plan-2026-07-03]] 的教训——hook 是 advisory 的，硬约束必须落在文件系统等可验证介质上。

## 三、卡死判定：四层活性金字塔

单一指标必然误判（进程活着 ≠ 在干活；在出 token ≠ 在推进任务）。采用四层金字塔，逐层收窄"真活着"的定义：

```
        ┌────────────────┐
        │ L3 语义活性      │ ← 任务在推进（todo 有变化、产物在增长）
        ├────────────────┤
        │ L2 进度活性      │ ← 心跳文件持续更新（每步工具调用后 touch）
        ├────────────────┤
        │ L1 会话事件活性   │ ← SSE/事件流上有新事件（token/part 更新）
        ├────────────────┤
        │ L0 进程活性      │ ← PID 存在、CPU/内存波动
        └────────────────┘
```

| 层级 | 采集方式 | 能证明 | 不能证明 | 典型采集延迟 |
|------|---------|--------|---------|-------------|
| L0 进程 | PID 存在性检查、CPU 时间增量 | 没崩溃 | 可能空转/挂死 | 秒级 |
| L1 会话事件 | SSE 流最后事件时间戳 | 在推理/执行工具 | 可能原地绕圈 | 亚秒级 |
| L2 进度心跳 | 心跳文件 mtime（由 hook 自动写入） | 在执行离散步骤 | 步骤可能无效重复 | 步长级 |
| L3 语义 | todo diff、产物哈希变化、工具签名序列环检测 | 任务实质推进 | —（最强信号） | 任务段级 |

### 判定矩阵与分类对策

| L0 | L1 | L2 | L3 | 诊断 | 对策 |
|----|----|----|----|------|------|
| ✗ | — | — | — | 崩溃 | 直接 T3 kill + checkpoint 恢复 |
| ✓ | ✗ >T_hard | ✗ | ✗ | **假死 hang**（工具挂起/网络阻塞） | T2 interrupt 当前轮 → 重试或换路 |
| ✓ | ✓ | ✓ | ✗ 连续 N 步 | **循环 loop**（复读/打转） | T1 nudge 注入纠偏指令；再犯 → T2 |
| ✓ | ✓ | ✓ | ✓ 但慢 | 正常缓慢 | T0 观察；可调低轮询频率 |
| ✓ | ✓ | ✗ >T_soft | ✗ | 半活跃（模型输出但不再动工具） | T1 nudge "汇报当前状态" |

阈值经验值起点：`T_soft = 3 × 平均步长`，`T_hard ≥ 120s`（参考 [[interactive-aware-subagent-plan-2026-07-03]] 的 stale 判定），`N_loop = 3` 次相同 `(tool, args哈希)` 序列。所有阈值应配置化并按任务类别分档（只读探索类放宽，写操作类收紧）。

## 四、通知与唤醒：升级式干预阶梯

核心思想：**干预强度与确信度成正比**，从观察到强拆逐级升级，每一级都给下一级留证据。

```
T0 observe ──超时──→ T1 nudge ──无响应×k──→ T2 interrupt ──重试超限──→ T3 kill+ESCALATE
  仅记录              邮箱软提醒            打断当前轮+注入指令         终止+上报人类
```

| 级别 | 动作 | 机制要点 | 代价 |
|------|------|---------|------|
| T0 观察 | 写监控日志，不接触子会话 | 心跳表 + 判定矩阵 | 零干扰 |
| T1 nudge | 投递 mailbox 消息："收到请确认，若遇阻请说明" | 文件 inbox 或 SDK 排队消息；**不打断当前轮**（同 DSH `send_message` 语义：排队到本轮结束） | 低；子级下个工具间隙可见 |
| T2 interrupt | abort 当前轮 → 立即注入纠偏指令重启一轮 | OpenCode server abort / DSH `interrupt_agent` / Pi abort | 中；丢失本轮未落盘的中间思考 |
| T3 kill & escalate | 杀作业 → 标记 failed → 上报父级/人类 | `job_kill` 或杀进程；触发 checkpoint 恢复或人工介入 | 高；必须有 checkpoint 才不白干 |

> [!tip] Pi 的 steer() 是介于 T1 与 T2 之间的第四档
> Pi 的 `steer()` 能把消息注入**正在执行中的 turn**（模型当轮即可看到并转向），无需 abort——相当于"不打断的打断"。干预阶梯在支持该语义的框架上应扩展为：T1 排队投递 → **T1.5 当轮注入（steer）** → T2 abort 重启。OpenCode 无此原语时只能靠 T1/T2 组合模拟。详见 [[参考-Pi-Agent-技术调研报告]] §3。

### Mailbox 协议设计

```json
// .agent-bus/inbox/<task_id>/msg-<seq>.json —— 单向写、读后移入 archive/
{
  "id": "msg-17",
  "from": "parent-session-id",
  "type": "nudge | data | reprioritize | stop",
  "ts": "2026-08-25T22:40:00Z",
  "body": "方向有误：目标文件已迁移至 src/v2/，请重新定位",
  "requires_ack": true
}
```

三条纪律：

1. **注入不靠模型自觉**。靠 prompt 里写"记得查邮箱"必然被遗忘；正确做法是在框架层缝入——OpenCode 用插件 `chat.message`/`tool.execute.before` hook 在每次工具调用前自动检查 inbox 并注入未读摘要；Pi Agent 用 extension 的 beforeToolCall 事件做同样的事。
2. **消息幂等且带序号**。子级以 `inbox_cursor` 记录消费位点，重复投递不产生重复效果（T2/T3 重试时尤其重要）。
3. **stop 类消息直达控制面**。控制面 hook 见 `type:"stop"` 直接调用 abort，不经模型。

## 五、Checkpoint 恢复协议

打断和崩溃之所以可承受，前提是"重来很便宜"。三要素：

### 5.1 任务状态文件（唯一事实源）

```json
// .agent-bus/state/<task_id>.json —— 子agent每完成一个原子步骤即更新
{
  "task_id": "t-042",
  "parent": "session-abc",
  "goal": "梳理 network/scripts 下全部脚本用途",
  "status": "running | nudged | interrupted | done | failed",
  "steps_done": ["扫描目录", "读取 ps1×6"],
  "next_step": "读取剩余 sh 脚本",
  "artifacts": ["out/script-inventory.md"],
  "inbox_cursor": 17,
  "heartbeat_ts": "2026-08-25T22:41:33Z"
}
```

### 5.2 产物落盘纪律

- 中间结论**即时写盘**（append 到 artifacts 文件），不攒在上下文里等最终报告——被打断时上下文可弃，盘上资产保留；
- 最终报告 = 状态文件的收尾更新 + 一段面向父级的摘要，二者缺一不可。

### 5.3 恢复 prompt 模板

```text
你此前执行任务 t-042 中断。读取 .agent-bus/state/t-042.json 与 artifacts/，
从 next_step 继续；已完成步骤勿重做；每步完成即更新状态文件；
收到本消息前若有未读 mailbox 消息，先处理再继续。
```

树状会话存储（Pi 的 JSONL fork、OpenCode 的会话持久化）让"恢复"可以落在原分支或新分支上，避免污染原始历史。

## 六、参考实现蓝图

### 6.1 OpenCode 版（插件 + Server 双轮）

```
┌─ 主会话 (primary) ──────────────────────────────┐
│  task 工具发起 subagent；自身也订阅 bus 摘要       │
└───────────────┬─────────────────────────────────┘
                │ spawn（隔离会话）
┌─ supervisor 插件 (.opencode/plugin/) ────────────┐
│ event hook: message.part.updated → 刷新心跳表     │
│             session.idle/error    → 结账          │
│ 定时器: 扫描判定矩阵 → 触发 T1..T3                  │
│   T1: SDK 向子会话发消息(排队) / 写 inbox           │
│   T2: server abort → 重发带 checkpoint 的 prompt   │
│ tool.execute.after hook: 代写心跳文件（零模型自觉）  │
│ tool.execute.before hook: 检查 inbox 注入未读      │
└───────────────┬─────────────────────────────────┘
┌─ 外置看门狗（可选，语言无关）───────────────────────┐
│ 读 .agent-bus/ 心跳表；对 >T_hard 的任务调          │
│ server abort 端点；与插件互为冗余（双保险）           │
└─────────────────────────────────────────────────┘
```

要点：OpenCode 原生 task 调用是阻塞式的，**并行与后台化靠 supervisor 经 Server/SDK 自建会话实现**（社区方案 opencode-agent-intercom 即此思路）；subagent 递归嵌套官方长期限制（issue #9280），故控制面放在 primary 侧或外置进程，不放 subagent 内部。

### 6.2 Pi Agent 版（进程内原生）

Pi 无内置子 agent 但 SDK 全在手：官方 subagent 示例扩展与社区方案（tmux 并行 / 进程内子会话 / headless 子代理）均复用 `createAgentSession()`；`session.subscribe()` 事件流即感知层；`followUp()`/`steer()` 双队列即 Mailbox 与 T1.5；AbortSignal+`interrupt()` 即 Interrupt；树状 JSONL + fork 即 Checkpoint。**四原语全部进程内可得**，适合做成服务化基座（对照 [[pi-agent-framework-knowledge]]：无内置权限/HTTP 层需自建；注意 0.x API 变更风险，见 [[参考-Pi-Agent-技术调研报告]] §9）。

### 6.3 与既有三层模式的拼图

```
[[fan-out-subagent-pattern]]      → 分发层：谁来做（并行分发、防冲突）
本文（实时交互方案）               → 控制面：做得怎样（感知/通知/打断/恢复）
[[state-machine-quality-gate-loop]] → 业务面：做得对不对（质量门控回环、RETRY/ESCALATE）
```

三者叠加才构成完整的多智能体生产系统：Fan-Out 没有 watchdog 是裸奔，watchdog 没有质量门是盲干，质量门没有 Fan-Out 是串行浪费。

## 七、反模式清单

> [!warning] 五个高频反模式
> 1. **心跳靠模型自觉** —— prompt 里要求"定期汇报进度"，模型一忙就忘；心跳必须由框架 hook 代写。
> 2. **nudge 无限重试** —— 不设 `max_nudge` 与退避，T1 变成消息风暴，反而拖垮子会话上下文。
> 3. **打断不落 checkpoint** —— T2/T3 前没有状态文件，等于把已完成工作全部作废。
> 4. **全局广播** —— 一条通知发给所有 subagent，无关者也被唤醒消耗 token；mailbox 必须按 task_id 寻址。
> 5. **控制面塞进业务上下文** —— 把心跳/邮箱细节写进子 agent 的系统提示词，污染注意力预算（对照 Pi ~800 token 预算哲学）；控制信息走结构化通道，不走自然语言上下文。

## 八、开放问题

- **语义活性(L3)的误报率**：工具签名环检测对"合理重复"（如同名测试反复跑）会误判，需要按工具类白名单豁免；
- **跨机部署**：`.agent-bus/` 文件协议限于单机共享盘，跨机要换成 Redis/消息队列，判定矩阵不变、传输层替换；
- **优先级反转**：T2 打断正在持锁写文件的子 agent 可能留下半成品，需要与文件锁（参见 [[subagent-resource-architecture-2026-07-03]]）联动——先等锁释放窗口再打断；
- **OpenCode 原生演进**：官方 agent-teams 方向（issue #15035）若落地，本文 supervisor 大部分能力会被原生吸收，迁移路径是把 `.agent-bus/` 协议映射到原生事件。

## Related

- [[opencode-multi-agent-architecture]] — OpenCode 两层模型与本方案的宿主架构
- [[fan-out-subagent-pattern]] — 分发层拼图
- [[state-machine-quality-gate-loop]] — 业务面质量回环拼图
- [[subagent-resource-architecture-2026-07-03]] — 资源维度姊妹篇（锁与门禁）
- [[pi-agent-framework-knowledge]] — Pi Agent 事件流/会话树依据
- [[参考-OpenCode-技术调研报告]] · [[参考-Pi-Agent-技术调研报告]] — 两基座控制面 API 依据（Server/SDK、steer/followUp）
- [[A2A多智能体协作协议]] — 跨进程/跨框架时的协议化对应物
