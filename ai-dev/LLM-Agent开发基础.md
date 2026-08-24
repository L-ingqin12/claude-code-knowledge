---
title: LLM-Agent开发基础
aliases: [Agent开发基础, ReAct手写实战, 智能体四组件]
tags: [ai, ai/agent]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# LLM-Agent开发基础

一句话定位：本文从"大模型产业落地"切入，系统拆解 Agent（智能体）的四大组件与主流设计模式，并以手写 ReAct 循环和智能客服案例打通"提示词→工具→代码→部署"的完整链路。

> [!abstract] 本文覆盖课程第 8、9 章核心内容：大模型产业落地发展趋势、Agent 四组件原理（LLM 大脑 / Memory 记忆 / Tools 工具 / Planning 规划）、ReAct 与 Plan-and-Execute 等设计模式、o1/R1 推理模型（Reasoning Model）对 Agent 的催化作用，以及手写 ReAct Agent 三步法与智能客服的实战落地。读完可独立写出一个约 50 行的最小 ReAct Agent。

## 核心概念

### 大模型产业落地发展趋势

| 阶段 | 形态 | 代表产品/能力 | 落地特征 |
|------|------|--------------|----------|
| 2022-2023 聊天潮 | Chat（对话） | ChatGPT、文心一言 | 单轮/多轮问答，内容生成 |
| 2023-2024 工具潮 | Copilot（副驾驶） | GitHub Copilot、办公 Copilot | 人主导，模型提建议、补全 |
| 2024-2025 智能体潮 | Agent（智能体） | Claude Code、Manus、Dify 工作流 | 模型主导任务分解与执行闭环 |
| 2025- 多智能体潮 | Multi-Agent（多智能体协作） | A2A 协议生态、Supervisor 编排 | 角色分工、流水线协作、人只验收 |

> [!tip] 关键判断：Agent 不是新模型，而是"模型 + 工具 + 环境 + 流程控制"的新应用范式；竞争门槛从"训模型"转移到"工程化拼装"，普通开发者首次与厂商站在同一起跑线。

### Agent 四组件

| 组件 | 英文 | 职责 | 常见实现 |
|------|------|------|----------|
| 大脑 | LLM Brain | 理解任务、推理、决策 | DeepSeek-V3 / GPT-4o / Claude |
| 记忆 | Memory | 存储历史与知识 | 上下文窗口、向量库（RAG）、对话摘要 |
| 工具 | Tools | 对外执行动作 | Function Calling、MCP 工具、代码执行器 |
| 规划 | Planning | 拆解任务、选择路径 | ReAct、Plan-and-Execute、Reflection |

> [!info] 一句话记忆法：**大脑想、规划拆、工具做、记忆存**，四者由一条"主循环"串起来。四组件中只有"大脑"是模型，其余三件都是工程。

### 主流设计模式

| 模式 | 核心思想 | 优点 | 典型场景 |
|------|----------|------|----------|
| ReAct | Reasoning + Acting 交替：Thought→Action→Observation | 可解释、通用、易手写 | 问答、客服、查询 |
| Plan-and-Execute | 先完整规划再逐步执行 | 长任务稳定、少跑偏 | 多步工程任务 |
| Reflection | 生成→自我批评→修订 | 质量高 | 写作、代码、翻译 |
| Supervisor（多智能体） | 一个编排者给多个 Worker 派活 | 并行、分工 | 复杂协作 |

### o1 / R1 推理模型与 Agent

| 维度 | 快思考模型（V3 等） | 推理模型（o1 / DeepSeek-R1） |
|------|---------------------|------------------------------|
| 输出方式 | 直接生成 | 先输出长思维链（Chain-of-Thought）再给答案 |
| 长任务规划 | 易漂移 | 自带"想清楚再干"，规划更稳 |
| 成本/延迟 | 低 | 高（思考 token 同样计费） |
| 在 Agent 中的用法 | 执行、格式约束 | 规划器、困难步骤、反思器 |

> [!tip] 落地结论：推理模型显著增强了 Agent 的 Planning 能力，但不必全程使用——"快模型执行 + 慢模型规划"是 2025 年主流组合。R1 的思维链内容不应透出给终端用户，注意区分 reasoning_content 与 content。

### Agent 架构设计落地方案

| 分层 | 职责 | 技术选型示例 |
|------|------|--------------|
| 模型层 | 快/慢模型双池，按任务路由 | DeepSeek-V3 + R1 |
| 工具层 | 标准化工具接入与权限控制 | MCP Server、Function Calling |
| 编排层 | 循环、状态机、失败重试 | 手写循环 / LangGraph |
| 应用层 | 面向场景的产品外壳 | 客服、编码、办公助手 |

## 原理剖析

### ReAct 循环：Thought → Action → Observation

![[ReAct-Agent-Loop.excalidraw]]

上图（ReAct-Agent-Loop）展示最经典的 Agent 主循环：用户提问进入 LLM 大脑后，模型按约定格式输出 **Thought（思考）** 与 **Action（动作）**；主循环解析 Action 并调用对应工具，把工具返回的 **Observation（观察）** 拼回上下文，再次交给模型思考。循环往复，直到模型输出 **Final Answer** 或触达 max_iterations（最大迭代次数）保护。

这段循环要理解三个要点：

1. **上下文是唯一状态**——Agent 没有隐藏记忆，Thought/Action/Observation 全部以纯文本拼在 messages 里，模型"看见"的历史就是它的全部记忆（Memory 的上下文窗口形态）。
2. **格式即协议**——`Thought:`、`Action:`、`Action Input:` 的固定格式是人与模型之间的"契约"，工具解析靠正则，协议一旦漂移循环就崩。
3. **环境反馈驱动**——Observation 是工具/环境给的反馈，相当于给模型一个"现实检验"，防止它凭空编答案（幻觉）。

> [!note] 论文原格式 vs 现代变体：ReAct 论文（Yao et al., 2022）的原始提示词采用 `Thought N:` / `Act N:` / `Obs N:` 编号格式，动作集为 `Search[实体]`、`Lookup[关键词]`、`Finish[答案]`；今天更流行的 `Thought:` / `Action:` / `Action Input:` / `Observation:` / `Final Answer:` 是 LangChain 等框架的简化变体。两者思想一致——"思考与行动交替、观察拼回上下文"，本文 Demo 采用后者。

主循环伪代码：

```
# ReAct 主循环伪代码（与下方 Demo 一一对应）
while step < max_iterations:
    reply = llm(messages)              # 模型输出 Thought + Action
    if reply 含 Final Answer: 返回答案
    action = 解析(reply)               # 正则提取工具名与参数
    observation = 执行(action)         # 调用工具，得到环境反馈
    messages += [reply, observation]   # 拼回上下文，进入下一轮
```

推理模型（o1/R1）对循环的改造：把 Planning 环节从"模型边想边做"升级为"先想后做"——R1 类的模型在一次生成中自带长思维链，可以直接产出完整计划，主循环退化为"执行计划 + 偏差时重规划"。代价是延迟与成本上升，因此常见做法是**快模型跑 ReAct 循环、慢模型只在开局做规划或在卡壳时做反思**。

### 多智能体 Supervisor 编排

![[Multi-Agent-Supervisor.excalidraw]]

上图（Multi-Agent-Supervisor）展示多智能体架构：Supervisor（编排者）接收总任务后，先做 Planning 拆解，再把子任务分发给多个 Worker（执行者，如检索员、程序员、测试员），各 Worker 各自持有 LLM 与工具独立执行，产出回汇给 Supervisor 汇总成最终结果。分发与回汇两条回路构成"分发-聚合"骨架。

设计要点：

- **Supervisor 只派活不干活**：负责路由（谁干）与汇总（结果合流），避免单点模型上下文爆炸。
- **Worker 可异构**：不同 Worker 可配不同模型、不同工具、不同系统提示词，例如检索 Worker 配搜索工具，代码 Worker 配执行器。
- **通信靠协议**：Worker 间不直接对话，统一经 Supervisor 或走 A2A（Agent-to-Agent）协议，见 [[A2A多智能体协作协议]]。

### Agent 流行工作方式总结

| 工作方式 | 说明 | 代表 |
|----------|------|------|
| 手写循环（ReAct） | 自己控制 prompt 与循环，最可控 | 本文 Demo |
| 框架编排 | LangChain / LangGraph / AutoGen 封装循环 | 企业级流水线 |
| 厂商 Agent API | OpenAI Assistants、百炼应用 | 低代码 |
| CLI/IDE 编码 Agent | 工具调用 + 权限确认的编码循环 | Claude Code 类 |
| 多智能体平台 | Dify / Coze 画布编排 | 业务快速搭建 |

## 最小可运行 Demo

### 手写 ReAct Agent 三步法

**第一步：提示词设计**——在 system prompt 里约定格式契约：

```
你必须按以下格式回复，每次只输出一步：
Thought: 你的思考
Action: 工具名[参数]   （需要调用工具时输出）
Final Answer: 最终答案 （任务完成时输出）
```

**第二步：工具定义**——Python 字典，工具名 → 可调用函数。

**第三步：代码设计与逻辑验证**——while 循环：调 LLM → 正则解析 Action → 执行工具 → 拼接 Observation。

完整代码（`react_agent.py`，DeepSeek chat API，核心循环约 50 行）：

```python
import json
import re
from openai import OpenAI

# DeepSeek 官方 API 兼容 OpenAI SDK，替换为自己的 key
client = OpenAI(api_key="sk-你的密钥", base_url="https://api.deepseek.com")

SYSTEM_PROMPT = """你是一个具备工具调用能力的助手。请严格按以下格式回应，每次只输出一个步骤：
Thought: 对当前任务的思考（中文）
Action: 工具名[参数]     # 可选，当需要调用工具时输出
Final Answer: 最终答案   # 当任务完成时输出
可用工具：
- get_weather[城市]: 查询某城市的天气
- calculate[表达式]: 计算数学表达式（如 calculate[12*34+56]）
"""

def get_weather(city: str) -> str:
    """模拟天气工具：真实场景替换为 API 调用"""
    return json.dumps({"city": city, "weather": "晴", "temp": "26°C"},
                      ensure_ascii=False)

def calculate(expr: str) -> str:
    """计算器工具：eval 仅演示用，生产环境需白名单校验"""
    return str(eval(expr))

TOOLS = {"get_weather": get_weather, "calculate": calculate}

def run_react(question: str, max_iterations: int = 5) -> str:
    """手写 ReAct 主循环：Thought -> Action -> Observation，直到 Final Answer"""
    messages = [{"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": question}]
    for step in range(max_iterations):          # 迭代上限防死循环
        resp = client.chat.completions.create(
            model="deepseek-chat", messages=messages, temperature=0.1)
        reply = resp.choices[0].message.content  # 模型输出，含 Thought 与 Action
        print(f"--- 第 {step+1} 轮 ---\n{reply}\n")

        # 解析 Final Answer：任务完成，直接返回
        if "Final Answer" in reply:
            return reply.split("Final Answer:", 1)[1].strip()

        # 正则解析 Action：工具名[参数]
        m = re.search(r"Action:\s*(\w+)\[([^\]]*)\]", reply)
        if not m:
            raise RuntimeError("格式漂移：未解析到 Action/Final Answer，请检查 prompt")
        tool_name, arg = m.group(1), m.group(2)
        if tool_name not in TOOLS:
            raise RuntimeError(f"工具幻觉：{tool_name} 不在注册表中")

        observation = TOOLS[tool_name](arg)      # 执行工具，得到 Observation
        messages.append({"role": "assistant", "content": reply})
        messages.append({"role": "user",
                         "content": f"Observation: {observation}"})  # 环境反馈拼回
    return "达到最大迭代次数仍未完成，请检查任务或提示词"

if __name__ == "__main__":
    print("最终结果：", run_react("北京今天天气怎么样？如果明天降温 5 度是多少度？"))
```

> [!success] 逻辑验证点：① 解析不到 Action 且无 Final Answer 应立即报错，避免静默死循环；② Observation 必须 append 成 user 消息，模型才"看得见"工具结果；③ max_iterations 是保命开关，真实系统还要叠加超时与预算。

### 基于 ReAct 的智能客服（需求分析→部署测试）

| 环节 | 做法 |
|------|------|
| 需求分析 | 梳理高频意图（查订单/查物流/退款政策），每个意图对应一个工具 |
| 提示词设计 | system prompt 注入客服人设 + 工具清单 + 边界（拒答无关问题） |
| 代码设计 | 复用上述循环，TOOLS 换成 order_query / logistics_query / refund_policy |
| 部署测试 | 用真实对话样本做回归集，重点测：多意图串联、工具失败兜底话术、越界拒答 |

智能客服提示词片段：

```
你是电商客服"小慧"。规则：
1. 只能回答订单、物流、退款三类问题，其余礼貌拒答。
2. 涉及订单/物流必须调用工具，禁止编造订单号与物流状态。
3. 用户情绪激动时先安抚再处理。
可用工具：order_query[订单号]、logistics_query[订单号]、refund_policy[]
```

> [!tip] 客服场景的 ReAct 价值：Thought 环节天然产出"客服思考过程"，便于审计与话术调优；Observation 兜底话术（工具失败时）必须单独设计，不能把异常堆栈透给用户。

部署测试清单：

- 回归集覆盖 3 类意图 × 每类至少 5 条真实样本
- 并发压测：单实例单轮循环耗时控制在可接受阈值内
- 故障演练：订单查询超时/报错时的兜底话术与降级路径
- 日志审计：Thought/Action/Observation 全量留痕，便于事后复盘

## 进阶实践与常见坑

### 手写循环 vs 框架

| 维度 | 手写循环 | 框架（LangGraph 等） |
|------|----------|---------------------|
| 可控性 | 完全可控 | 受框架抽象约束 |
| 上手成本 | 快（约 50 行） | 前期学习成本高 |
| 状态管理 | 手动拼 messages | 内置状态图/检查点 |
| 适用场景 | 单任务、教学、微服务 | 复杂流程、团队协作 |

> [!tip] 选择建议：先用本文手写版建立对 Agent 的心智模型，再按需引入框架——手写版是理解一切框架的"最小公分母"。

### 失效模式速查表

| 失效模式 | 现象 | 对策 |
|----------|------|------|
| 死循环 | 同一 Action 反复出现，耗尽迭代 | max_iterations + 状态去重检测 |
| 格式漂移 | 不按 Thought/Action 格式输出 | 低温采样、few-shot 示例、解析失败重试 |
| 工具幻觉 | 调用不存在的工具/参数 | 工具注册表白名单 + 解析后校验 |
| 上下文溢出 | 长任务 Observation 堆积超窗口 | 对话摘要压缩、滑动窗口、转 RAG |
| 半途而废 | 长任务中途停下 | 检查点记录 + 断点续跑 |

> [!warning] 生产化第一课：Agent 是"会犯错的软件"。韧性设计（重试、降级、熔断、人工接管）比提示词技巧更决定上线成败，系统性方案见 [[Agent韧性架构分析-微信转载]]。

### 常见坑补充

- **eval 滥用**：计算工具直接用 `eval` 可被注入，生产用 `ast` 白名单或子进程隔离。
- **把思考当答案**：推理模型（R1）的思维链不应透给用户，区分 reasoning_content 与 content。
- **温度设置**：格式敏感环节 temperature 建议 0~0.3；创意环节才调高。
- **过度设计**：能一个 ReAct 循环解决的不要上多智能体框架，先跑通再扩展。
- **观测缺失**：至少记录每轮 Thought/Action/Observation 日志，否则线上问题无法复现。

## 相关文档

- [[AI大模型开发]] — 大模型基础原理，本篇 Agent 的能力底座
- [[AI-Dev-KB-Home]] — ai-dev 子库首页，课程骨架总览
- [[MCP协议开发实战]] — 工具的标准化接入协议，Agent 工具层的演进方向
- [[Function-Calling工具调用实战]] — 厂商原生函数调用与手写 ReAct 的对照
- [[A2A多智能体协作协议]] — Supervisor 多智能体间的标准通信协议
- [[Agent韧性架构分析-微信转载]] — 生产环境 Agent 失效模式与韧性设计
- [[Loop-Engineering-深度拆解-从产品功能集到方法论包装]] — 循环工程的方法论视角

## 参考资料

> [!info] 以下 URL 为本文写作时实际检索核对的技术事实来源（检索日期 2026-08-25）。

- ReAct 论文原文（Yao et al., 2022，原始 Thought/Act/Obs 提示词格式）：<https://arxiv.org/abs/2210.03629>
- Prompt Engineering Guide — ReAct Prompting（论文示例与格式拆解）：<https://www.promptingguide.ai/techniques/react>
- DeepSeek API 官方文档（deepseek-chat 模型与 base_url 用法）：<https://api-docs.deepseek.com/>
- OpenAI Python SDK（DeepSeek 兼容的 chat.completions 调用方式）：<https://github.com/openai/openai-python>
