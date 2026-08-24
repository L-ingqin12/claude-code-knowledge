---
title: LangChain-LangGraph框架实战
aliases: [LangChain实战, LangGraph实战, LCEL框架, LangChain框架实战]
tags: [ai, ai/agent]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# LangChain-LangGraph框架实战

**一句话定位**：LangChain 用 LCEL（LangChain Expression Language，LangChain 表达式语言）把"提示词 → 模型 → 解析"组合成可复用管道，LangGraph 再把管道升级为带环状态机（StateGraph）——本文档按"生态分工 → LCEL 管道 → Agent 构建 → LangGraph 深度实战 → 多代理与混合检索"的路径一次讲透，并给出两个最小可运行 Demo。

> [!abstract] 概述
> 本文档对应课程第 18 章（新版）与第 19 章，覆盖三块内容：
> 1. **LangChain 生态**：langchain-core / langchain-community / langsmith / langgraph 四大包分工、`init_chat_model` 统一接入、LCEL 管道与 Runnable 协议、智能问答链、工具调用 Agent、MCP 接入、RAG 四件套；
> 2. **LangGraph 深度**：Chain 与 Graph 的本质区别、StateGraph 三件套、Reducer 追加语义、三种单代理实现对比、事件流、长短期记忆（Checkpointer / Store）、人机交互断点；
> 3. **多代理与混合检索**：Network / Supervisor / Hierarchical 三种多代理架构、Supervisor 代码实践、向量库 + Neo4j GraphRAG 双检索案例。
> 前置知识建议先读 [[AI大模型开发]]（模型原理）与 [[LLM-Agent开发基础]]（Agent 概念）。

## 核心概念

### LangChain 生态四大包分工

| 包 | 职责 | 典型内容 | 类比 |
|----|------|----------|------|
| `langchain-core` | 核心抽象层，无具体模型依赖 | Runnable 协议、Message、Prompt、OutputParser | 语言的标准库 |
| `langchain-community` | 第三方集成大杂烩 | DocumentLoader、VectorStore、第三方 Tool | 社区软件源 |
| 厂商包（`langchain-openai` / `langchain-deepseek` 等） | 各模型厂商适配 | ChatOpenAI、ChatDeepSeek | 设备驱动 |
| `langgraph` | 有状态、带环的编排运行时 | StateGraph、Checkpointer、ToolNode | 状态机引擎 |
| `langsmith` | 可观测性与评估平台 | tracing 链路追踪、数据集评测 | 监控 + 测试台 |

> [!tip] 选型建议
> 只做单次问答/抽取 → 装 `langchain-core` + 厂商包；需要检索/第三方工具 → 加 `langchain-community`；需要循环/多步决策 → 上 `langgraph`。不必把全家桶都装齐。

### 接入大模型：init_chat_model

`init_chat_model("deepseek-chat")` 是 LangChain 0.3+ 的统一接入入口：按模型名自动匹配厂商适配包，并按约定读取环境变量（如 `DEEPSEEK_API_KEY`、`OPENAI_API_KEY`），还支持显式指定 `model_provider`、`base_url`、`temperature` 等参数。换模型只需改一个字符串，链代码零改动。

### LCEL 核心原语速查

| 原语 | 作用 | 示例 |
|------|------|------|
| `\|` 管道符 | 把 Runnable 串成链 | `prompt \| model \| parser` |
| Runnable 协议 | 统一接口：`invoke / ainvoke / stream / batch` | 组合出的链自动获得同步/异步/流式/批量 |
| `bind_tools()` | 把工具 schema 注入模型 | `llm.bind_tools([tool1, tool2])` |
| `with_structured_output()` | 强制输出结构化 JSON | `llm.with_structured_output(Route)` |
| `RunnablePassthrough` | 透传输入字段 | `{"q": RunnablePassthrough()}` |
| `RunnableParallel` | 分支并行执行 | 多路检索并行召回 |
| `with_fallbacks()` | 失败降级 | 主模型挂了自动切备用模型 |

### RAG 四件套

| 组件 | 作用 | 常用实现 |
|------|------|----------|
| Loader（加载） | 从 PDF / 网页 / 数据库读原始文档 | `PyPDFLoader`、`WebBaseLoader`、`TextLoader` |
| Splitter（切分） | 按语义边界切块 | `RecursiveCharacterTextSplitter(chunk_size, chunk_overlap)` |
| Embedding（向量化） | 文本 → 稠密向量 | `OpenAIEmbeddings`、`HuggingFaceEmbeddings` |
| VectorStore / Retriever（存检） | 存向量、按相似度召回 | FAISS、Chroma、`as_retriever(k=4)` |

### Chain（LangChain）vs Graph（LangGraph）

| 维度 | LangChain Chain | LangGraph Graph |
|------|-----------------|-----------------|
| 拓扑 | 有向无环管道（DAG） | 带环状态机（StateGraph） |
| 执行 | 单次从左到右 | 节点间循环，直到条件边放行 |
| 状态 | 隐式传递（链内不可见） | 显式 State，可检查、可持久化 |
| 适合场景 | 问答、翻译、抽取等固定流程 | Agent 工具循环、人机交互、多代理 |
| 一句话 | "管道" | "会转圈的管道" |

### LangGraph 核心三件套

| 要素 | 说明 |
|------|------|
| `StateGraph(State)` | 图容器，State 为 TypedDict 定义的状态字典 |
| Nodes（节点） | 函数：读 State → 返回 `{"字段": 增量}` 更新 |
| Edges（边） | `add_edge`（固定边）/ `add_conditional_edges`（条件边，按返回值路由） |

### 记忆体系：短期 Checkpointer vs 长期 Store

| 维度 | Checkpointer（短期） | Store（长期） |
|------|---------------------|---------------|
| 存什么 | 每一步的 State 快照（对话历史） | 结构化键值（用户画像等） |
| 隔离键 | `thread_id`（一个会话一条线） | `namespace`（可跨 thread 共享） |
| 实现 | `MemorySaver`（内存）/ `SqliteSaver`（落盘） | `InMemoryStore` / 自实现 `BaseStore` |
| 用途 | 多轮记忆、断点恢复、人机审批 | 跨会话的用户偏好沉淀 |

### 三种单代理实现对比

| 实现 | 机制 | 适用模型 | 优点 | 缺点 |
|------|------|----------|------|------|
| Router Agent | 结构化输出做意图路由 | 任意支持 JSON 输出的模型 | 清晰、可审计 | 路由粒度固定 |
| Tool Calling Agent | `bind_tools` + 条件边 `tools_condition` | 支持原生 function calling | 模型自主决策、实现最简 | 依赖模型工具调用质量 |
| ReAct Agent | 显式 Reason-Act 提示词循环 | 通用模型（无 function calling 也可） | 兜底方案、可解释 | 提示词长、速度慢 |

### 多代理架构三类型

| 类型 | 拓扑 | 特点 | 代表 |
|------|------|------|------|
| Network（对等网络） | 全连接，Agent 互相通信 | 去中心化、易扩展 | 多 Agent 协作网络 |
| Supervisor（主管编排） | 星型：主管调度各 worker | 集中决策、流程可控 | LangGraph supervisor |
| Hierarchical（层级） | 树状：父图套子图，子图内可再有主管 | 团队分工、可递归 | Magentic-One 思想 |

## 原理剖析

### LCEL 管道与 Runnable 协议

LCEL 的魔法只有一句话：**LangChain 里每个组件都是一个 Runnable，Runnable 之间用 `|` 连接**。`prompt | model | parser` 本质是三层函数调用：prompt 把输入变量渲染成 Message 列表 → model 产出 AIMessage → parser 抽成字符串。因为所有组件遵循同一个 Runnable 协议，**组合出的链自动获得全部四种调用方式**——这不是语法糖，而是接口一致性带来的免费午餐：

```python
chain = prompt | model | parser
chain.invoke(...)                 # 同步
# 异步：await chain.ainvoke(...) —— 须在 async def 内或事件循环中调用
for chunk in chain.stream(...):   # 流式（逐 token）
    ...
chain.batch([...])                # 批量并发
```

三种链形态的演进：**最简 Chain**（`prompt | model | parser`，三步直通）→ **复杂 Chain**（加 `bind_tools` 工具调用或接 Retriever 检索）→ **复合 Chain**（`RunnableParallel` 把多路分支并行执行后合并，如"翻译 + 摘要 + 关键词"三路并行再汇入一个 prompt）。

### Chain 与 Graph 的本质区别：为什么 Agent 需要"环"

Chain 是有向无环图（DAG）：数据从左流到右，一步到位。但 Agent 的思考模式是**循环**：模型产生工具调用 → 工具返回观察 → 模型基于观察再决策 → 可能再次调用工具，直到任务完成。这个"调用-观察-再思考"的回路无法用一条直线表达，于是 LangGraph 用状态机解决：`agent` 节点与 `tools` 节点之间用条件边连接，`tools_condition` 检查最后一条消息里有没有 `tool_calls`——有就走 `tools` 节点执行工具，没有就走到 `END` 输出答案。**图中的环不是缺陷，而是 Agent 的核心能力**。

### State 进阶：Reducer、消息传递与可视化

节点返回的字典如何合并进全局 State？由 State 字段的 **Reducer 函数（归约函数）**决定：

| Reducer | 语义 | 典型场景 |
|---------|------|----------|
| 默认（无 reducer） | 覆盖：新值直接替换旧值 | `current_city: str` |
| `operator.add` | 追加：新旧值列表拼接 | 日志、事件流 |
| `add_messages` | 智能追加：按消息 ID 去重、支持删除 | `messages` 列表 |

```python
class State(TypedDict):
    messages: Annotated[list, add_messages]   # 追加语义(自动去重)
    city: str                                  # 默认覆盖语义
```

**消息传递**：节点之间不直接互相调用，而是通过 State 的 `messages` 字段接力——上一节点写入的消息，下一节点原样读到，输入元组（如 `("user", "你好")`）由 LangGraph 自动转成 `HumanMessage / AIMessage / ToolMessage` 对象，工具调用结果以 `ToolMessage` 回流模型。

**Graph 可视化**：`graph.get_graph()` 返回图对象，可导出图像文件（`draw_png()`）或打印 ASCII 拓扑，用于排查"边接错了、节点漏了"——可视化在多代理调试时几乎是必需品。

### 事件流：updates vs values

`graph.stream(input, stream_mode=...)` 的两种常用模式：

- `"updates"`（默认）：只吐每个节点产生的**增量** `{节点名: 新状态片段}`，适合观察"这一步谁做了什么"；
- `"values"`：每步吐**完整 State 快照**，适合渲染聊天界面（不丢历史）；
- `"messages"`：token 级流式，适合打字机效果。

### 记忆原理：Checkpointer 与 thread_id

`builder.compile(checkpointer=MemorySaver())` 之后，**每执行完一个节点，完整 State 快照就写入 Checkpointer**。会话隔离靠 `config = {"configurable": {"thread_id": "user-001"}}`：不同 thread_id 各自维护一条消息线，互不可见。`SqliteSaver`（独立包 `langgraph-checkpoint-sqlite`）把快照落盘到 SQLite 文件，进程重启后还能续聊；`Store` 则用 `namespace` 组织跨会话的长期键值（如 `("profiles", user_id)` 下存偏好），实现"换个新对话还认识你"——短期记忆管上下文，长期记忆管画像。

### 人机交互：interrupt 断点

`interrupt()` 是 LangGraph 的"审批窗口"：执行到某节点时抛出中断、把控制权交给人（human-in-the-loop，人在回路）。静态断点用编译参数 `interrupt_before=["tools"]`（每次执行工具前都停）；动态断点用节点内的 `interrupt({"question": ...})` 按数据决定是否停。恢复时用 `Command(resume=answer)` 把人的决定注入图继续执行。典型场景：删除文件、发邮件、付款等高风险工具调用前的人工审批。**断点机制依赖 Checkpointer**——不挂 checkpointer 的中断现场无法保存。

### MCP 接入原理：load_mcp_tools

LangChain 接 MCP 的桥是 `langchain-mcp-adapters` 包。`load_mcp_tools(session)` 的原理：先按 MCP 协议建立 client ↔ MCP server 的连接（stdio 子进程 / SSE / Streamable HTTP 三种传输），用 `tools/list` 发现远端工具，再把每个 MCP 工具包装成 LangChain 的 `BaseTool`（把 JSON schema 转成 pydantic 参数、调用转发回 MCP 会话）。**对 LangGraph / LangChain 而言，MCP 工具与本地 `@tool` 函数毫无区别**——这是"工具来源透明"的关键。MCP 协议细节见 [[MCP协议开发实战]]。

### RAG 检索流程

检索增强生成（Retrieval-Augmented Generation，RAG）的管道：Loader 读文档 → Splitter 切块 → Embedding 向量化入库 → 用户问题向量化 → Retriever 按相似度召回 top-k → 拼进提示词 → LLM 生成带上下文的答案。四件套缺一不可，`chunk_size / chunk_overlap` 直接影响召回质量。深度调优见 [[RAG检索增强生成实战]]。

### Supervisor 编排原理（配图）

![[Multi-Agent-Supervisor.excalidraw]]

> [!note] 图解：Supervisor 循环（图文件由主会话稍后创建，此处直接嵌入）
> 上图展示 Supervisor 多代理的运行时循环，五个步骤：
> 1. **入队**：用户任务进入 Supervisor 节点，主管读取全局 State 与消息历史；
> 2. **分派**：主管用 `with_structured_output` 输出结构化决策——`next` 字段为某个 worker 的名字（如 `researcher`、`coder`）；
> 3. **执行**：条件边按 `next` 把控制权路由给该 worker，worker 独立执行并把结果写回共享 State；
> 4. **汇总**：控制权回到 Supervisor，主管判断任务是否完成——未完成则再次分派（可能换一个 worker），完成则输出 `FINISH`；
> 5. **结束**：`FINISH` 触发到 `END` 的边，主管汇总所有 worker 产出，生成最终答复。
> 关键点：**主管只做路由决策、不干具体活**，所有 worker 通过共享 State 协作——这正是 Magentic-One（Orchestrator 编排器 + Task Ledger 任务台账 + Progress Ledger 进度台账 + 专职 worker）思想的 LangGraph 落地。

### 多代理：从单代理缺陷到三类架构

单代理（One Big Agent）的缺陷：上下文爆炸（所有工具说明挤在一个窗口）、能力单一（一个模型难同时精通写码与运维）、工具冲突。多代理把任务拆给专职 Agent 协作：

- **Network（对等网络）**：Agent 两两直连、互相发消息，无中心节点；
- **Supervisor（主管编排）**：主管集中决策"下一步派谁"，见上图；
- **Hierarchical（层级）**：父图把子图当节点，子图内部还可以有自己的主管，形成树状团队。

**父子图消息传递**：子图通过 `builder.add_node("child", child_graph)` 挂进父图，父图把消息写入 State 后，子图按字段映射接收输入、执行完把结果写回共享键——父子之间不直接传参数，**一切通过 State 的共享字段接力**。

## 最小可运行 Demo

### Demo 1：LCEL 三行链（约 10 行）

```python
# demo1_lcel.py —— LCEL 三行链最小示例
# 前置: pip install langchain; 环境变量 DEEPSEEK_API_KEY=xxx
from langchain.chat_models import init_chat_model              # 统一接入大模型
from langchain_core.prompts import ChatPromptTemplate          # 提示词模板
from langchain_core.output_parsers import StrOutputParser      # 解析器

model = init_chat_model("deepseek-chat")    # 1. 模型: 按名称自动匹配厂商适配包
prompt = ChatPromptTemplate.from_messages([
    ("system", "你是{领域}领域的专家，用一句话回答。"),
    ("user", "{问题}"),
])                                           # 2. 提示词: 变量 {领域}/{问题}
parser = StrOutputParser()                   # 3. 解析器: AIMessage → 纯字符串

chain = prompt | model | parser             # ★ LCEL 管道: 一行完成组合
print(chain.invoke({"领域": "网络", "问题": "什么是 BGP 路由协议?"}))
# 输出示例: BGP 是自治系统之间的边界网关协议, 负责互联网骨干的路由交换。
```

> [!tip] "三行链"指链的三要素 prompt、model、parser 各一行，`|` 组合出的链自动支持 `invoke / ainvoke / stream / batch` 四种调用。

### Demo 2：LangGraph 两节点 ReAct 迷你图（约 50 行）

```python
# demo2_react_mini.py —— LangGraph 两节点 ReAct 迷你图 + MemorySaver 记忆
# 前置: pip install langchain langgraph; 环境变量 DEEPSEEK_API_KEY=xxx
from typing import Annotated, TypedDict
from langchain.chat_models import init_chat_model
from langchain_core.tools import tool
from langgraph.graph import StateGraph, START, END
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode, tools_condition
from langgraph.checkpoint.memory import MemorySaver


# 1. State: messages 用 add_messages Reducer(追加语义); next 由条件边写入
class State(TypedDict):
    messages: Annotated[list, add_messages]   # 消息列表, 追加 + 按 ID 去重
    next: str                                  # 下一个节点名(tools_condition 场景可省略)


# 2. 工具: docstring 即工具描述, 会被写入模型可见的 schema
@tool
def get_weather(city: str) -> str:
    """查询指定城市的实时天气。"""
    return f"{city}：晴，26°C"


llm = init_chat_model("deepseek-chat")
llm_with_tools = llm.bind_tools([get_weather])    # 把工具 schema 注入模型


# 3. agent 节点: 调 LLM, 返回消息增量(模型可能输出 tool_calls)
def agent(state: State) -> dict:
    return {"messages": [llm_with_tools.invoke(state["messages"])]}


# 4. 组装图: agent 节点 + tools 节点 + 条件边(有工具调用→tools, 否则→END)
builder = StateGraph(State)
builder.add_node("agent", agent)
builder.add_node("tools", ToolNode([get_weather]))        # ToolNode 负责执行工具
builder.add_edge(START, "agent")
builder.add_conditional_edges("agent", tools_condition)   # ★ 条件边: 决定是否循环
builder.add_edge("tools", "agent")                         # 工具结果回流 agent → 环
graph = builder.compile(checkpointer=MemorySaver())        # ★ checkpointer=短期记忆


# 5. 会话隔离: 同一 thread_id 续聊, 不同 thread_id 互不干扰
config = {"configurable": {"thread_id": "user-001"}}
for chunk in graph.stream({"messages": [("user", "北京天气怎么样?")]},
                          config, stream_mode="updates"):
    print(chunk)   # updates 模式: 逐节点打印增量, 可观察到 agent→tools→agent 的循环
# 第二轮: 同一 thread_id 续聊, 模型记得上一轮, 可直接追问
graph.invoke({"messages": [("user", "明天呢?")]}, config)
```

> [!note] 两节点如何实现 ReAct 循环
> `tools_condition` 检查最后一条 AIMessage 是否含 `tool_calls`：含 → 走 `tools` 节点执行工具 → 结果回流 `agent` 再思考；不含 → 走 `END` 输出最终答案。ReAct 的 Reason（agent）与 Act（tools）两个角色各占一个节点，环由条件边自动形成。

## 进阶实践与常见坑

### 智能问答系统案例（RAG 四件套串联）

```python
# qa_case.py —— 智能问答系统: 检索 + 生成
from langchain_community.document_loaders import TextLoader          # ① 加载
from langchain_text_splitters import RecursiveCharacterTextSplitter  # ② 切分
from langchain_openai import OpenAIEmbeddings                        # ③ 向量化
from langchain_community.vectorstores import FAISS                   # ④ 存储/检索(需 faiss-cpu)

docs = TextLoader("公司制度.txt").load()
chunks = RecursiveCharacterTextSplitter(
    chunk_size=500, chunk_overlap=50).split_documents(docs)
vs = FAISS.from_documents(chunks, OpenAIEmbeddings())
retriever = vs.as_retriever(k=4)              # 相似度 top-4 召回

from langchain.chat_models import init_chat_model
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnablePassthrough

rag_chain = (
    {"context": retriever, "question": RunnablePassthrough()}
    | ChatPromptTemplate.from_messages([
        ("system", "仅根据以下资料回答问题:\n{context}"),
        ("user", "{question}"),
    ])
    | init_chat_model("deepseek-chat")
    | StrOutputParser()
)
print(rag_chain.invoke("年假怎么休?"))   # 答案附带资料依据, 幻觉大幅下降
```

### Agent 构建：create_tool_calling_agent 与多工具并联串联

```python
# agent_tools.py —— 工具调用 Agent + 多工具协作
from langchain.agents import create_tool_calling_agent, AgentExecutor
from langchain_core.prompts import ChatPromptTemplate
from langchain.chat_models import init_chat_model
from langchain_core.tools import tool

@tool
def search_web(q: str) -> str:
    """在网络上搜索信息。"""
    return f"关于 {q} 的搜索结果: ...(省略实现)"

@tool
def calc(expr: str) -> str:
    """计算数学表达式并返回结果。"""
    return f"{expr} = {eval(expr)}"    # 演示用; 生产环境勿用 eval

llm = init_chat_model("deepseek-chat")
agent = create_tool_calling_agent(
    llm, [search_web, calc],
    ChatPromptTemplate.from_messages([
        ("system", "你是能调用工具的助手，逐步解决问题。"),
        ("human", "{input}"),
        ("placeholder", "{agent_scratchpad}"),   # 工具调用中间结果占位
    ]),
)
executor = AgentExecutor(agent=agent, tools=[search_web, calc], verbose=True)
print(executor.invoke({"input": "搜索最新的 LLM 论文数量并乘以 3"})["output"])
```

- **并联（并行）**：模型一次回复可同时发出多个 `tool_calls`（如同时调 `search_web` 和 `calc`），AgentExecutor / LangGraph 并发执行后一次性送回结果；
- **串联（顺序）**：工具结果返回后模型继续决策是否再调工具——"先搜索拿到数字、再计算"就是典型的串联链。

### LangChain 接 MCP 工具

```python
# mcp_bridge.py —— 把远端 MCP 工具变成 LangChain 工具
from langchain_mcp_adapters.client import MultiServerMCPClient
from langchain_mcp_adapters.tools import load_mcp_tools

async def main():
    # 连接一个 stdio 型 MCP server(命令行启动子进程)
    async with MultiServerMCPClient({
        "filesystem": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "."],
        },
    }) as client:
        tools = await load_mcp_tools(client.session)   # 发现远端工具并包装成 BaseTool
        llm = init_chat_model("deepseek-chat").bind_tools(tools)  # 与本地工具无差别使用
        print(llm.invoke("列出当前目录").tool_calls)
```

> [!warning] 版本坑
> `langchain-mcp-adapters` 早期版本直接暴露 `load_mcp_tools(session)`，新版推荐 `MultiServerMCPClient` 统一管理多 server 会话（API 以官方 README 为准）；MCP 工具均为 async，同步链里要用 `asyncio.run` 包一层。MCP Server 开发细节见 [[MCP协议开发实战]]。

### Supervisor 编排代码实践

```python
# supervisor.py —— Supervisor 编排核心骨架
from typing import Literal
from pydantic import BaseModel
from langgraph.graph import StateGraph, START, END

class Route(BaseModel):
    next: Literal["researcher", "coder", "FINISH"]   # 主管的结构化决策空间

def supervisor(state: State) -> dict:
    """主管节点: 只路由, 不干活。"""
    decision = llm.with_structured_output(Route).invoke(state["messages"])
    if decision.next == "FINISH":
        return {"next": END}          # 任务完成 → 结束
    return {"next": decision.next}    # 分派到指定 worker

builder = StateGraph(State)
builder.add_node("supervisor", supervisor)
builder.add_node("researcher", researcher)      # worker 1: 联网调研
builder.add_node("coder", coder)                # worker 2: 写代码
builder.add_edge(START, "supervisor")
builder.add_conditional_edges("supervisor", lambda s: s["next"])  # 按决策路由
builder.add_edge("researcher", "supervisor")    # worker 干完回到主管(汇总)
builder.add_edge("coder", "supervisor")
graph = builder.compile()
```

> [!tip] 要点
> Supervisor 的全部逻辑就是"结构化决策 + 条件边路由"：`Literal["researcher", "coder", "FINISH"]` 把主管的选择空间锁死在合法节点名上，防止模型幻觉出一个不存在的节点。worker 完成后的边全部指回 supervisor，构成"分派-执行-汇总"循环。

### 混合知识库案例：向量库 + Neo4j GraphRAG 双检索

单一向量检索只能答"语义相似"，答不了"多跳关系"（如"张三是谁的下属的下属"）。双检索方案：**向量库**负责语义召回段落，**Neo4j GraphRAG**负责实体-关系多跳查询，两路结果融合重排后交给 LLM 汇总：

| 检索路 | 召回能力 | 擅长问题 |
|--------|----------|----------|
| 向量库（FAISS 等） | 语义相似段落 | "总结一下 XX 制度" |
| Neo4j GraphRAG | 实体-关系多跳遍历 | "XX 的上级部门是谁" |
| 融合重排 | 双路去重 + RRF（Reciprocal Rank Fusion，倒数排名融合） | 混合型问题 |

### 混合知识库的第三选择：Microsoft GraphRAG

"GraphRAG"存在两个同名阵营：**Neo4j GraphRAG**（`neo4j-graphrag` 包，用 Cypher 在属性图上做多跳查询，轻量即插即用）与 **Microsoft GraphRAG**（独立框架，先离线建图与社区摘要，再回答问题）。微软方案的 CLI 三命令（已按官方 CLI 文档核实）：

```bash
graphrag init                                # 初始化工作区(生成 settings.yaml / .env)
graphrag index                               # 离线建索引: 实体/关系抽取 → 社区检测 → 生成社区摘要
graphrag query --method global "全文宏观问题"  # global: 基于社区摘要做地图式全局问答
graphrag query --method local "实体细节问题"   # local: 基于局部实体-关系子图做钻取式问答
```

local 与 global 检索流程：**local search（局部检索）**先定位相关实体，再沿关系遍历其邻居实体与关联文本生成上下文，适合"某个实体怎么样"的钻取问题；**global search（全局检索）**不查具体实体，而是把全部社区摘要分片交给 map-reduce 式 LLM 汇总，适合"这个语料整体讲了什么"的地图式问题。两者流程与参数已按官方 CLI 文档与分步解析文章交叉核实。

### RAG 质量评测：Ragas

Ragas 是 RAG 专用评测框架，用 LLM-as-a-judge（LLM 当裁判）给检索与生成打分（指标语义已按官方文档核实）：

```python
# ragas_eval.py —— 用测试集评估 RAG 管道
from ragas import evaluate
from ragas.metrics import (faithfulness, answer_relevancy,
                           context_precision, context_recall)
from datasets import Dataset

# 测试集四列: question / answer / contexts / ground_truth
ds = Dataset.from_list([{
    "question": "年假怎么休?", "answer": "...",
    "contexts": ["...召回段落..."], "ground_truth": "..."}])
score = evaluate(ds, metrics=[faithfulness, answer_relevancy,
                              context_precision, context_recall])
print(score)   # 输出四项分数
```

四个核心指标：`faithfulness`（忠实度：答案与召回上下文是否一致，防幻觉）、`answer_relevancy`（答案相关性）、`context_precision`（上下文精度：召回的段落是否都有用）、`context_recall`（上下文召回：ground truth 是否被召回）。

### 常见坑清单

> [!bug] 高频坑（按踩中频率排序）
> 1. **忘传 thread_id**：checkpointer 模式下两次 `invoke` 不带 `thread_id`，每次都是全新会话，多轮记忆"失灵"；
> 2. **Reducer 语义搞反**：想追加的字段没写 `Annotated[list, operator.add]`，被默默覆盖；
> 3. **SqliteSaver 导入报错**：它已拆到 `langgraph-checkpoint-sqlite` 包，导入路径是 `langgraph.checkpoint.sqlite`，不是 memory；
> 4. **stream_mode 混用**：拿 `"updates"` 的输出当完整消息列表渲染 UI，界面丢历史——渲染界面要用 `"values"`；
> 5. **interrupt() 不生效**：人机交互断点必须编译时挂 checkpointer，否则中断现场无处保存；
> 6. **结构化输出不校验**：`with_structured_output` 换模型后 schema 可能失败，生产建议加重试与 fallback；
> 7. **版本漂移**：LangChain 与 LangGraph 均已发布 1.0 正式版（2025-10，官方博客可查）；1.0 新增 `create_agent` 入口，`init_chat_model` / `bind_tools` / `tools_condition` 的导入位置在 0.2 → 0.3 → 1.0 之间多次变动，抄旧博客代码前先 `pip show langchain langgraph` 核对版本。

### 生产化建议

> [!success] 上生产三件套
> - **可观测**：接入 LangSmith（`LANGCHAIN_TRACING_V2=true`）追踪每次调用链与 token 消耗；
> - **降级**：`with_fallbacks([主模型, 备用模型])` + `with_retry` 防单点故障；
> - **治理**：多代理系统把 Supervisor 的每次分派决策写进日志/Store，便于审计"为什么派了 A 而不是 B"。

## 相关文档

- [[AI大模型开发]] — 大模型原理与推理基础（本框架的上游知识）
- [[AI-Dev-KB-Home]] — AI 开发知识库首页 MOC
- [[LLM-Agent开发基础]] — Agent 概念、ReAct/工具调用范式入门
- [[MCP协议开发实战]] — MCP 工具协议细节与 Server 开发（本文 `load_mcp_tools` 的底层）
- [[RAG检索增强生成实战]] — RAG 四件套的深度拆解与调优
- [[A2A多智能体协作协议]] — Agent 之间的任务委托协议（LangGraph 多代理的跨框架延伸）

## 参考资料

- LangChain 官方文档 · Interrupts 人机交互指南：<https://docs.langchain.com/oss/python/langgraph/interrupts>
- LangGraph API 参考 · interrupt 函数：<https://reference.langchain.com/python/langgraph/types/interrupt>；Checkpoints 持久化：<https://reference.langchain.com/python/langgraph/checkpoints>
- LangChain & LangGraph 1.0 官方发布博客（2025-10，版本事实核实来源）：<https://www.langchain.com/blog/langchain-langgraph-1dot0>
- langchain-mcp-adapters 官方 README（MultiServerMCPClient / load_mcp_tools 用法）：<https://github.com/langchain-ai/langchain-mcp-adapters/blob/main/README.md>；API 参考：<https://reference.langchain.com/python/langchain-mcp-adapters>
- Microsoft GraphRAG CLI 接口文档：<https://deepwiki.com/microsoft/graphrag/8-cli-interface>；工作原理分步解析（local/global 检索）：<https://tech.bertelsmann.com/en/blog/articles/how-microsoft-graphrag-works-step-by-step-part-12>
- LangChain 向量存储检索器 How-to（FAISS from_documents / as_retriever）：<https://python.langchain.ac.cn/docs/how_to/vectorstore_retriever/>
- Ragas 评测入门（faithfulness / answer_relevancy / context_precision / context_recall）：<https://docs.ragas.io/en/v0.1.21/getstarted/evaluation.html>
- Magentic-One 的 Autogen 实现源码文档（Task Ledger / Progress Ledger）：<https://microsoft.github.io/autogen/0.4.3/_modules/autogen_agentchat/teams/_group_chat/_magentic_one/_magentic_one_group_chat.html>
