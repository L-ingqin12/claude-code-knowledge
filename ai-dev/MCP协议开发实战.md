---
title: MCP协议开发实战
aliases: [MCP开发, ModelContextProtocol实战, MCP Server构建]
tags: [ai, ai/agent]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# MCP协议开发实战

一句话定位：本文从 Function Call 的三大缺陷出发，讲透 MCP（Model Context Protocol，模型上下文协议）"AI 界 USB-C"的本质，并手把手完成 FastMCP Server、Python Client、调试发布与三平台接入的全链路实战。

> [!abstract] 覆盖课程第 10、11 章：Agent 视角的 MCP 原理剖析、Function Call 缺陷分析（M×N 集成爆炸 / 厂商绑定 / 无生态复用）、MCP 环境构建（uv / python sdk）、Client/Server 双端开发、stdio / SSE / Streamable HTTP 三种传输、MCP Inspector 调试、打包发布与离线部署，以及 Cherry Studio / 阿里百炼 / Dify 三平台接入自研 MCP Server。

## 核心概念

### Function Call 的三大缺陷

| 缺陷 | 说明 | 后果 |
|------|------|------|
| M×N 集成爆炸 | 每个模型厂商 × 每个工具都要写一套适配层 | 集成成本随工具数量线性爆炸 |
| 厂商绑定 | 工具调用协议（schema、调用格式）随厂商私有 | 换模型等于重写工具层 |
| 无生态复用 | 工具实现无法跨应用共享 | 各项目重复造轮子 |

> [!note] Function Call（函数调用）本质是"厂商私有协议"：OpenAI、Anthropic、DeepSeek 各有各的 tools 参数格式与返回结构，工具开发者被迫为每个厂商写适配。

### MCP 与 Function Call 对比

| 维度 | Function Call | MCP |
|------|---------------|-----|
| 协议归属 | 厂商私有 | 开放标准（JSON-RPC 2.0） |
| 复用性 | 每个应用重写 | 一次开发处处接入 |
| 能力范围 | 仅"工具调用" | 工具（Tools）+ 资源（Resources）+ 提示词（Prompts） |
| 宿主关系 | 直接调厂商 API | Host 内嵌 Client，模型可插拔 |
| 生态 | 无公共工具市场 | 官方/社区 Server 生态繁荣 |

### MCP 的本质：AI 界的 USB-C

| 类比 | USB-C | MCP |
|------|-------|-----|
| 主机角色 | 电脑 | Host App（Claude Desktop / Cherry Studio / IDE） |
| 设备角色 | 外设（鼠标/硬盘/显示器） | MCP Server（文件/天气/数据库工具） |
| 接口 | 统一物理接口 + 协议 | 统一 JSON-RPC 协议 + 三种传输 |
| 效果 | 外设即插即用 | 工具即插即用，一次开发处处接入 |

> [!tip] 一句话：MCP 把"模型调工具"从**每对关系单独定制**变成**统一协议生态**——Server 开发一次，任何支持 MCP 的 Host 都能用，厂商与工具解耦。

### 核心名词

| 名词 | 说明 |
|------|------|
| Host App（宿主应用） | 承载对话的客户端，内嵌一个或多个 MCP Client |
| MCP Client | 与 Server 建立 1:1 连接、负责协议通信 |
| MCP Server | 暴露 Tools（工具）/ Resources（资源）/ Prompts（提示词） |
| Tools | 模型可调用的能力，Server 的核心资产 |
| Transport（传输） | stdio / SSE / Streamable HTTP 三种通信方式 |

### 三种传输对比

| 传输 | 连接模型 | 特点 | 适用场景 |
|------|----------|------|----------|
| stdio | 子进程标准输入输出 | 本地、零网络、最简单 | 本地 CLI Host |
| SSE | HTTP + Server-Sent Events 长连接推送，另一端点收消息 | 远程、单向推送 | 历史方案，正在被替代 |
| Streamable HTTP | 单一 HTTP 端点双向流 | 现代推荐，取代旧 HTTP+SSE 双端点 | 远程生产部署 |

## 原理剖析

![[MCP-Architecture.excalidraw]]

上图（MCP-Architecture）展示 MCP 整体架构：左侧 Host App 内可同时内嵌多个 MCP Client，每个 Client 与一个 MCP Server 保持独立连接；Server 按传输方式分 stdio（本地子进程）、SSE（HTTP 长连接推送）、Streamable HTTP（单一端点双向流）三类；右侧各 Server 对接本地文件、数据库或远程 API 等真实资源。模型本身不直接连 Server，而是由 Host 把工具定义注入对话上下文，模型"点名"后由 Client 转发调用。

三个理解要点：

1. **Client-Server 是 1:1**：一个 Client 只连一个 Server；Host 想用 N 个 Server 就开 N 个 Client，互不干扰、故障隔离。
2. **JSON-RPC 2.0 是协议骨架**：`initialize` → `tools/list` → `tools/call` → `notifications`，全部走 JSON-RPC 消息，传输层只是"邮路"，协议与传输解耦。
3. **模型不感知协议**：模型看到的只是工具名 + JSON Schema 描述，协议细节由 Host/Client 完全屏蔽——这正是与 Function Call 的差异所在：统一发生在生态层面，而非厂商私有。

> [!info] Server 三资产：Tools（模型可调用）、Resources（模型可读的数据）、Prompts（可复用的提示模板）。当前生态最成熟的是 Tools，其余两类按需扩展。

报文示例（JSON-RPC 2.0）：

```json
// Client → Server：列出工具
{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}

// Client → Server：调用工具
{"jsonrpc": "2.0", "id": 2, "method": "tools/call",
 "params": {"name": "get_weather", "arguments": {"city": "北京"}}}

// Server → Client：返回结果
{"jsonrpc": "2.0", "id": 2,
 "result": {"content": [{"type": "text", "text": "北京 今天晴，26°C"}]}}
```

### MCP Server 推荐（官方与热门）

| Server | 能力 | 接入方式 |
|--------|------|----------|
| filesystem | 读写指定目录文件 | npx / uvx 直跑 |
| fetch | 网页抓取与搜索 | 远程或本地 |
| github | Issue/PR/仓库操作 | 官方托管 |
| playwright / puppeteer | 浏览器自动化 | 本地 |
| 数据库类（Postgres 等） | 结构化查询 | 本地/远程 |

## 最小可运行 Demo

### 环境构建

```bash
# 推荐 uv（Python 包管理器，替代 pip + venv 组合）
uv venv && uv pip install mcp fastmcp openai
# 或传统方式
python -m venv .venv && pip install mcp fastmcp openai
```

> [!tip] 依赖说明：`mcp` 是官方 Python SDK（写 Client 用），`fastmcp` 是官方高层封装（写 Server 用），`openai` 用于 Client 接入大模型。

### Demo ①：FastMCP 编写天气/计算器 Server（约 20 行）

```python
# server.py —— 一个同时提供天气与计算器的 MCP Server
from fastmcp import FastMCP

mcp = FastMCP("demo-server")   # 创建 Server，名字会显示在 Host 的工具列表里

@mcp.tool()                    # @mcp.tool() 装饰器：声明一个模型可调用的工具
def get_weather(city: str) -> str:
    """查询指定城市的天气。参数 city: 城市中文名，如 北京。"""
    # 演示用假数据，真实场景替换为天气 API 调用
    return f"{city} 今天晴，26°C，适合出行"

@mcp.tool()
def calculate(expression: str) -> str:
    """计算数学表达式。参数 expression: 算式字符串，如 12*34+56。"""
    # 演示用 eval；生产环境需用 ast 白名单校验，避免代码注入
    return f"结果：{eval(expression)}"

if __name__ == "__main__":
    mcp.run(transport="stdio")  # 本地以 stdio 方式运行：读标准输入、写标准输出
```

**关键点**：docstring 是工具的"说明书"，会被转成 JSON Schema 注入模型上下文——**写清楚每个参数的含义与示例，比函数名更重要**。

### Demo ②：Python MCP Client 连接并调用工具

```python
# client.py —— 连接上述 Server，列出并调用工具
import asyncio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    # stdio 参数：指向 server.py，由 SDK 拉起子进程
    params = StdioServerParameters(command="python", args=["server.py"])
    async with stdio_client(params) as (read, write):      # 建立 stdio 通道
        async with ClientSession(read, write) as session:  # 初始化 MCP 会话
            await session.initialize()                     # 握手：协商协议版本

            tools = await session.list_tools()             # 列出 Server 暴露的工具
            print("可用工具：", [t.name for t in tools.tools])

            # 调用天气工具，返回 CallToolResult
            r1 = await session.call_tool("get_weather", {"city": "北京"})
            print("天气结果：", r1.content[0].text)

            r2 = await session.call_tool("calculate", {"expression": "12*34+56"})
            print("计算结果：", r2.content[0].text)

asyncio.run(main())
```

> [!success] 验证路径：直接 `python client.py` 即可——stdio_client 会自动拉起 server.py 子进程，无需手动先启动 Server。

### Client 接入大模型（五步）

| 步骤 | 做法 |
|------|------|
| 1. 取工具 schema | `session.list_tools()` 得到名称 + 描述 + 参数 JSON Schema |
| 2. 注入上下文 | 把 schema 塞进 system prompt 或 Function Calling 的 tools 参数 |
| 3. 模型点名 | 模型输出工具名与参数 JSON |
| 4. 转发执行 | `session.call_tool(name, args)`，结果拼回对话 |
| 5. 循环 | 与 [[LLM-Agent开发基础]] 的 ReAct 循环完全同构 |

工具注入大模型的骨架代码（DeepSeek 示例）：

```python
# 片段：把 MCP 工具转成 DeepSeek Function Calling 的 tools 参数
# （接上例 client 的 async 上下文，此处封装为函数便于复用）
def to_function_tools(tools):
    return [
        {"type": "function", "function": {
            "name": t.name, "description": t.description,
            "parameters": t.inputSchema}}
        for t in tools
    ]

async def build_tools(session):
    return to_function_tools((await session.list_tools()).tools)

# 在 async 函数内：tools_schema = await build_tools(session)
resp = client.chat.completions.create(
    model="deepseek-chat", messages=messages, tools=tools_schema)
# 模型返回 tool_calls 后，再经 session.call_tool 转发执行并拼回结果
```

## 进阶实践与常见坑

### Server Debug：MCP Inspector

```bash
npx @modelcontextprotocol/inspector python server.py
```

> [!tip] Inspector 是官方调试神器：可视化查看 tools/list 结果、手动构造参数试调、查看 JSON-RPC 原始报文。**一切"Client 调不通"的问题先上 Inspector 排查**，定位是 Server 侧还是 Host 侧。

### 打包发布与部署

| 方式 | 做法 | 适用 |
|------|------|------|
| uvx 发布 | 配置 pyproject.toml 的 `[project.scripts]` 入口，`uvx my-server` 即装即跑 | Python 生态推荐 |
| 一键注册 | `fastmcp install server.py` 自动写入 Claude Desktop 等 Host 配置 | 桌面端快速接入 |
| pip 发布 | `pip install my-server` 到私有源 | 传统内网源 |
| 离线部署 | wheel 包拷贝 + 本地依赖目录（pip --no-index） | 无外网环境 |
| 在线部署 | Streamable HTTP + 反向代理（Nginx/Caddy）加 TLS | 公网服务 |

> [!warning] 离线 vs 在线：stdio 是本地子进程，天然适合离线部署；远程服务必须选 SSE 或 Streamable HTTP。SSE 是"单向推送"历史方案，新项目直接用 Streamable HTTP 单一端点，省掉旧 HTTP+SSE 双端点的心智负担。

### 基于 SSE / HTTP 的 Server 构建、测试、发布

```bash
# 构建：只改 run 的 transport 参数
# mcp.run(transport="sse", host="[IP已脱敏]", port=8000)             # SSE 双端点（旧）
mcp.run(transport="streamable-http", host="[IP已脱敏]", port=8000)   # 现代推荐

# 测试：Inspector 直接连 URL
npx @modelcontextprotocol/inspector http://localhost:8000/mcp

# 发布：systemd / docker 托管 + 反向代理加 TLS
```

端点设计对比：

| 方案 | 端点 | 说明 |
|------|------|------|
| 旧 HTTP + SSE | `/sse` 长连接 + 独立 `/messages` 端点收消息 | 双端点，网关/代理配置繁琐 |
| Streamable HTTP | 单端点 `/mcp` | 可选升级为 SSE 流式响应，现代推荐 |

### 三平台接入自研 MCP Server

| 平台 | 接入方式 |
|------|----------|
| Cherry Studio | 设置 → MCP 服务器 → 添加（本地填 stdio 命令，远程填 URL） |
| 阿里百炼 | 百炼 MCP 广场选型，或配置自定义 MCP 服务地址 |
| Dify | 工具 → MCP 插件，或上传 OpenAPI schema 生成自定义工具 |

### 常见坑

| 坑 | 现象 | 对策 |
|----|------|------|
| docstring 缺参数说明 | 模型传错参数 | 每个参数写明含义 + 示例 |
| stdio 混入日志 | print 日志污染协议流 | 日志走 stderr，stdout 只给协议 |
| 状态跨调用丢失 | 工具间想共享状态 | 状态存在 Server 内存/文件，Client 侧不要假设 |
| 返回非 JSON | call_tool 结果解析失败 | 工具返回纯文本字符串最稳 |
| 版本漂移 | SDK 与 Host 支持版本不一致 | initialize 阶段对齐版本并降级 |
| 长连接断线 | SSE 连接被网关掐断 | 用 Streamable HTTP + 心跳/重连策略 |
| 权限越界 | Server 访问了授权之外的资源 | Host 侧配置白名单目录/只读挂载 |
| 并发互踩 | 多个 Client 同时调用有状态工具 | 工具设计无状态，或 Server 内加锁 |

## 相关文档

- [[LLM-Agent开发基础]] — Agent 四组件与 ReAct 循环，MCP 工具层的前置知识
- [[AI大模型开发]] — 模型调用与 Function Calling 的底层基础
- [[AI-Dev-KB-Home]] — ai-dev 子库首页，课程骨架总览
- [[A2A多智能体协作协议]] — 多 Agent 间通信协议，与 MCP 的"工具层"互补
- [[DSH跨框架Skills与MCP加载]] — DSH 跨框架加载 Skills 与 MCP 的桥接实践
- [[Skill规模化管理-从渐进式披露到检索式发现]] — 工具/技能规模化的管理方法论

## 参考资料

> [!info] 以下 URL 为本文写作时实际检索核对的技术事实来源（检索日期 2026-08-25）。

- MCP 官方网站：<https://modelcontextprotocol.io/>
- MCP 规范 2025-06-18 — Transports（stdio / SSE / Streamable HTTP 三种传输定义）：<https://modelcontextprotocol.io/specification/2025-06-18/basic/transports>
- MCP Inspector 官方文档（调试方式与连接参数）：<https://modelcontextprotocol.io/docs/tools/inspector>
- FastMCP 官方文档（`@mcp.tool()` 装饰器与 `mcp.run()` 传输参数）：<https://gofastmcp.com/>
- FastMCP CLI — Install MCP Servers（`fastmcp install` 注册方式）：<https://gofastmcp.com/cli/install-mcp>
- FastMCP 2.3 发布说明（Streamable HTTP 支持进展）：<https://jlowin.dev/blog/fastmcp-2-3-streamable-http>
- MCP Python SDK（`stdio_client` / `ClientSession` / `call_tool` 用法）：<https://github.com/modelcontextprotocol/python-sdk>
