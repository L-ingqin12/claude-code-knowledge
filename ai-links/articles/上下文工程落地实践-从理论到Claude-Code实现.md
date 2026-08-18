---
title: "上下文工程落地实践——从理论到 Claude Code 源码实现"
aliases: [上下文工程实践, Context Engineering 落地, Claude Code 上下文工程]
tags: [ai/learning, reference]
created: 2026-06-22
updated: 2026-08-17
status: stable
source: "多篇文章融合"
source_urls:
  - "https://mp.weixin.qq.com/s/AI378SJcvKSPk9saXpOXZg"
  - "https://mp.weixin.qq.com/s/CLIuogpYSPng2brQph7AHg"
  - "https://mp.weixin.qq.com/s/gRzmPovqR3ygTDuxkMX-4w"
date: "2026-06-22"
fetched_at: "2026-06-22"
---

# 上下文工程落地实践——从理论到 Claude Code 源码实现

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[上下文工程-注意力预算与四层解法]] | [[Claude-Code记忆机制源码拆解]] | [[Skill规模化管理-从渐进式披露到检索式发现]] | [[2026-08-16-AI链接综述与归档]]

## 摘要

上下文工程的核心问题：**在 Transformer 有限的注意力预算中，如何只放对的东西、在对的位置、用对的形式。** 基础理论来自吴师兄（注意力稀释×Lost in the Middle×Context Rot），落地验证来自小林coding 对 Claude Code 源码的拆解（六层级 CLAUDE.md、ExtractMemories 代理、Sonnet 选择器、stale 警告）和小金AI 的 10 个 Skills 清单（子 Agent 隔离、渐进式披露、verification-before-completion）。

本文按四层解法组织，每层给出：理论依据 → Claude Code 的具体实现 → 迁移到自建 Agent 的具体做法。

---

## 零、前提：三条铁律

在展开四层解法之前，三条从 Claude Code 源码中验证的设计铁律：

### 铁律一：只放代码推不出来的东西

记忆系统明确列出了「不该存清单」——代码模式/架构/文件路径（grep 能推）、Git 历史（git log 是权威）、调试修复方案（已在 commit 中）、CLAUDE.md 已有内容。

**原则**：凡是能从代码仓库确定性推导出来的信息，不放 context。只放代码推不出来的——用户偏好、踩坑教训、项目截止日期、外部系统指针。

### 铁律二：索引常驻，内容按需

MEMORY.md 索引始终在 system prompt → 模型知道有什么可用。具体记忆文件按需加载 → 不浪费 token。这解决了一个两难：全塞爆窗口，不塞模型不知道有什么。

### 铁律三：记忆是历史快照，不是真理

2 天以上的记忆自动加 `<system-reminder>This memory was saved N days ago. Verify.</system-reminder>`。附加验证提示：「记忆说文件在路径 X，先检查是否存在」「记忆说函数叫 Y，先 grep 一下」。记忆像 git log——记录过去发生了什么，不是当前状态。

---

## 一、第一层：检索——只放相关的，不灌全量

### 理论

把 5000 份文档全灌进 context，等于把 100 万 token 噪声压在模型注意力上。检索的本质不（只）是「让模型访问外部知识」，更是 **「让模型不必访问无关知识」**。性价比最高的一招。

### Claude Code 落地

#### 1.1 不用向量检索，用 Sonnet 做选择题

```
步骤：
1. 扫描所有记忆文件的前 30 行（提取 frontmatter，不读正文）
2. 把所有记忆的 name + description 拼成「标题清单」
3. 发给 Sonnet：用户当前问题是 X，哪些记忆相关？不确定就不选
4. Sonnet 用 JSON schema 返回 top-5 文件名
```

系统提示词中明确：「Only include memories that you are certain will be helpful. Be selective and discerning.」

#### 1.2 两道过滤

| 过滤 | 内容 | 原因 |
|------|------|------|
| `alreadySurfaced` | 上轮已出现的记忆直接排除 | 不把 5 个名额浪费在重复上 |
| `recentTools` | 正在用的工具文档排除 | agent 已经在用这工具了，再塞文档是噪音。但工具的坑点/警告保留——正在用时最需要 |

#### 1.3 为什么不选向量检索

向量检索四个致命问题，在记忆场景全中：
- **相似≠相关**：你问代码 bug，它召回所有讨论过 bug 的对话，但只有一两条跟当前代码相关
- **召回不稳定**：换 embedding 模型结果全变
- **维护成本高**：向量数据库 + embedding 模型 + chunk 大小 + 索引更新 + 冲突合并
- **用户没法看**：存进去是 768 维浮点数，debug 一条错误记忆要先反查原文

Claude Code 选 Sonnet 的理由：候选集不超过几百时，小模型做选择题 > 向量检索。一次几百 token，比维护向量数据库便宜。选错能解释，比调阈值容易。

#### 1.4 自建 Agent 怎么抄

```markdown
# 不要
embeddings = model.encode(all_documents)
top_k = vector_search(query_embedding, embeddings, k=5)

# 要
candidates = [{name: doc.name, description: doc.description} for doc in all_docs]
prompt = f"Query: {query}\nAvailable: {json.dumps(candidates)}\nPick top-5."
selected = small_llm(prompt, schema=PickTop5Schema)
```

前提：候选量在几百以内。几千以上仍需 embedding 初筛，但最终选择仍应交给 LLM 而不是阈值。

---

## 二、第二层：压缩——长了就缩，留骨头扔汤

### 理论

Agent 跑了 20 步探索，不能简单砍掉最早几步（可能砍掉关键约束）。正确做法是压缩——20 步过程 → 结构化进展摘要，几百字替换几万 token。压缩的艺术：**留结论、留约束、留待办，扔掉过程噪声。**

这是治理 Context Rot 的主手段——不靠模型「聪明地忽略」，靠工程上阻止垃圾在 context 里堆积。

### Claude Code 落地

#### 2.1 Context 自动压缩（Compaction）

Claude Code 的短期记忆管理：当对话接近窗口上限，不砍最早消息，而是对旧对话运行一次压缩——提取关键结论、活跃约束、待办事项，用压缩后的摘要替换原始历史。

#### 2.2 ExtractMemories 代理——压缩的另一种形态

每轮 query loop 结束后，后台 fork 一个独立代理：
- 扫一遍这一轮对话里的用户反馈、纠正、信息
- 与现有记忆比对去重
- 按四种类型分类
- 写成一条结构化记忆文件

这本质上是把对话压缩成「值得跨会话保留的事实」。关键设计：**fork 主对话而非新建**——复用主对话的 prompt cache，不用重新加载 system prompt，增量开销很小。

#### 2.3 feedback 和 project 的强制结构

```markdown
---
name: 不要用 mock 数据库
description: 集成测试必须连真实数据库
type: feedback
---

集成测试必须连真实数据库，不要用 mock。

**Why:** 上季度 mock 测试通过了但 prod 迁移挂了
**How to apply:** 所有标了「集成测试」的 case 都适用
```

只记规则不记原因 = 边界情况抓瞎。压缩的纪律：**必须保留决策理由和适用条件**，否则压缩后的信息无法在边界情况下被正确使用。

#### 2.4 project 类型的绝对日期强制

用户说「周四前冻结」→ 必须存成「2026-03-05 前冻结」。相对日期过几天就失效，绝对日期永远准确。

#### 2.5 自建 Agent 怎么抄

```python
def compact_history(messages, max_tokens=2000):
    """压缩长对话历史为结构化摘要"""
    old_messages = messages[:-20]  # 保留最近 20 轮原文
    summary_prompt = """
    将以下对话历史压缩为结构化摘要，严格遵守：
    1. 只保留：关键决策、活跃约束、待办事项、用户偏好
    2. 丢弃：中间探索过程、失败的尝试、已解决的问题
    3. 每条约束必须包含 Why 和适用条件
    4. 相对时间转绝对时间
    """
    summary = llm(summary_prompt + format(old_messages), max_tokens=max_tokens)
    return [SystemMessage(summary)] + messages[-20:]
```

---

## 三、第三层：子 Agent 隔离——独立 context，互不污染

### 理论

让一个 Agent 的 context 背负所有任务的全部细节 → 注意力被所有子任务的中间状态淹没。解法：大任务拆给多个子 Agent，每个有自己干净、独立的 context，只装它那一小块任务需要的信息。子 Agent 只把最终结论回传主线，中间探索过程烂在自己 context 里。

**表面是「分工」，底层是「context 隔离」。**

### Claude Code 落地

#### 3.1 ExtractMemories 代理 = 完美的隔离示范

```
主对话 context：
├── 用户问题
├── 模型回复
├── 工具调用序列
│   ├── Read file A
│   ├── Grep pattern B    ← 全部在主 context 里
│   ├── Edit file C
│   └── Bash test
└── 最终输出

ExtractMemories 代理（fork 自主线）：
├── 复用主对话的 prompt cache（不重新加载 system prompt）
├── 只看对话历史 → 决定有没有值得记的
├── 写成独立 .md 文件 ← 中间过程烂在自己 context 里
└── 主对话完全不受影响
```

关键细节：fork 模式让代理**共享 prompt cache**，而不是新建对话重新加载几千 token 的 system prompt。这同时做到了 context 隔离和 token 节省。

#### 3.2 Everything Claude Code——多 Agent 分工的产业实践

把 Claude Code 工作拆到五类配置中：

| 组件 | 职责 | Context 隔离效果 |
|------|------|-----------------|
| Agents | 规划、架构、TDD、审查分别独立子 Agent | 各自独立 context，只回传结论 |
| Skills | 可复用工作流沉淀 | 每个 skill 独立 context 执行 |
| Hooks | 关键节点自动检查 | 不占主对话 context |
| Rules | 长期生效编码规则 | 条件注入，不总是 loaded |
| Commands | `/tdd` `/code-review` 快捷触发 | 触发时新建独立子 Agent |

#### 3.3 Superpowers 的 verification-before-completion

Agent 宣称完成时，不是信它的话，而是要求它在独立 context 里提供证据：
- 测试通过了？→ 贴测试输出
- 功能正常？→ 贴运行日志
- 页面没崩？→ 贴截图

无证据 = 不验收。这本质是用独立验证 context 来对抗主 context 里的腐烂。

#### 3.4 自建 Agent 怎么抄

```python
def run_subagent(task: str, context: dict) -> dict:
    """子 Agent 独立 context 执行，只回传结论"""
    sub_context = [
        SystemMessage(f"Task: {task}"),
        SystemMessage(f"Relevant context: {json.dumps(context)}"),
        # 不加载主 Agent 的完整历史
    ]
    result = agent_loop(sub_context)
    # 只回传结论，中间过程丢弃
    return {"conclusion": result.summary, "artifacts": result.files}

# 主 Agent
sub_results = []
for subtask in decompose(main_task):
    sub_results.append(run_subagent(subtask, extract_relevant_context(subtask)))

# 主 context 只收结论，不收过程
main_context.append(f"Sub-agent results: {json.dumps(sub_results)}")
```

---

## 四、第四层：渐进式披露——用的时候再加载

### 理论

不在一开始就把所有指令、所有文档全部塞进 context，而是分级按需加载：
- **第一级**：一句话元信息（让模型知道「有这个能力、什么时候该用」）
- **第二级**：模型判断真要用了，加载完整说明
- **第三级**：需要某个具体文件了，才去读

无论背后挂了多少知识，任何时刻 context 里只有当前这一步真正用得上的那部分。

### Claude Code 落地

#### 4.1 CLAUDE.md 六层级的分级加载

启动时全量加载的是**六层的元信息**（每层一句话级别的存在声明）。实际内容按需展开：

```
系统启动时注入：
  "Managed rules loaded from /etc/claude/managed/"     ← 元信息
  "User rules loaded from ~/.claude/CLAUDE.md"         ← 元信息
  "Project rules: CLAUDE.md, .claude/CLAUDE.md"       ← 元信息

运行时按需展开：
  agent 读 CLAUDE.md → 发现 @include @~/company/security.md → 加载安全规范
  agent 编辑 *.tsx → 匹配 glob paths: ["**/*.tsx"] → 注入前端规范
  agent 编辑 *.go → 不匹配任何前端 glob → 不加载
```

#### 4.2 条件规则（Conditional Rules）

`.claude/rules/` 下的每条规则通过 frontmatter 的 `paths` 字段做 glob 匹配：

```yaml
---
name: 前端规范
description: React + Tailwind 项目规范
paths: ["**/*.tsx", "**/*.jsx"]
---
```

只在编辑匹配文件时注入。一个项目可以有几十条规则，每条只在需要时占用 token。**这是渐进式披露的最直接实现。**

#### 4.3 MEMORY.md 索引——知识目录的渐进式披露

```
第一级：MEMORY.md 索引始终在 system prompt
  "Available memories: user_role.md — 后端工程师新手前端
                      feedback_no_mock.md — 不要用 mock 测试
                      project_freeze.md — 3月5日合并冻结"

第二级：Sonnet 判断需要某条 → 加载完整记忆文件

第三级：记忆文件里的外部引用 → agent 再去读具体文件
```

#### 4.4 Skills 的渐进式披露（来自小金AI 参考）

| 级别 | 加载内容 | 触发条件 |
|------|---------|----------|
| 元信息 | Skill name + description（一句话） | 始终在 system prompt |
| 完整说明 | Skill 的 SKILL.md 全文 | 模型判断这个 skill 适用于当前任务 |
| 具体文件 | skill 引用的配置、脚本、模板 | 执行时按需读取 |

#### 4.5 自建 Agent 怎么抄

```python
class ProgressiveLoader:
    def __init__(self):
        self.level1 = []    # 始终加载：name + description
        self.level2 = {}    # 按需加载：完整说明
        self.level3 = {}    # 按需加载：具体文件

    def build_system_prompt(self, current_file=None):
        prompt = []
        # Level 1: 始终注入元信息
        for item in self.level1:
            prompt.append(f"- {item['name']}: {item['description']}")
        
        # Level 2: glob 匹配条件注入
        if current_file:
            for rule in self.level2.values():
                if glob_match(rule['paths'], current_file):
                    prompt.append(rule['content'])
        return prompt
    
    def load_on_demand(self, item_name):
        # Level 3: agent 调用时才加载
        if item_name in self.level3:
            return self.level3[item_name]
```

---

## 五、四层协同——一个完整请求的 context 生命周期

把四层解法串起来，看一个 Claude Code 请求的 context 构建全过程：

```
1. 启动时（渐进式披露 Level 1）
   ├── system prompt 基础框架
   ├── CLAUDE.md 六层的元信息声明
   ├── MEMORY.md 索引（所有记忆的 name + description）
   └── Skills 元信息列表（name + description）

2. 用户输入后（检索 + 渐进式披露 Level 2）
   ├── condition: 当前编辑 *.tsx → 注入前端规范
   ├── condition: 当前编辑 *.go → 不注入前端规范
   ├── Sonnet 扫描 MEMORY.md 索引 → 选 top-5 相关记忆
   │   ├── alreadySurfaced 过滤 → 排除上轮已出现的
   │   └── recentTools 过滤 → 排除正在用的工具文档
   ├── 加载选中的 5 条记忆完整文件
   └── @include 引用展开（防循环、防路径遍历）

3. Agent 执行中（压缩 + 子 Agent 隔离）
   ├── context 接近窗口上限 → compaction 压缩旧消息
   │   └── 留结论、留约束、留待办，扔过程噪声
   ├── hook 触发 → ExtractMemories 代理独立 fork
   │   └── 扫对话历史 → 写新记忆文件（不占主 context）
   └── 子 Agent fork → 独立 context 执行 → 只回传结论

4. 注入时（stale 警告）
   ├── 记忆 < 2 天 → 直接注入
   └── 记忆 ≥ 2 天 → <system-reminder> stale 警告 + 验证要求
```

---

## 六、核心设计原则速查

| 原则 | 来源 | 一句话 |
|------|------|--------|
| **只放代码推不出来的** | 记忆机制·不该存清单 | grep/commit 能推出来的不放 context |
| **索引常驻 + 内容按需** | 记忆机制·存储设计 | MEMORY.md 常驻，记忆文件按需 |
| **小模型做选择题** | 记忆机制·检索 | 候选 < 几百时，LLM 选 > 向量检索 |
| **记忆是历史快照** | 记忆机制·stale 警告 | 2 天 stale + grep 验证，不当真理 |
| **结构化优于自由文本** | 记忆机制·四类型 | 写前先分类，强制 Why + How to apply |
| **有效上下文 > 最大上下文** | 上下文工程·核心结论 | 100 万窗口也像 8000 一样经营 |
| **不靠模型聪明，靠工程纪律** | Context Rot 对策 | 不让垃圾进 context，而不是指望模型忽略 |
| **留结论留约束留待办** | 压缩的艺术 | 压缩时保留决策理由和适用条件 |
| **表面分工，底层 context 隔离** | 子 Agent 隔离 | 中间过程不污染主线 |
| **按需加载，不是一次性全塞** | 渐进式披露 | Skills/条件规则/索引的三级模型 |
