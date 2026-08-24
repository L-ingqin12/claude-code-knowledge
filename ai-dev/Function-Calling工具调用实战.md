---
title: Function-Calling工具调用实战
aliases: [函数调用实战, Function Calling实战, FC工具调用]
tags: [ai, ai/learning]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# Function-Calling工具调用实战

本文是函数调用（Function Calling，简称 FC）的实战手册：让大模型不再只输出文字，而是输出结构化的 tool_calls JSON，由客户端执行真实函数后回传结果，再经第二次模型调用生成最终答案。

> [!abstract] 定位与目标
> 本文服务《第 3 章 FC 部分 + 第 7 章进阶 + 第 28 章》课程骨架：Function Calling 运行流程（两次模型调用）、messages 中 `assistant.tool_calls` 与 `role:"tool"` 的配对、从 Python 函数签名 + docstring 自动生成 JSON Schema、自动完成两次调用的封装、四大挑战与解法（意图识别 / 返回不精准 / 海量函数 / 并行与串行）、响应太慢的优化（流式 + 并行 + 精简 Schema）。读完可获得一个约 80 行、离线可跑的双轮 Function Calling 完整实现。

## 核心概念

### 术语表

| 术语 | 中文含义 | 一句话解释 |
|------|----------|-----------|
| Function Calling | 函数调用 | 模型输出"我想调用哪个函数、参数是什么"的结构化意图，而非直接答案 |
| tool_calls | 工具调用列表 | assistant 消息中的字段，数组元素含 `id` 与 `function.name/arguments` |
| tool_call_id | 工具调用 ID | 关联 `assistant.tool_calls` 与 `role:"tool"` 结果的唯一配对键 |
| role:"tool" | 工具结果消息 | 客户端把函数执行结果以该角色回填给模型的消息类型 |
| finish_reason | 结束原因 | `"tool_calls"`=要求调用工具；`"stop"`=正常结束 |
| JSON Schema | JSON 模式 | 对函数参数的声明（类型/枚举/描述/必填），模型据此填参数 |
| tool_choice | 工具选择策略 | `auto`（默认）/`required`（必须调用）/`none`（禁止调用） |
| parallel_tool_calls | 并行工具调用 | 一次返回多个无依赖工具调用，客户端可并发执行 |
| Executor | 执行器 | 客户端侧真实执行函数的组件，模型永远不亲自执行代码 |
| 两次模型调用 | Two-pass | 第一轮产出 tool_calls，第二轮消化工具结果产出 Final Answer |

### 运行流程总览（六步，两次模型调用）

| 步骤 | 动作 | 说明 |
|------|------|------|
| 1 | User 提问 | "北京今天天气怎么样？" |
| 2 | 模型第 ① 次调用 | 模型决定调用 `get_weather`，返回 tool_calls JSON（此时没有文字答案） |
| 3 | 客户端执行 | Executor 解析 tool_calls → 真实调用 `get_weather("北京")` |
| 4 | 结果回传 | 执行结果以 `role:"tool"` 消息追加，`tool_call_id` 配对 |
| 5 | 模型第 ② 次调用 | 带工具结果再次请求模型 |
| 6 | Final Answer | 模型基于工具结果生成最终自然语言答案 |

## 原理剖析

### 时序泳道图解说

![[Function-Calling-Sequence.excalidraw]]

> [!note] 图由主会话稍后创建，直接嵌入
> 上图为 Function Calling 时序泳道图（Excalidraw 手绘图）：泳道依次为 User → LLM → tool_calls → Executor → role:tool 结果 → LLM → Final Answer，重点标出两次模型调用。嵌入路径为 `![[Function-Calling-Sequence.excalidraw]]`，图创建完成后本文档无需再改。

对照泳道图逐段解读：

1. **User → LLM（第 ① 次调用）**：模型收到的不是"帮我查天气"的任务描述，而是"你可以用 get_weather 这个工具"的 tools 列表 + 用户问题。模型输出的不是答案，而是"我想调用 get_weather，参数 city=北京"的 tool_calls JSON；
2. **tool_calls → Executor**：客户端解析 JSON，执行真实函数。这一步发生在客户端代码里，模型全程不执行任何代码，也不接触真实数据；
3. **Executor → role:tool 结果**：函数返回值（建议 JSON 字符串）以 `role:"tool"` 消息回填，并通过 `tool_call_id` 与上一步的 tool_calls 严格配对；
4. **LLM → Final Answer（第 ② 次调用）**：模型带着工具结果再次推理，把结构化数据翻译成自然语言，如"北京今天 28 度，晴"。

> [!warning] 为什么必须是两次调用
> 模型是无状态的，且不运行代码：第一轮输出只是"动作意图"，工具执行结果是全新的输入，必须再走一次前向计算才能变成答案。任何"一步到位"的想法都会导致模型对着没执行过的结果编造答案（幻觉）。

### 消息流配对（messages 里的关键结构）

| 序号 | role | content | 关键字段 |
|------|------|---------|----------|
| 1 | user | 北京今天天气怎么样？ | — |
| 2 | assistant | null | `tool_calls=[{id:"call_1", function:{name:"get_weather", arguments:'{"city":"北京"}'}}]` |
| 3 | tool | `{"city":"北京","temp":28,"desc":"晴"}` | `tool_call_id:"call_1"` ← 必须与第 2 步的 id 一致 |
| 4 | assistant | 北京今天 28 度，晴。 | `finish_reason:"stop"` |

配对规则（违反即 API 报 400 或结果错乱）：

- `assistant.tool_calls` 与 `role:"tool"` 消息**必须成对出现**，且逐条按 `tool_call_id` 对应；
- 每条 `role:"tool"` 消息必须**紧跟**它对应的 assistant 消息之后（第二轮请求前）；
- 多个工具并行调用时：一条 assistant 消息带 N 个 tool_calls，后跟 N 条 tool 消息，顺序与 tool_calls 列表一致；
- 第二轮请求必须携带完整的 messages 历史（user → assistant(tool_calls) → tool），模型才能"回忆起"自己要了什么。

## 最小可运行 Demo

完整双轮 Function Calling 实现（约 80 行）：`get_weather` 本地假实现 → 手写 tools schema + `inspect` 自动生成对照 → while 循环处理 `finish_reason=="tool_calls"` 并支持一次多工具并行调用。未配置 `OPENAI_API_KEY` 时走 Mock 客户端，离线可跑完整流程：

```python
# -*- coding: utf-8 -*-
"""最小可运行 Function Calling Demo：双轮调用 + 一次多工具并行执行。
运行: python fc_demo.py
未配置 OPENAI_API_KEY 时使用内置 Mock 客户端（离线可跑完整双轮流程）。
"""

import inspect
import json
import os

# ① 本地工具实现（假数据源；真实场景替换为天气 API / 数据库查询）
def get_weather(city: str, unit: str = "celsius") -> str:
    """查询指定城市的实时天气。city 参数：城市名（中文或英文，如 '北京'）。unit 参数：温度单位，celsius 或 fahrenheit。"""
    fake_db = {"北京": (28, "晴"), "上海": (31, "多云"), "广州": (33, "雷阵雨")}
    temp, desc = fake_db.get(city, (25, "未知"))
    if unit == "fahrenheit":
        temp = round(temp * 9 / 5 + 32, 1)
    return json.dumps({"city": city, "temp": temp, "unit": unit, "desc": desc}, ensure_ascii=False)

# ② 手写 tools schema（对照用）：description / 枚举 / 单位都要写清楚
HANDWRITTEN_TOOLS = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "查询指定城市的实时天气",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "城市名，如 北京 / Beijing"},
                "unit": {"type": "string", "enum": ["celsius", "fahrenheit"],
                         "description": "温度单位，默认 celsius"},
            },
            "required": ["city"],
        },
    },
}]

# ③ 自动生成 schema：从函数签名 + docstring 提取（参数名/默认值/必填）
def auto_schema(func):
    """由 Python 函数自动生成 OpenAI tools JSON Schema。"""
    doc = (func.__doc__ or "").strip()
    params = inspect.signature(func).parameters
    properties, required = {}, []
    for name, p in params.items():
        if p.default is inspect.Parameter.empty:
            required.append(name)               # 无默认值 → 必填参数
        properties[name] = {"type": "string", "description": f"参数 {name}，函数说明：{doc}"}
    return [{"type": "function", "function": {
        "name": func.__name__,
        "description": doc.split("。")[0] if doc else func.__name__,   # 取 docstring 首句作函数说明
        "parameters": {"type": "object", "properties": properties, "required": required},
    }}]

# ④ Mock 客户端：模拟两次 OpenAI 调用（第一轮 tool_calls，第二轮最终答案）
MOCK_STATE = {"asked": False}

def mock_call(messages, tools):
    if messages[-1]["role"] == "user" and not MOCK_STATE["asked"]:
        MOCK_STATE["asked"] = True
        return {"content": None, "finish_reason": "tool_calls",
                "tool_calls": [{"id": "call_1", "type": "function",
                                "function": {"name": "get_weather",
                                             "arguments": '{"city": "北京", "unit": "celsius"}'}}]}
    return {"content": "北京今天 28 摄氏度，晴。", "tool_calls": None, "finish_reason": "stop"}

def call_model(messages, tools):
    """模型调用封装：统一返回 {content, tool_calls, finish_reason} 字典。"""
    api_key = [已脱敏]("OPENAI_API_KEY")
    if not api_key:
        [已脱敏] mock_call(messages, tools)
    from openai import OpenAI                  # pip install openai
    resp = OpenAI(api_key=[已脱敏]).chat.completions.create(
        model="gpt-4o-mini", messages=messages, tools=tools,
        parallel_tool_calls=True,               # 允许一次返回多个工具调用
    )
    msg = resp.choices[0].message
    # SDK v1 的 tool_calls 元素为 Pydantic 对象：pydantic v2 用 model_dump()，v1 环境改用 tc.dict()
    return {"content": msg.content, "finish_reason": resp.choices[0].finish_reason,
            "tool_calls": [tc.model_dump() for tc in msg.tool_calls] if msg.tool_calls else None}

TOOL_REGISTRY = {"get_weather": get_weather}   # 工具注册表：schema 名 → 真实函数

# ⑤ 主循环：处理 finish_reason=="tool_calls"，支持一次多工具并行调用
def run_agent(question: str, tools: list, max_rounds: int = 5) -> str:
    """完整双轮（或多轮）Function Calling 主流程。"""
    messages = [{"role": "user", "content": question}]
    for _ in range(max_rounds):
        r = call_model(messages, tools)
        if r["finish_reason"] != "tool_calls":
            return r["content"]                  # 模型给出最终答案，结束
        # assistant 消息要原样回填 tool_calls，与后面的 role:"tool" 消息配对
        messages.append({"role": "assistant", "content": r["content"], "tool_calls": r["tool_calls"]})
        for tc in r["tool_calls"]:               # 无依赖的工具在此并行执行
            args = json.loads(tc["function"]["arguments"])
            result = TOOL_REGISTRY[tc["function"]["name"]](**args)
            messages.append({"role": "tool", "tool_call_id": tc["id"], "content": result})
    raise RuntimeError("超过最大轮数仍未收敛，检查工具返回是否被模型反复误用")

if __name__ == "__main__":
    print("手写 schema  :", json.dumps(HANDWRITTEN_TOOLS, ensure_ascii=False))
    print("自动 schema  :", json.dumps(auto_schema(get_weather), ensure_ascii=False))
    print("最终答案     :", run_agent("北京今天天气怎么样？", auto_schema(get_weather)))
```

> [!tip] 运行说明
> ① 直接 `python fc_demo.py` 走 Mock 双轮流程；② 设置 `OPENAI_API_KEY` 后自动切换真实接口（需 `pip install openai`）；③ 手写 schema 与 `auto_schema` 的对照打印，直观展示"自动生成省事、但 description 质量需要人工补强"。

## 进阶实践与常见坑

### 四大挑战与解法

| 挑战 | 问题表现 | 解法 |
|------|----------|------|
| ① 意图识别问题 | 该调函数时不调，或不该调时乱调（把闲聊也当工具请求） | 提高 JSON Schema 质量：参数 description 写清单位/枚举/示例；用 `tool_choice` 收紧策略 |
| ② 返回无法精准作答 | 工具返回原始数据，模型直接复述或答非所问 | 两阶段调用优化：先取数据，再让模型精读数据后作答 |
| ③ 海量函数问题 | 几十个工具塞爆上下文，且模型选错率随数量上升 | 分层设计：按域分组的两级路由，先选类别再选具体函数 |
| ④ 并行 vs 串行 | 全部串行则时延叠加，乱并行则拿到过期/空结果 | 无依赖并行省时延；有依赖必须串行，等前序结果再发下一轮 |

**① 意图识别 → Schema 质量**：模型判断"该不该调用、参数填什么"的唯一依据是 Schema 文本。参数 `description` 必须写清**单位**（"摄氏度还是华氏度"）、**枚举**（合法取值集合）、**示例**（"如 北京"），并显式声明 `required`。必要时加一条系统消息："只有在需要实时数据时才调用工具，闲聊直接回答。"

**② 两阶段调用**：第一轮只让工具"把数据取回来"；第二轮让模型"精读数据回答问题"——把"检索"与"生成"分开，模型就不会对着长数据发呆。骨架如下：

```python
# 两阶段调用骨架：阶段一取数据，阶段二精读作答
raw = run_agent("调用工具获取北京近三天天气", tools)          # 阶段一：只取数据
answer = call_model(
    [{"role": "user",
      "content": f"以下是原始数据：\n{raw}\n\n请总结北京近三天天气趋势。"}],
    tools=None,                                            # 阶段二：不再带工具，省 Token
)["content"]
```

> [!tip] 何时值得拆两阶段
> 当工具返回的数据量超过几百 Token、或需要跨多条数据做对比/统计时，拆两阶段收益最大；数据只有一行时单轮即可。

**③ 分层路由（两级）**：第一级用一个"路由器函数"（`route_tool(domain)`），由模型先选出领域类别（天气/股票/地图…），第二级再暴露该领域的具体工具。每轮请求只携带"类别路由 + 当前域工具"的小 Schema 集合，上下文省一大截，选错率随之下降。此思路在 [[LLM-Agent开发基础]] 中会扩展为完整的工具调度。

**④ 并行 vs 串行的判断标准**：只要工具 B 的参数不依赖工具 A 的结果，就放同一轮并行（`parallel_tool_calls=True`）；存在依赖时，第一轮先取 A，把 A 的结果回填后再发起包含 B 的第二轮。

### 响应太慢问题的三板斧

| 手段 | 收益 | 注意点 |
|------|------|--------|
| 流式输出（Streaming） | 首 Token 时延大幅下降，用户可感知进度 | 流式场景下 tool_calls 到达前无法执行，需先缓冲 |
| 并行工具调用 | N 个独立工具时延从 N×T 压到约 1×T | 仅限无依赖工具，见挑战④ |
| 精简 Schema | 减少 Prompt 体积，缩短预填充时间 | description 精简但保留单位/枚举，别砍关键约束 |

### 自动化封装进阶

- **`auto_schema` 的局限与补强**：自动生成的 description 是机械拼接，缺单位/枚举/示例——正是挑战①的病灶。改良方向：约定 docstring 的固定格式（首句=函数说明，后续行=参数说明），让 `auto_schema` 按约定解析，生成质量逼近手写；
- **通用 `run_agent` 扩展**：加 `max_rounds` 防死循环、加超时重试（网络抖动时按 `tool_call_id` 幂等重发）、加结果校验（Executor 返回非 JSON 时包装成合法 JSON 再回填）；
- **与 MCP 的关系**：FC 是"单应用内"的工具协议，MCP（Model Context Protocol）把工具的定义与执行抽到外部服务，本 Demo 的 `TOOL_REGISTRY` 可以被 MCP 客户端替换，见 [[MCP协议开发实战]]。

### 常见坑清单

| 坑 | 现象 | 对策 |
|----|------|------|
| tool_call_id 不配对 | API 报 400 / 模型"失忆"答非所问 | 严格执行消息流配对表，逐条核对 id |
| 无限循环 | 模型反复调用同一工具不收敛 | 设置 max_rounds 上限，超限抛错转人工 |
| 参数幻觉 | 模型编造不存在的城市名/枚举值 | Schema 写全枚举 + 示例；Executor 侧校验参数 |
| 返回值未格式化 | 工具返回复杂对象，模型解读混乱 | 返回值统一 JSON 字符串，字段名语义化 |
| 温度过高 | 参数 JSON 偶发畸形 | 工具调用场景 temperature 设 0-0.2 |
| 并行误用 | 有依赖的工具被并行执行，拿到空结果 | 依赖分析后再决定并行还是串行 |
| 单轮幻想 | 期望一次调用就出答案 | 理解两次模型调用机制，见 [[#时序泳道图解说]] |

## 相关文档

- [[AI大模型开发]] — 本知识库 LLM 开发总笔记，FC 的底层是模型的结构化输出能力，可交叉阅读；
- [[AI-Dev-KB-Home]] — AI 开发子 Vault 的首页 MOC，本文所在章节的导航入口；
- [[Prompt-Engineering入门与Demo]] — 提示词工程是 FC 的前提：好的 Schema 描述就是好的参数级 Prompt；
- [[LLM-Agent开发基础]] — FC 是 Agent 的工具使用基础，分层路由在此扩展为完整工具调度；
- [[MCP协议开发实战]] — 把本 Demo 的本地工具注册表替换为跨应用工具协议 MCP；
- [[参考-Ark-Agent-Plan计费与配置]] — Ark Agent Plan 的计费与配置参考，FC 多轮调用成本核算的依据。

## 参考资料

> [!info] 本文关键技术事实经 web_search 交叉核实，以下为实际参考的公开资料（访问日期 2026-08-25）。

1. [OpenAI Function calling 官方指南](https://platform.openai.com/docs/guides/function-calling) — "模型调用 → 执行工具 → 回传结果"流程与并行函数调用的官方说明；
2. [openai/openai-openapi: openapi.yaml](https://github.com/openai/openai-openapi/blob/423e672461b3d17f9829711e4a858e777252f077/openapi.yaml) — `parallel_tool_calls`（布尔参数，默认 true）与 `tool_calls` 字段结构的权威定义；
3. [openai/openai-python SDK 仓库](https://github.com/openai/openai-python) — `chat.completions.create(tools=...)` 调用签名与 `ChatCompletionMessageToolCall`（Pydantic 模型）的用法；
4. [Azure OpenAI REST API reference（messages 消息结构）](https://learn.microsoft.com/en-us/azure/ai-services/openai/reference) — `assistant.tool_calls` 与 `role:"tool"` 消息的字段级定义；
5. [Portkey Error Library: tool_call_id 配对错误](https://portkey.ai/error-library/tool-call-response-error-6610000) — "assistant 的 tool_calls 之后必须跟随逐条对应的 tool 消息"的报错案例与修复方式；
6. [OpenAI API Reference: chat/completions](https://platform.openai.com/docs/api-reference/chat/create) — `parallel_tool_calls` 与 `temperature`（默认 1，低值更确定性）的官方参数定义；
7. [OpenAI Help Center: Function calling in the Chat Playground](https://help.openai.com/en/articles/9492280-function-calling-in-the-chat-playground) — 函数调用双轮交互过程的可视化演示。
