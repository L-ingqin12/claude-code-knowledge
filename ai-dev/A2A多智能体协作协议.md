---
title: A2A多智能体协作协议
aliases: [A2A协议, Agent2Agent, A2A多智能体协作, 多智能体协作协议]
tags: [ai, ai/agent]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# A2A多智能体协作协议

**一句话定位**：A2A（Agent-to-Agent，智能体间协作协议）是 Google 牵头发起的开放协议，让构建于不同框架的 Agent 之间能够相互发现、委托任务并交换产物——MCP 解决了"Agent ↔ 工具"的连接，A2A 解决的则是 MCP 够不着的"Agent ↔ Agent"连接。

> [!abstract] 概述
> 本文档对应课程第 12 章，依次回答四个问题：**为什么**需要 A2A（MCP 的盲区）、**解决什么**问题（能力发现 / 任务委托 / 协作通信）、**如何**解决（Agent Card + Task 生命周期 + HTTP/JSON-RPC/SSE）、**如何落地**（a2a-sdk 最小 server/client 与 LangGraph 结合）。
> 建议先读 [[MCP协议开发实战]]（对比基线）与 [[LLM-Agent开发基础]]（Agent 概念）。

## 核心概念

### A2A 解决的三大问题

| 问题 | MCP 的盲区 | A2A 的答案 |
|------|-----------|------------|
| 能力发现（Discovery） | 只描述"工具"，不描述"会用工具的人" | Agent Card：公开身份卡描述"我能干什么" |
| 任务委托（Delegation） | 无"把活外包给别的 Agent"的概念 | Task：一等公民的任务对象，带完整生命周期 |
| 协作通信（Collaboration） | 客户端-服务器单向调用 | 双向消息 + 产物（Artifact）交换 |

### 参与者角色

| 参与者 | 角色 |
|--------|------|
| Client Agent（客户端智能体） | 发起方：发现对方、提交任务、接收产物 |
| Server Agent（服务端智能体） | 远端：公开能力、执行任务、回传结果 |
| User（人类用户） | 任务源头与最终受益者，可中途介入（input-required） |

### 基本通信要素

| 概念 | 说明 |
|------|------|
| Agent Card（智能体身份卡） | 公开的 JSON 元数据：技能、能力、端点、认证方式，挂在 `/.well-known/agent.json` |
| Task（任务） | A2A 通信的基本单元，有独立 ID 与生命周期 |
| Message（消息） | 包裹在 Task 内的对话片段，含 `role` 与 `parts` |
| Part（消息片段） | Message 的组成部分：文本、文件、结构化数据 |
| Artifact（产物） | 任务产出：文档、代码、图片，可内联也可用 URI 引用 |
| Skill（技能） | 服务端声明的能力（如"写 Python 代码"），客户端按需调用 |

### Task 任务生命周期

| 状态 | 含义 |
|------|------|
| `submitted` | 客户端已提交，等待服务端受理 |
| `working` | 服务端 Agent 正在执行 |
| `input-required` | 任务暂停，等待客户端补充信息（人工确认） |
| `completed` | 任务完成，携带最终 Artifact |
| `failed` | 执行失败，附错误信息 |
| `canceled` | 被任一方取消 |
| `rejected` | 提交被服务端拒绝（能力不符 / 参数非法） |
| `auth-required` | 任务需客户端/用户完成认证后才能继续（v0.2 规范既有状态；枚举仍在扩展，官方仓库后续新增 `user-consent-required` 等成员，见 [a2aproject/A2A 提交记录](https://github.com/a2aproject/A2A/commit/5817ffbfbdf19746dad2e1865793e51bd0d9f8bc)） |

> [!note] 状态机要点
> 正常路径 `submitted → working → completed`；`input-required` 是 A2A 独有的双向暂停态，用于中途向对方要材料或等人工拍板；`failed / canceled` 是终态。客户端的轮询与 SSE 订阅本质都是在跟踪这个状态机的推进。

### 设计关键原则

| 原则 | 含义 |
|------|------|
| 简单（Embrace Agentic） | 只定义"委托任务"这一核心原语，不规定 Agent 内部怎么实现 |
| 企业就绪（Enterprise Ready） | 基于成熟技术栈：HTTP + JSON-RPC 2.0 + SSE，天然穿透防火墙、可审计 |
| 异步优先（Async First） | 长任务不阻塞：SSE 流式回调或轮询获取进度 |
| 不透明执行（Opaque Execution） | 对方无需知道你用什么框架、模型、工具——只看 Agent Card 与产物 |

### 交互机制

| 场景 | 机制 |
|------|------|
| 同步短任务 | 一次 `message/send` 请求-响应即拿结果 |
| 长任务 | `tasks/send` 创建 Task 后轮询 `tasks/get` |
| 长任务流式 | `tasks/sendSubscribe` 通过 SSE 实时推送 `status-update` / `artifact-update` 事件 |

### A2A vs MCP 对比

| 维度 | MCP（Model Context Protocol） | A2A（Agent-to-Agent） |
|------|------------------------------|-----------------------|
| 定位 | Agent ↔ 工具 / 数据源 | Agent ↔ Agent |
| 原语 | Tool / Resource / Prompt | Agent Card / Task / Message / Artifact |
| 传输 | stdio / SSE / Streamable HTTP | HTTP + JSON-RPC 2.0 + SSE |
| 发现机制 | 连接后 `tools/list` 枚举工具 | 拉取 `/.well-known/agent.json` 身份卡 |
| 执行方 | Agent 自己调用工具 | 把任务委托给对端 Agent 执行 |
| 典型场景 | 让 Agent 会查数据库、调 API | 跨框架多 Agent 分工：前端 Agent 委托后端 Agent 修 bug |
| 关系 | 互补：Agent **内部**用它连工具 | 互补：Agent **之间**用它委托任务 |

## 原理剖析

### 为什么出现 A2A：MCP 的盲区

MCP 定义了 Agent 与工具之间的统一协议，但它假设"调用方是 Agent、被调方是工具"。现实里大量价值沉淀在**别人家的 Agent** 里（例如一个精通运维排障的 Agent）。跨框架 Agent 之间互不知名：不知道对方存在（无发现机制）、不知道对方能不能干这活（无能力声明）、没法把活外包（无任务委托原语）。于是只能"人肉中转"——用户把 A 的答案复制粘贴给 B。A2A 的出发点就是把这个中转自动化、标准化。

### 如何解决：发现 → 委托 → 通信三段式

1. **发现**：每个 A2A Agent 在 `/.well-known/agent.json` 公开 Agent Card（技能列表、能力、端点、认证方式），客户端拿到 Card 即知对方"是谁、会什么"——这与 Web 的 robots.txt / 手机号的通讯录名片是同一个思路；
2. **委托**：`message/send`（短任务）或 `tasks/send`（长任务）创建 Task，服务端按 Task 生命周期推进，客户端通过轮询或 SSE 订阅进度；
3. **通信**：Task 内的 Message / Part 承载对话，Artifact 承载产物（小产物内联 base64，大产物用 URI 引用，避免协议栈被大数据压垮）。

```
用户 ──→ Client Agent ──(发现: GET /.well-known/agent.json)──→ Server Agent
            │                                                      │
            │←──(返回 Agent Card: 技能/能力/端点/认证)────────────│
            │                                                      │
            │──(委托: tasks/send 创建 Task, 返回 task_id)─────────→│
            │                                                      │
            │←──(SSE: status-update working → input-required → …)──│
            │←──(SSE: artifact-update 产物增量 → 最终产物)────────│
```

### 与 MCP 的配合：互补而非竞争

两者解决不同层级的连接问题，**一个 Agent 系统里通常同时存在**：Agent 内部用 MCP 连接自己的工具（查库、调 API），Agent 之间用 A2A 互相委托（把不属于自己技能的任务外包出去）。

| 连接层级 | 协议 | 连接对象 | 类比 |
|----------|------|----------|------|
| 内部 | MCP | 工具 / 数据 | 员工与工具 |
| 外部 | A2A | 其他 Agent | 员工与外包团队 |

> [!tip] 判断用谁
> 对方是一个"函数 / 服务"→ 用 MCP；对方是一个"会思考、会调用工具的 Agent"→ 用 A2A。MCP 的调用方永远是 Agent，A2A 的调用方也是 Agent——差别只在被调方是人还是物。

## 最小可运行 Demo

> [!warning] 版本提示
> `a2a-sdk` 版本演进较快：0.2.x → 0.3.x → 1.x（PyPI 已发布 1.1.0；仓库由 google/a2a-python 迁至 a2aproject/a2a-python，官方提供 v0.3 → v1.0 迁移指南）。下文示例以 0.3.x 写法为主（现存教程主流），0.2.x 差异在注释中标注，1.x 迁移要点见文末参考资料。安装：`pip install a2a-sdk`。以下片段聚焦协议要点，个别细节用伪代码标注，完整可运行示例以官方 a2a-samples 为准。

### Server 端：AgentSkill 定义 + Starlette 挂载

```python
# a2a_server.py —— 最小 A2A Server（a2a-sdk 0.3.x）
from a2a.server.apps import A2AStarletteApplication
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.agent_execution import AgentExecutor
from a2a.types import (AgentCapabilities, AgentCard, AgentSkill,
                       Artifact, TaskState, TaskStatusUpdateEvent,
                       TaskArtifactUpdateEvent, TextPart)

class TranslatorExecutor(AgentExecutor):
    """Agent 执行器: A2A 框架的回调, 处理每一个 Task。"""
    async def execute(self, context, event_queue):
        # 1. 从 context 取用户消息(Message/Part), 交给自己的 Agent/模型
        user_text = context.get_user_input()          # 伪代码: 提取用户输入文本
        result = await my_translate_agent.run(user_text)  # 你自己的 Agent(LangChain 也行)
        # 2. 先宣告任务完成, 再推送产物(顺序不可颠倒)
        await event_queue.enqueue_event(TaskStatusUpdateEvent(
            task_id=context.task_id, status=TaskState.completed, final=True))
        await event_queue.enqueue_event(TaskArtifactUpdateEvent(
            task_id=context.task_id,
            artifact=Artifact(name="translation.txt",
                              parts=[TextPart(text=result)]),
            last_chunk=True))

skill = AgentSkill(
    id="translate_zh_en", name="中英互译",
    description="把中文文本翻译成英文(或反向), 支持整段与术语表",
    tags=["translation", "nlp"], examples=["你好 → Hello"])

server = A2AStarletteApplication(
    agent_card=AgentCard(
        name="翻译 Agent", url="http://localhost:8000", version="1.0.0",
        capabilities=AgentCapabilities(streaming=True),   # 声明支持 SSE 流式
        skills=[skill],                                    # 技能清单
        default_input_modes=["text"], default_output_modes=["text"]),
    http_handler=DefaultRequestHandler(
        agent_executor=TranslatorExecutor()))              # 挂载执行器

app = server.build()   # Agent Card 自动暴露在 /.well-known/agent.json
# 0.2.x 写法: StarletteApplication(...) + app.add_route(AGENT_CARD_WELL_KNOWN_PATH, ...)
# 启动: uvicorn.run(app, port=8000)
```

### Client 端：发现 Agent Card → 提交任务 → 轮询 / 流式

```python
# a2a_client.py —— 最小 A2A Client
import asyncio
from a2a.client import A2ACardResolver, A2AClient
from a2a.types import MessageSendParams, Message, TextPart
from a2a.types import TaskArtifactUpdateEvent

async def main():
    # 1. 发现: 按 URL 拉取身份卡(约定路径 /.well-known/agent.json)
    card = await A2ACardResolver("http://localhost:8000").get_agent_card()
    print("发现的 Agent 技能:", [s.name for s in card.skills])

    client = A2AClient(card)      # 2. 用 Card 构造客户端

    # 3a. 短任务: 同步发送消息, 一次往返直接拿结果
    result = await client.send_message(MessageSendParams(
        message=Message(role="user", parts=[TextPart(text="你好世界")])))
    print("短任务回复:", result)

    # 3b. 长任务: 提交后轮询 Task 状态(submitted → working → completed)
    task = await client.send_message(MessageSendParams(
        message=Message(role="user", parts=[TextPart(text="翻译整本手册(长任务)")])))
    while True:
        task = await client.get_task(task.id)          # 轮询进度
        if task.status.state.value in ("completed", "failed"):
            break                                       # task.artifacts 即最终产物
        await asyncio.sleep(1)

    # 3c. 长任务: SSE 流式订阅(服务端声明 streaming 时可用)
    async for event in client.send_message_streaming(MessageSendParams(
            message=Message(role="user", parts=[TextPart(text="翻译并实时回传")]))):
        if isinstance(event, TaskArtifactUpdateEvent):
            print("收到产物增量:", event.artifact)

asyncio.run(main())
```

### 结合 LangGraph：把 ReAct Agent 包装成远端技能

A2A 不关心内部实现——`AgentExecutor.execute` 里调 LangChain、LangGraph 还是裸模型都行（不透明执行原则）：

```python
# executor_graph.py —— A2A Server 内嵌 LangGraph ReAct Agent 作为被委托技能
from langgraph.prebuilt import create_react_agent      # 一行建 ReAct Agent
from langchain.chat_models import init_chat_model

class GraphExecutor(AgentExecutor):
    def __init__(self):
        self.agent = create_react_agent(               # 内部 Agent(可用 MCP 连工具)
            model=init_chat_model("deepseek-chat"),
            tools=[search_web, run_code])
    async def execute(self, context, event_queue):
        text = context.get_user_input()
        async for chunk in self.agent.astream({"messages": [("user", text)]}):
            ...   # 伪代码: 把 LangGraph 输出转发为 A2A 事件流
        await event_queue.enqueue_event(...)           # completed + Artifact
```

> [!tip] "内 MCP + 外 A2A"完整拼图
> GraphExecutor 内部的 Agent 用 MCP 连自己的工具，整体作为一个 Skill 通过 A2A 对外提供——被委托方"不透明执行"，委托方完全不知道里面是 LangGraph。LangGraph 侧多代理编排细节见 [[LangChain-LangGraph框架实战]]。

## 进阶实践与常见坑

### 生产化设计要点

| 关注点 | 建议 |
|--------|------|
| 认证 | Agent Card 声明 `securitySchemes`（OAuth2 / API Key），企业内网也要做来源校验 |
| 幂等 | Task ID 服务端保持幂等，客户端重试不产生重复任务 |
| 大产物 | 大文件用 Artifact 的 URI 引用（对象存储签名 URL），协议只传元数据 |
| 超时 | 长任务设 TTL；客户端轮询用指数退避 + 抖动 |
| Card 缓存 | Agent Card 变更不频繁，客户端可短 TTL 缓存，失败时强制刷新 |

### 常见坑清单

> [!bug] 高频坑
> 1. **版本混淆**：网上教程 0.2.x（`StarletteApplication` + `DefaultRequestHandler` 手动 add_route）与 0.3.x（`A2AStarletteApplication` 一步挂载）、1.x（API 再次调整，见官方迁移指南）写法混用，报 `AttributeError`——先 `pip show a2a-sdk` 再选写法；
> 2. **忘开 streaming 却用流式**：Agent Card 的 `capabilities.streaming` 未声明 true，客户端流式订阅收不到 SSE 事件；
> 3. **任务卡在 working**：`execute` 里异常被吞、没发 `completed` 事件——用 finally 块保证终态事件一定发出；
> 4. **只发 Artifact 不发终态**：先 completed 后 artifact，或漏发 `final=True`，客户端轮询永远不退出；
> 5. **把 A2A 当 RPC 用**：大模型 Agent 任务多为分钟级，`send_message` 同步死等会超时——长任务走轮询 / 流式订阅；
> 6. **安全**：生产环境把 Agent Card 端点限制在允许列表内，防止被陌生 Agent 探测并塞恶意任务。

## 相关文档

- [[MCP协议开发实战]] — MCP 工具协议细节（A2A 的对比基线与 Agent 内部工具层）
- [[LLM-Agent开发基础]] — Agent 基础概念与 ReAct / 工具调用范式
- [[LangChain-LangGraph框架实战]] — LangGraph 多代理编排（A2A 被委托端最常用的实现）
- [[AI大模型开发]] — 大模型原理（所有 Agent 的底座）
- [[AI-Dev-KB-Home]] — AI 开发知识库首页 MOC

## 参考资料

- A2A 协议官方规范（Python）：<https://a2aprotocol.ai/docs/guide/a2a-protocol-specification-python>
- A2A Task 状态机详解（DeepWiki）：<https://deepwiki.com/google/a2a-python/4.1-task-state-machine>
- a2a-python 类型定义源码（TaskState 枚举，fork 镜像）：<https://github.com/martimfasantos/a2a-python/blob/a402a3bf610705c77e83c86f3b200027a77afcf3/src/a2a/types.py>
- a2a-sdk PyPI 发布页（当前版本 1.1.0，版本事实核实来源）：<https://pypi.org/project/a2a-sdk/1.1.0/>
- a2a-python v0.3 → v1.0 官方迁移指南：<https://raw.githubusercontent.com/a2aproject/a2a-python/b598dfccf6e3e9b4e0abddffe2c2f26da3059ff1/docs/migrations/v1_0/README.md>
- A2A Python SDK 入门（DeepWiki）：<https://deepwiki.com/google/A2A/4.1.1-getting-started-with-python-sdk>；客户端交互教程：<https://a2a-protocol.org/pr-849/tutorials/python/6-interact-with-server/>
