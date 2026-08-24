---
title: Prompt-Engineering入门与Demo
aliases: [提示词工程入门, Prompt Engineering入门, PE入门与Demo]
tags: [ai, ai/learning]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# Prompt-Engineering入门与Demo

本文是提示词工程（Prompt Engineering，简称 PE）的入门实践手册：先建立"面向目标架构的需求分析 → 技术选型"方法框架，再以两个可直接运行的 Python Demo 落地 Few-shot 少样本与 CoT 思维链（Chain-of-Thought）的核心技法。

> [!abstract] 定位与目标
> 本文服务《第 7 章 提示词部分》课程骨架：需求函数自动编写（Few-shot 少样本示例）、稳定函数编写（LtM 提示流程）、提示词管理（模板集中管理 / 版本化）、code_generate 全自动编程函数、GLM-4 级模型编码能力体验差异、大模型 Debug 能力检测与自动 Debug 函数，以及复杂任务瓶颈分析（上下文长度限制 / 单次生成质量上限）。读完可获得：① 一套可复用的 `PromptTemplate` 模板类；② zero-shot / few-shot / CoT 三路对照实验脚本；③ 对"任务拆解 + 多轮协作"解决思路的完整认知。

## 核心概念

### 术语表

| 术语 | 中文含义 | 一句话解释 |
|------|----------|-----------|
| Prompt | 提示词 | 发给模型的全部输入文本，是当前最直接的"编程接口" |
| System Prompt | 系统提示词 | 固定在对话开头的全局指令（角色、规则、输出格式），优先级最高 |
| Zero-shot | 零样本 | 不给示例直接提问，完全依赖模型预训练知识作答 |
| Few-shot | 少样本 | 在 Prompt 中塞入 2-5 个"输入→输出"示例，让模型模仿格式与逻辑 |
| ICL | In-Context Learning（上下文学习） | 模型仅凭 Prompt 内的示例临时学会任务，不更新任何参数 |
| CoT | Chain-of-Thought（思维链） | 让模型先输出中间推理步骤再给答案，即"一步一步想" |
| LtM | Least-to-Most（由易到难） | 把难题拆成子问题逐题求解，前一步答案作为下一步输入 |
| Temperature | 温度 | 采样随机性参数：低=稳定可复现，高=发散有创意 |
| Token | 词元 | 计费与上下文窗口的计量单位；官方口径 100 Token ≈ 75 个英文单词，中文压缩比无官方数据（待验证） |
| 结构化输出 | Structured Output | 强制模型按 JSON / XML 等固定格式输出，便于程序解析 |

### 六件套通用技法速查

| 技法 | 作用 | 关键要点 |
|------|------|----------|
| 角色设定 | 收窄输出分布、激活领域知识 | "你是资深 Python 工程师"优于"你帮我写代码" |
| 分隔符 | 防注入、防指令混淆 | 用三引号或 XML 标签把指令、示例、用户输入隔开 |
| 结构化输出 | 让结果可被程序消费 | 要求"只输出 JSON"，并给出字段名与取值说明 |
| CoT 思维链 | 提升推理类任务正确率 | 数学/逻辑题先列步骤；关键词"让我们一步一步思考" |
| Few-shot 示例 | 校准输出格式与风格 | 示例必须覆盖边界情况，且与目标输出同分布 |
| 温度搭配 | 控制随机性 | 代码/数学/信息抽取用 0-0.2；头脑风暴/文案用 0.7-1.0 |

### Few-shot 示例选择三原则

| 原则 | 说明 | 反例 |
|------|------|------|
| 分布一致 | 示例的格式、风格、语言必须与期望输出一致 | 期望 JSON 却给自然语言示例 |
| 覆盖边界 | 至少包含一个正常样例 + 一个边界/异常样例 | 只有"理想输入"的示例集 |
| 宁精勿滥 | 2-5 条精选优于 20 条灌水，省 Token 且少干扰 | 示例挤占上下文导致目标问题被截断 |

## 原理剖析

### ICL 为什么有效：注意力机制下的"现场拟合"

提示词工程的本质是调用模型的上下文学习（In-Context Learning，ICL）能力。Transformer 的注意力机制（Attention）让模型在生成每个 Token 时都能回看 Prompt 里的所有示例，从示例的"输入→输出"对里临时拟合出一个映射函数——这个函数只存在于本次前向计算中，不会写入任何权重。由此推出三条推论：

- **示例质量决定上限**：示例本质是训练数据的"现场补丁"，错误示例会直接产生负迁移（Negative Transfer）；
- **示例位置影响权重**：注意力随距离衰减，把最关键的示例放在 Prompt 末尾（离目标问题最近处）效果最好；
- **上下文就是工作台**：指令 + 示例 + 用户输入共享同一个上下文窗口，任何一块过大都会挤占其他部分。

> [!note] 与参数微调（Fine-tuning）的区别
> Few-shot 不改变模型参数、即插即用、零训练成本，但每次调用都要为示例重复付费（占 Token）；微调把能力固化进权重、单次调用更便宜，但需要数据集与训练成本。工程上先 Few-shot 验证可行性，再决定是否微调。

三项核心技法的论文出处（经公开资料交叉核实，详见文末参考资料）：

| 技法 | 出处 | 要点 |
|------|------|------|
| ICL | Brown et al., 2020（GPT-3，arXiv 2005.14165） | 首次系统展示"给示例即学会"的上下文学习能力 |
| CoT | Wei et al., NeurIPS 2022 | 思维链显著提升多步推理任务正确率 |
| LtM | Zhou et al., ICLR 2023（arXiv 2205.10625） | 由易到难分解提示，应对复杂任务 |

### LtM 提示流程：复杂任务拆解

```text
目标: 让模型稳定地编写复杂需求函数
        ↓ 一次性提问
[失败模式] 输出半截 / 中后段逻辑漂移 / 幻觉出依赖 —— 撞上单次生成质量上限
        ↓ LtM 改造
Step1: 先问"请列出该函数需要处理的子问题清单"      → 得到拆解
Step2: 逐个子问题提问"请实现子问题 N"                → 得到局部正确代码
Step3: 让模型"把以上片段合并为完整函数并自查"        → 拼装 + 自检
```

LtM（Least-to-Most，由易到难）的核心思想：**不让模型一次跨过整条推理链，而是把链条切成它能稳定走完的小段**。每一小段输入短、目标明确，落在单次生成质量上限之内；前一段的输出作为后一段的输入，天然形成多轮协作。

![[Prompt-Engineering-LtM-Flow.excalidraw]]

> [!note] 图由主会话稍后创建，直接嵌入
> 上图为 LtM 提示流程示意图（Excalidraw 手绘图）：左列展示"一次性提问"的失败模式，右列展示"拆解 → 分步求解 → 合并"三步流程与每步上下文规模的变化。嵌入路径为 `![[Prompt-Engineering-LtM-Flow.excalidraw]]`，图创建完成后本文档无需再改。

### 复杂任务瓶颈分析

| 瓶颈 | 具体表现 | 解决思路 |
|------|----------|----------|
| 上下文长度限制 | 长需求 + 多示例 + 历史对话超出窗口，开头内容被遗忘或截断 | 任务拆解：每轮只给当前子任务所需的上下文 |
| 单次生成质量上限 | 输出越长，中后段质量断崖式下跌，代码写到一半逻辑漂移 | 分步生成 + 多轮协作：每步短输出，逐步拼接 |
| 注意力稀释 | 与当前子任务无关的信息挤占注意力预算 | 精简每轮 Prompt，隔离无关上下文（详见 [[上下文工程-注意力预算与四层解法]]） |

一句话总结：**任务拆解 + 多轮协作**是对抗"上下文有限 + 单次生成有限"两大硬约束的通用解法，LtM 是它的最小实现。

## 最小可运行 Demo

### Demo 1：可复用 PromptTemplate 类（约 40 行）

str.format 模板 + Few-shot 注入的最小实现，`python prompt_template.py` 即可运行：

```python
# -*- coding: utf-8 -*-
"""可复用 PromptTemplate 类：str.format 模板 + Few-shot 示例注入。
运行: python prompt_template.py"""

class PromptTemplate:
    """提示词模板：集中管理模板文本，支持 {占位符} 填充与 few-shot 示例注入。"""

    def __init__(self, template: str, examples: list = None):
        # template 使用 str.format 风格占位符，如 "请将{src}翻译成{tgt}"
        self.template = template
        self.examples = examples or []   # 每条示例: {"input": ..., "output": ...}

    def add_example(self, input_text: str, output_text: str):
        """追加一条 few-shot 示例（输入 → 期望输出）。示例越多校准越强，但 Token 消耗越大。"""
        self.examples.append({"input": input_text, "output": output_text})

    def render(self, **kwargs) -> str:
        """渲染最终 Prompt：先注入示例块，再填充模板占位符。目标任务放在末尾，离注意力最近。"""
        parts = []
        if self.examples:
            parts.append("请参考以下示例的格式完成新任务：")
            for i, ex in enumerate(self.examples, 1):
                parts.append(f"【示例{i}】\n输入：{ex['input']}\n输出：{ex['output']}")
        parts.append(self.template.format(**kwargs))
        return "\n\n".join(parts)


if __name__ == "__main__":
    # 使用场景：需求函数自动编写（课程骨架中的 Few-shot 部分）
    tmpl = PromptTemplate(
        template="请根据以下需求编写 Python 函数，只输出代码不要解释：\n{requirement}",
        examples=[
            {"input": "写一个函数，计算两个数的和",
             "output": 'def add(a, b):\n    """返回 a 与 b 的和"""\n    return a + b'},
            {"input": "写一个函数，判断整数是否为偶数",
             "output": 'def is_even(n):\n    """判断 n 是否为偶数"""\n    return n % 2 == 0'},
        ],
    )
    print(tmpl.render(requirement="写一个函数，判断整数是否为质数"))
```

> [!tip] 模板即资产
> 把所有 `PromptTemplate` 实例集中放在 `prompts/` 包中统一 import，就是"提示词模板集中管理"的最小形态；配合 git 提交即可获得版本化能力。

### Demo 2：zero-shot vs few-shot vs CoT 效果对比脚本

同一个数学任务，三种 Prompt 写法对照；未配置 `OPENAI_API_KEY` 时自动走 Mock 客户端，保证离线可运行：

```python
# -*- coding: utf-8 -*-
"""同一任务下 Zero-shot / Few-shot / CoT 三种 Prompt 效果对比脚本。
运行: python prompt_compare.py
未配置 OPENAI_API_KEY 时使用内置 Mock 客户端（离线可跑）；配置后切换真实接口。
"""

import os

TASK = "电影《流浪地球3》票房 58 亿，制作成本 12 亿，营销成本 3 亿，制片方利润率是多少？（保留一位小数）"

# ① Zero-shot：零示例直接提问，完全依赖模型先验知识
ZERO_SHOT = f"请回答问题：{TASK}\n只输出最终答案。"

# ② Few-shot：给一条同类示例校准解题格式（示例与任务同分布）
FEW_SHOT = (
    "请参考示例的解题方法回答新问题。\n\n"
    "示例：某电影票房 30 亿，制作成本 8 亿，营销成本 2 亿，制片方利润率是多少？\n"
    "解答：总成本 = 8 + 2 = 10 亿；利润 = 30 - 10 = 20 亿；利润率 = 利润 / 票房 = 20 / 30 ≈ 66.7%。\n\n"
    f"新问题：{TASK}"
)

# ③ CoT：不给示例，但强制模型展示中间推理步骤
COT = (
    f"请回答问题：{TASK}\n"
    "请一步一步思考：先列出已知条件，再写出计算公式，最后给出结果。"
)


def fake_llm(prompt: str) -> str:
    """Mock 客户端：按 Prompt 特征返回预设结果，演示三种写法的典型差异。"""
    if "一步一步" in prompt:                      # CoT：推理链完整
        return ("已知条件：票房 58 亿、制作 12 亿、营销 3 亿。\n"
                "总成本 = 12 + 3 = 15 亿；利润 = 58 - 15 = 43 亿。\n"
                "利润率 = 43 / 58 ≈ 74.1%。\n最终答案：74.1%")
    if "示例" in prompt:                          # Few-shot：模仿示例格式作答
        return "总成本 = 12 + 3 = 15 亿；利润 = 58 - 15 = 43 亿；利润率 = 43 / 58 ≈ 74.1%"
    return "利润率是 8.3%。"                       # Zero-shot：易算错或漏步骤


def chat(prompt: str) -> str:
    """真实客户端插槽：有 Key 走 OpenAI 兼容接口，无 Key 走 Mock。"""
    api_key = [已脱敏]("OPENAI_API_KEY")
    if not api_key:
        [已脱敏] fake_llm(prompt)
    from openai import OpenAI                      # pip install openai
    client = OpenAI(api_key=[已脱敏])
    resp = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": prompt}],
        temperature=0.0,                            # 数学任务：低温保证可复现
    )
    return resp.choices[0].message.content


if __name__ == "__main__":
    print("=" * 60)
    for name, prompt in [("zero-shot", ZERO_SHOT), ("few-shot", FEW_SHOT), ("cot", COT)]:
        print(f"\n===== {name} =====")
        print("--- 发送的 Prompt ---\n" + prompt)
        print("--- 模型输出 ---\n" + chat(prompt))
    print("\n" + "=" * 60)
    print("观察要点：few-shot 校准格式、CoT 暴露推理过程，两者正确率通常高于 zero-shot。")
```

> [!tip] 实验结论的推广
> 换模型（如 GLM-4 系列）时必须重跑这套对比脚本：不同模型对同一 Prompt 的敏感度不同，示例与温度参数不能原样照搬，提示词迁移 = 参数迁移 + 评测回归。

## 进阶实践与常见坑

### 提示词管理：模板集中管理 + 版本化

```
prompts/
├── __init__.py
├── code_gen.py       # 需求函数编写模板 + few-shot 示例
├── code_debug.py     # Debug 修复模板
└── chat.py           # 通用对话模板
```

- **集中管理**：所有 `PromptTemplate` 实例在 `prompts/` 包中定义，业务代码只 import，禁止散落的 Prompt 字符串；
- **版本化**：`prompts/` 目录纳入 git；每次修改模板提交一次 commit 并在模板名中标注版本（如 `code_gen_v2`）；
- **变更可评估**：模板升级后用固定评测集（同 Demo 2 脚本）跑回归对比，量化新模板是加分还是减分。

### code_generate 全自动编程函数

```python
from prompts.code_gen import TEMPLATE   # 已注入 few-shot 示例的模板实例

def code_generate(requirement: str, llm=call_llm) -> str:
    """全自动编程函数：需求文本 → Prompt 渲染 → 模型调用 → 返回代码。"""
    return llm(TEMPLATE.render(requirement=requirement))
```

设计要点：**单一职责**（只生成代码，不做解释）、**输出约束**（模板内写明"只输出代码"）、**示例覆盖**（few-shot 示例覆盖该需求域的主流函数形态）。复杂需求请改用 LtM 分步调用。

### GLM-4 级模型编码能力体验差异

| 能力维度 | 表现特征 | 应对策略 |
|----------|----------|----------|
| 简单函数编写 | 稳定正确，速度快 | zero-shot + 低温即可 |
| 中等复杂需求 | 偶发逻辑错误、边界遗漏 | few-shot + temperature 0.1 |
| 复杂多模块需求 | 一次生成常"缺胳膊少腿" | LtM 拆解 + 多轮协作 |
| 长代码生成 | 中后段质量明显下降 | 分函数生成再合并 |

> [!warning] 换模型的必做动作
> GLM-4 级模型（如 GLM-4-Flash / GLM-4-Plus）与 GPT-4 级模型的提示词大体可迁移，但温度敏感性、示例偏好存在差异。**每换一次模型，就用 Demo 2 的脚本重跑评测集**，把差异量化后再上线（GLM-4 模型名单见文末参考资料）。

### 大模型 Debug 能力检测与自动 Debug 函数

检测方法：① 故意给含 bug 的代码，问"找出问题并说明原因"；② 给报错堆栈（Traceback），问"如何修复"；③ 迭代修复直到测试用例通过，记录修复轮数作为能力指标。

```python
def auto_debug(code: str, error: str, template, llm=call_llm, max_rounds: int = 3) -> str:
    """自动 Debug 函数：把代码 + 报错回喂模型，多轮迭代直到可运行。"""
    for _ in range(max_rounds):
        code = llm(template.render(code=code, error=error))
        error = try_run(code)        # 试运行返回 None 表示通过，否则返回新报错
        if error is None:
            return code               # 修复成功
    return code                       # 达到轮数上限仍未通过，转人工
```

> [!info] Debug 也是"多轮协作"
> 自动 Debug 的本质与 LtM 相同：单轮修不好就拆成"定位问题 → 给出补丁 → 验证"多轮循环，每轮只让模型处理一个小增量。

### 常见坑清单

| 坑 | 现象 | 对策 |
|----|------|------|
| 温度设置不当 | 代码任务用高温，两次调用结果不一致 | 生成/抽取类 0-0.2；创意类 0.7-1.0 |
| 示例过长过多 | 上下文被示例挤爆，目标问题被截断 | 2-5 条精选示例，长示例压缩后再用 |
| 示例泄漏 | 模型原文照抄示例答案，评测失真 | 示例与真实任务差异化，评测换题 |
| JSON 不稳定 | 偶尔多出解释文字或尾逗号 | 结构化输出模式 / JSON Schema 约束 + 解析失败重试 |
| 分隔符冲突 | 用户输入里出现与指令相同的分隔符 | 用 XML 标签或随机分隔符包裹用户输入 |
| 负迁移 | 示例风格把目标任务带偏 | 检查示例与目标分布是否一致，必要时删示例 |
| 一步到位幻想 | 复杂需求一次生成质量差 | LtM 拆解 + 多轮协作（见 [[#复杂任务瓶颈分析]]） |

## 相关文档

- [[AI大模型开发]] — 本知识库 LLM 开发总笔记，Prompt 技法的底层是注意力机制与 ICL，可交叉阅读；
- [[AI-Dev-KB-Home]] — AI 开发子 Vault 的首页 MOC，本文所在章节的导航入口；
- [[Function-Calling工具调用实战]] — 提示词的自然延伸：让模型输出结构化 tool_calls 来调用外部函数；
- [[RAG检索增强生成实战]] — 与 Few-shot 互补的另一种知识注入方式：检索（Retrieval）增强生成；
- [[LLM-Agent开发基础]] — 提示词工程是 Agent 的底层语言，Agent 循环 = 多轮协作的工程化；
- [[上下文工程-注意力预算与四层解法]] — 上下文窗口与注意力预算的进阶管理，瓶颈分析的深化；
- [[Anthropic-Skill系统深度分析]] — 提示词模板组织形式的业界参考（Skills 化的模板管理）。

## 参考资料

> [!info] 本文关键技术事实经 web_search 交叉核实，以下为实际参考的公开资料（访问日期 2026-08-25）。

1. [OpenAI Prompt engineering guide（官方六大策略指南）](https://platform.openai.com/docs/guides/prompt-engineering) — 清晰指令、提供参考文本、拆解复杂任务、让模型"思考"等策略的官方出处；
2. [Anthropic: Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices) — XML 标签、角色提示、few-shot 示例、思维链等 2024-2026 最佳实践；
3. [Brown et al., Language Models are Few-Shot Learners（arXiv 2005.14165）](https://arxiv.org/abs/2005.14165) — In-Context Learning（上下文学习）概念的原始出处；
4. [Wei et al., Chain-of-Thought Prompting Elicits Reasoning in Large Language Models（NeurIPS 2022）](https://proceedings.neurips.cc/paper_files/paper/2022/hash/9d5609613524ecf4f15af0f7b31abca4-Abstract-Conference.html) — CoT 思维链原始论文；
5. [Zhou et al., Least-to-Most Prompting Enables Complex Reasoning（arXiv 2205.10625, ICLR 2023）](https://arxiv.org/abs/2205.10625) — LtM 由易到难提示原始论文；
6. [OpenAI Help Center: What are tokens and how to count them?](https://help.openai.com/en/articles/4936856-what-are-tokens-and-how-to-count-them) — "100 Token ≈ 75 英文单词"官方口径；中文 Token 压缩比无官方数据（待验证）；
7. [OpenAI API Reference: chat/completions](https://platform.openai.com/docs/api-reference/chat/create) — temperature 默认值为 1、低温度输出更确定性的官方参数定义；
8. [智谱 GLM-4 系列模型官方文档](https://docs.bigmodel.cn/cn/guide/models/text/glm-4) — GLM-4-Flash / GLM-4-Plus 等模型名单与能力说明。
