---
title: "Anthropic Claude Code Skill 系统：设计方案与实现方法深度分析"
aliases: [Anthropic Skill系统, Skill Creator, Skill系统深度分析]
tags: [ai/skills, ai/learning]
created: 2026-06-12
updated: 2026-08-17
status: stable
source: "Anthropic 官方博客 + 社区资料分析"
date: "2026-06-12"
---

# Anthropic Claude Code Skill 系统：设计方案与实现方法深度分析

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[Claude-Code实用Skills参考]] | [[Skill规模化管理-从渐进式披露到检索式发现]] | [[Agent驱动Skill迁移设计]] | [[日志检索分析系统-Skill管理Demo设计]]

> 分析日期: 2026-06-12
> 分析范围: skill-creator, skill-development, skill-refactor, 及 Anthropic 内部实践

---

## 目录

1. [Skill 系统架构总览](#1-skill-系统架构总览)
2. [Skill 解剖学：目录结构与渐进式披露](#2-skill-解剖学目录结构与渐进式披露)
3. [Skill Creator：元技能的设计与实现](#3-skill-creator元技能的设计与实现)
4. [Skill Development：插件生态中的规范化方法论](#4-skill-development插件生态中的规范化方法论)
5. [Skill Refactor：路由歧义的消除系统](#5-skill-refactor路由歧义的消除系统)
6. [Anthropic 内部实践：9 大分类与设计原则](#6-anthropic-内部实践9-大分类与设计原则)
7. [核心设计原则横切对比](#7-核心设计原则横切对比)
8. [实现模式总结](#8-实现模式总结)
9. [生态与分发](#9-生态与分发)

---

## 1. Skill 系统架构总览

### 1.1 什么是 Skill

Skill 是 Claude Code 的**模块化能力扩展单元**。它是一个包含指令、脚本、资产和数据的**文件夹**（不是单一 markdown 文件），Agent 自动发现并加载它们来提升特定领域的准确性和效率。

核心理念来自 Anthropic 官方博客：

> "Skills are structured as folders — not just markdown files — containing instructions, scripts, assets, and data. Agents discover them and use them to improve accuracy and efficiency."

### 1.2 系统架构层次

```
┌─────────────────────────────────────────────────────┐
│                    用户请求                           │
└─────────────────────┬───────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────┐
│              Skill 路由层 (Skill Routing)             │
│  ┌───────────────────────────────────────────────┐  │
│  │  Agent 根据 skill description (frontmatter)    │  │
│  │  从 available_skills 列表中选择匹配的 skill     │  │
│  └───────────────────────────────────────────────┘  │
│  输入: 用户 prompt + 所有 skill metadata (~100词/个)  │
│  输出: 选中的 skill (或 none)                         │
└─────────────────────┬───────────────────────────────┘
                      │ skill 被触发
                      ▼
┌─────────────────────────────────────────────────────┐
│              渐进式加载层 (Progressive Disclosure)    │
│                                                     │
│  Level 1: Metadata (name + description)             │
│           → 始终在上下文中 (~100 词)                  │
│                                                     │
│  Level 2: SKILL.md 正文                              │
│           → skill 触发时加载 (<500 行 / <5k 词)       │
│                                                     │
│  Level 3: 捆绑资源 (Bundled Resources)                │
│           → scripts/   - 可执行而不加载到上下文       │
│           → references/ - 按需加载                    │
│           → assets/     - 用于输出，不占上下文         │
└─────────────────────────────────────────────────────┘
```

### 1.3 三层渐进式披露的 Token 经济

这是整个 skill 系统**最核心的设计约束**：

| 层级 | 内容 | 加载时机 | Token 成本 | 设计约束 |
|------|------|---------|-----------|---------|
| **Metadata** | YAML frontmatter (name, description) | 始终在上下文 | ~100 tokens/skill | description ≤ 1024 字符，必须同时包含"做什么"和"何时用" |
| **SKILL.md 正文** | 核心指令、工作流、示例 | skill 触发时 | <5k 词（推荐上限） | 只放核心流程；接近上限时拆到 references/ |
| **捆绑资源** | scripts/, references/, assets/ | 按需 | 无限制（scripts 不占上下文） | references 大文件 (>300行) 需有目录 |

**关键洞察**: 为什么每个 skill 都检入 repo 会增加上下文负担？因为 **Level 1 metadata 是所有 skill 同时加载的**。一个 50 个 skill 的项目，即使没触发任何 skill，也要消耗 ~5000 tokens 在 description 上。

### 1.4 Skill 的触发机制

Agent 决定是否触发 skill 的核心逻辑：

1. Agent 看到 `available_skills` 列表（每个 skill 的 name + description）
2. 根据用户请求的语义，判断是否需要某个 skill
3. **关键**: Agent 只会为其**无法轻松独立处理**的任务触发 skill — 简单的单步查询即使 description 匹配完美也可能不触发
4. 复杂、多步骤、专业化的查询最容易触发 skill

因此：**description 是写给人（Agent）看的，不是给用户看的**。它不是功能摘要，而是触发条件描述。

---

## 2. Skill 解剖学：目录结构与渐进式披露

### 2.1 标准目录结构

```
skill-name/                    # kebab-case 命名，必须
├── SKILL.md                   # 必须，大小写敏感
│   ├── ---                    # YAML frontmatter 开始
│   ├── name: skill-name       # 必须，skill 标识符
│   ├── description: ...       # 必须，触发条件描述
│   └── ---                    # YAML frontmatter 结束
│   └── Markdown 指令正文       # 必须
│
├── scripts/                   # 可选：可执行代码
│   ├── validate.py            #   确定性/重复性任务
│   └── rotate_pdf.py          #   可执行而不加载到上下文
│
├── references/                # 可选：扩展文档
│   ├── schemas.md             #   按需加载到上下文
│   ├── api.md                 #   大文件需有目录
│   └── patterns.md            #   信息不与 SKILL.md 重复
│
└── assets/                    # 可选：输出用资源
    ├── template.pptx           #   不加载到上下文
    ├── logo.png               #   复制或修改后用于输出
    └── boilerplate/           #   模板代码
```

### 2.2 各目录的用途边界

#### SKILL.md (必须)

**包含**（始终在 skill 触发时加载）:
- 核心概念和概述
- 关键流程和工作流
- 快速参考表格
- 指向 references/examples/scripts 的指针
- 最常用的使用场景

**不包含**:
- 超过 500 行的内容（应拆分）
- 重复 description 的内容
- 显而易见的常识
- 鼓励语/空洞内容

#### scripts/ (可选)

**何时放入**: 同一段代码被反复重写，或需要确定性可靠性时。

**关键优势**: 脚本可以**不加载到上下文窗口**中执行，token 效率极高。

```
示例: rotate_pdf.py → 每次旋转 PDF 不再需要 agent 重写 30 行 Python
      validate.sh    → 验证逻辑确定且复用
```

#### references/ (可选)

**何时放入**: 详细文档在 agent 工作时需要参考，但不是每次触发都需要。

**最佳实践**:
- SKILL.md 和 references 之间**信息不重复**
- 详细信息放 references，核心流程放 SKILL.md
- 大文件 (>10k 词) 在 SKILL.md 中提供 grep 搜索模式

```
示例: 
  references/schema.md    → 数据库 schema，agent 需要时读取
  references/policies.md  → 公司政策，按需查阅
  references/api_docs.md  → API 文档，需要时参考
```

#### assets/ (可选)

**何时放入**: skill 需要用于最终输出的文件（模板、图片、字体、样板代码）。

**关键**: assets 中的文件**不进入上下文窗口**，它们被复制或修改后用于输出。

```
示例:
  assets/logo.png          → 品牌资产
  assets/template.pptx     → PowerPoint 模板
  assets/frontend-template/ → HTML/React 样板
```

### 2.3 多域组织模式

当 skill 支持多个框架/平台时，按变体组织：

```
cloud-deploy/
├── SKILL.md              # 工作流 + 选择逻辑
└── references/
    ├── aws.md            # Agent 只读相关文件
    ├── gcp.md
    └── azure.md
```

SKILL.md 中包含选择逻辑（"如果是 AWS → 读 aws.md"），Agent 只加载相关的 reference 文件。

---

## 3. Skill Creator：元技能的设计与实现

### 3.1 定位

Skill Creator 是一个**元技能 (meta-skill)** — 它的任务是构建和优化其他 skill。它于 2026 年 3 月发布，实现了"用技能构建技能"的递归自举。

> 来源: Anthropic 官方 skills 仓库 (github.com/anthropics/skills, 141k+ stars)

### 3.2 四大模式

| 模式 | 目的 | 核心流程 |
|------|------|---------|
| **Create** | 从零构建新 skill | 意图捕获 → 访谈 → 编写 → 测试 → 迭代 |
| **Eval** | 评估 skill 输出质量 | 运行测试用例 → 评分 → 分析模式 → 生成报告 |
| **Improve** | 基于反馈改进 skill | 读反馈 → 归纳 → 修改 → 重新测试 → 比较 |
| **Benchmark** | 盲测 A/B 版本对比 | 并行运行两版本 → 盲评 → 分析差异 → 生成建议 |

### 3.3 三个内部 Agent 的协作架构

Skill Creator 使用**子 Agent 并行协作**模式，而非单体流程：

```
                    ┌──────────────┐
                    │  用户请求     │
                    └──────┬───────┘
                           │
                           ▼
               ┌───────────────────────┐
               │   Skill Creator       │
               │   (协调编排)           │
               └───────┬───────────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         ▼             ▼             ▼
   ┌──────────┐ ┌──────────┐ ┌──────────┐
   │ Executor │ │  Grader  │ │ Analyzer │
   │ (执行)   │ │ (评分)   │ │ (分析)   │
   └──────────┘ └──────────┘ └──────────┘
         │             │             │
         └─────────────┼─────────────┘
                       │
                       ▼
               ┌──────────────┐
               │ Comparator   │
               │ (盲测对比)    │  ← 可选，用于 A/B 测试
               └──────────────┘
```

#### Executor (执行器)
- 职责: 在给定 skill 的情况下执行测试 prompt
- 运行方式: 子 Agent 并行执行（with-skill 和 baseline 同时启动）
- 输出: 执行转录 (transcript) + 输出文件

#### Grader (评分器)
- 职责: 评估 execution 输出是否满足 assertions
- 输入: expectations（断言列表）、transcript_path、outputs_dir
- 输出: `grading.json`（包含 passed/failed、证据、claims 验证）
- **独特设计**: 评分器不仅要给断言打分，还要**批判断言本身**的质量

评分器的双重职责设计非常精妙：
```json
{
  "expectations": [...],     // 逐条断言评分
  "eval_feedback": {         // 对断言的批判
    "suggestions": [
      {
        "assertion": "输出包含名字 'John Smith'",
        "reason": "一份幻觉产生的文档如果提到名字也能通过——应考虑检查它是否作为主要联系人出现"
      }
    ]
  }
}
```

#### Analyzer (分析器)
- 职责: 解盲对比结果，分析**为什么**赢家获胜
- 输入: winner 和 loser 的 skill 路径 + transcript 路径
- 输出: 结构化 JSON — 赢家优势、输家弱点、指令遵循度评分、改进建议
- 改进建议按优先级分类：`high/medium/low`

#### Comparator (对比器)
- 职责: **盲测** (blind comparison) — 不知道哪个版本的 skill 产生了哪个输出
- 输出: `comparison.json`（含 rubric 评分矩阵 + 赢家判定）
- Rubric 评分维度的设计：

| 维度 | 1 (差) | 3 (可接受) | 5 (优秀) |
|------|--------|-----------|---------|
| 正确性 (Correctness) | 重大错误 | 小错误 | 完全正确 |
| 完整性 (Completeness) | 缺失关键元素 | 大部分完整 | 所有元素齐全 |
| 准确性 (Accuracy) | 显著不准确 | 轻微不准确 | 全程准确 |
| 组织 (Organization) | 杂乱 | 基本有序 | 清晰逻辑 |
| 格式 (Formatting) | 不一致/损坏 | 大致一致 | 专业精致 |
| 可用性 (Usability) | 难以使用 | 可用但费劲 | 易于使用 |

### 3.4 Create 模式的完整流程

```
意图捕获 (Capture Intent)
  │ 理解用户想要什么
  │ 从对话历史中提取已有工作流
  │ 明确: 做什么 / 何时触发 / 输出格式 / 是否需要测试
  ▼
访谈与研究 (Interview & Research)
  │ 主动问边界情况、输入输出格式、依赖
  │ 并行搜索 MCP 获取上下文
  ▼
编写 SKILL.md
  │ 填充 name / description / body
  │ 遵循 skill writing guide
  ▼
创建测试用例 (2-3 个)
  │ 保存到 evals/evals.json
  │ 不含 assertions（稍后添加）
  ▼
Step 1: 同时启动所有运行 (with-skill + baseline)
  │ 每个测试用例启动两个子 Agent
  │ 保存输出到 workspace/iteration-N/
  ▼
Step 2: 在运行进行中，起草 assertions
  │ 利用等待时间
  │ 更新 eval_metadata.json
  ▼
Step 3: 运行完成时捕获 timing 数据
  │ 从 task notification 中提取 total_tokens + duration_ms
  │ 立即保存到 timing.json（这是唯一机会）
  ▼
Step 4: 评分、聚合、启动查看器
  │ 启动 Grader 子 Agent 评估每个用例
  │ 运行 aggregate_benchmark.py 生成统计
  │ 做 Analyst pass 发现隐藏模式
  │ 启动 eval-viewer (generate_review.py)
  ▼
Step 5: 读取用户反馈
  │ 从 feedback.json 读取
  │ 关注有具体投诉的用例
  ▼
改进 → 重新运行 → 重复直到满足退出条件
```

### 3.5 Description 优化子系统

这是 Skill Creator 中最精细的子系统之一，专门解决 skill 触发准确性问题。

#### 核心流程

```
Step 1: 生成触发评估查询集
  ├── 20 个查询: 8-10 个 should-trigger + 8-10 个 should-not-trigger
  ├── 查询必须是真实用户会输入的内容
  ├── should-not-trigger 最有价值的是「近失」(near-miss) 查询
  └── 避免太简单的负样本（太简单不测试任何东西）

Step 2: 与用户一起审查
  ├── 使用 assets/eval_review.html 模板
  ├── 用户可编辑、开关 should-trigger、增删条目
  └── 导出 eval_set.json

Step 3: 运行优化循环 (run_loop.py)
  ├── 60/40 分割: train 集 / held-out test 集
  ├── 每个查询运行 3 次取可靠触发率
  ├── 基于 train 失败模式调用 Claude 提出改进
  ├── 最多 5 轮迭代
  └── 按 test 分数（非 train 分数）选择最佳描述 → 防止过拟合

Step 4: 应用结果
  └── 将 best_description 写入 SKILL.md frontmatter
```

#### 核心算法（run_loop.py 的实现）

```python
# 分层随机分割（按 should_trigger 分层）
train_set, test_set = split_eval_set(eval_set, holdout=0.4)

# 每轮迭代:
for iteration in range(1, max_iterations + 1):
    # 1. 评估当前 description（train + test 一起运行以提高并行度）
    all_results = run_eval(queries=train_set + test_set, 
                           description=current_description, 
                           runs_per_query=3)
    
    # 2. 分离 train/test 结果
    train_passed, test_passed = split_results(all_results)
    
    # 3. 如果全部通过 → 退出
    if train_passed == total:
        break
    
    # 4. 基于 train 结果改进 description（test 分数对改进模型不可见）
    new_description = improve_description(
        current_description, train_results, blinded_history)
    
    # 5. 循环

# 最终: 按 test 分数选最佳（而非 train 分数）
best = max(history, key=lambda h: h["test_passed"])
```

**关键设计决策**: 
- 用 test 分数选最佳，不是 train 分数 → 防止过拟合到 train 集
- 改进时对 test 结果**设盲** → 防止描述泄露 test 信息
- 分层分割保证 should-trigger 和 should-not-trigger 在 train/test 中都有代表

### 3.6 数据模型设计

Skill Creator 定义了完整的 JSON Schema 体系：

| Schema 文件 | 用途 | 关键字段 |
|------------|------|---------|
| `evals.json` | 定义测试用例 | id, prompt, expected_output, expectations[] |
| `history.json` | 追踪版本演进 | version, parent, pass_rate, grading_result |
| `grading.json` | 评分结果 | expectations[], summary, claims[], eval_feedback |
| `metrics.json` | 执行指标 | tool_calls{}, total_steps, errors, output_chars |
| `timing.json` | 时间数据 | total_tokens, duration_ms, executor/grader timings |
| `benchmark.json` | 基准测试结果 | runs[], run_summary{}, delta{}, notes[] |
| `comparison.json` | 盲测对比 | winner, rubric{}, output_quality{}, expectation_results |
| `analysis.json` | 赛后分析 | winner_strengths[], loser_weaknesses[], suggestions[] |

### 3.7 打包系统

`package_skill.py` 将 skill 文件夹打包为 `.skill` 文件（实际是 ZIP 格式）:

- 排除 `__pycache__`, `node_modules`, `*.pyc`, `.DS_Store`
- 排除根级 `evals/` 目录（评估数据不打入分发包）
- 打包前运行 `quick_validate.py` 验证结构
- 输出: `<skill-name>.skill`

---

## 4. Skill Development：插件生态中的规范化方法论

### 4.1 与 Skill Creator 的关系

| 维度 | Skill Creator | Skill Development |
|------|-------------|-------------------|
| **定位** | 元技能，自动化 skill 构建 | 指南/方法论，人工遵循 |
| **适用场景** | 通用 skill 创建 | 插件内的 skill 开发 |
| **测试方式** | 子 Agent 并行评估 + 定量评分 | 安装插件本地测试 |
| **打包** | 生成 .skill 文件 | 随插件分发，不需要打包 |
| **目录位置** | 独立 skill 目录 | 插件内的 `skills/` 子目录 |

### 4.2 规范化的创建流程

Skill Development 定义了严格的 6 步流程：

```
Step 1: 理解具体示例
  ├── 从用户获取具体使用场景
  ├── "这个 skill 应该支持什么功能？"
  ├── "有哪些使用方式？什么短语应该触发它？"
  └── 避免一次性问太多问题

Step 2: 规划可重用内容
  ├── 分析每个示例：从头执行需要什么？
  ├── 识别可复用的 scripts/, references/, assets/
  └── 产出: 资源清单

Step 3: 创建目录结构
  └── mkdir -p plugin-name/skills/skill-name/{references,examples,scripts}

Step 4: 编辑 Skill
  ├── 先创建可重用资源 (scripts/, references/, assets/)
  ├── 再写 SKILL.md
  ├── description: 第三人称 + 具体触发短语
  └── body: 命令式(imperative)写作, 1,500-2,000 词

Step 5: 验证和测试
  ├── 使用 skill-reviewer agent 审查
  └── 安装插件本地测试

Step 6: 迭代
  └── 在实际使用中发现不足 → 改进 → 重测
```

### 4.3 写作规范

Skill Development 建立了严格的写作风格规则：

| 位置 | 规范 | 正确示例 | 错误示例 |
|------|------|---------|---------|
| **Description** | 第三人称 | "This skill should be used when the user asks to..." | "Use this skill when you want to..." / "Load when user needs..." |
| **Body** | 命令式/不定式 | "To create a hook, define the event type." | "You should create a hook..." / "Claude should extract..." |
| **整体** | 客观、指导性 | "Parse the frontmatter using sed." | "You can parse the frontmatter..." |

### 4.4 skill-reviewer Agent

skill-reviewer 是一个专门的审查 Agent，执行 8 步审查流程：

1. 定位并读取 SKILL.md
2. 验证结构（frontmatter 格式、必填字段）
3. 评估 description 质量（触发短语、第三人称、具体性、长度）
4. 评估内容质量（词数、写作风格、组织）
5. 检查渐进式披露（核心 vs references 分离）
6. 审查支持文件
7. 识别问题（按 critical/major/minor 分类）
8. 生成建议（具体修复方案 + 前后对比）

---

## 5. Skill Refactor：路由歧义的消除系统

### 5.1 问题模型

这是用户创建的最复杂的 skill，专门解决多 skill 共存时的**路由歧义**问题：

```
用户请求: "review 一下我的代码改动"
                │
                ▼
    ┌───────────────────────┐
    │   Agent 看到 3 个     │
    │   相似的 skill:        │
    │                       │
    │   code-review         │ ← 检查 bugs + compliance
    │   security-review     │ ← 只做安全检查
    │   pr-review-toolkit   │ ← 多个 agent 并行 review
    │                       │
    │   触发词都含 "review" │
    │   结构都是审查代码     │
    │   → 选哪个？          │
    └───────────────────────┘
```

### 5.2 三重目标体系

| 目标 | 含义 | 衡量标准 |
|------|------|---------|
| 🎯 **精准路由** | 相似 skill 之间建立互斥的决策边界 | 歧义评分 < 20%，正样本触发率 ≥ 90% |
| 📐 **精简完备** | 每个 skill 职责单一、零 filler | 无 God Skill，无重复指令，无死代码 |
| 🔒 **功能保持** | 重构前后功能完全一致（硬约束） | 所有 functional_steps 在新结构中可追溯 |

### 5.3 核心概念：决策边界 (Decision Boundary)

```
Skill A                Skill B
  │                      │
  │   ┌──────────────┐   │
  │   │  歧义区域     │   │   ← 需要消除
  │   └──────────────┘   │
  │                      │
  ◄────── 边界线 ────────►
  
 边界线 = 明确的区分条件，agent 可以据此决策
```

**好的决策边界**:
- 互斥条件：场景 X vs 场景 Y，不重叠
- 信号明确：agent 只需 1-2 个特征词即可判定
- 边界清晰：不存在"两个都行"的灰色地带

**坏的决策边界**:
- 两个 description 都用同一触发词
- 依赖读 skill body 才能区分（太晚了）
- 用模糊程度副词区分

### 5.4 歧义评分算法

`analyze_skills.py` 计算每对 skill 的歧义风险：

| 维度 | 权重 | 含义 |
|------|------|------|
| Trigger Word Overlap | 40% | description 中的关键词重叠率 |
| Domain Overlap | 30% | 是否属于同一领域 |
| Structural Similarity | 30% | 指令结构、工具链、输出格式相似度 |

**分类阈值**:
```
Ambiguity ≥ 70%:  🔴 CONFLICT  — 必须合并或用条件拆分
Ambiguity 40-70%: 🟡 AMBIGUOUS — 需添加互斥条件
Ambiguity 20-40%: 🟢 NEAR      — 需添加区分提示
Ambiguity < 20%:  ✅ DISTINCT  — 互不干扰
```

### 5.5 四种决策边界建立方法

#### 方法 1: 互斥条件拆分 (NOT 子句)

```
Before (歧义):
  skill-A: "Code review for pull requests"
  skill-B: "Security review for code changes"

After (互斥):
  skill-A: "General code review for bugs and CLAUDE.md compliance.
            Use for: 'review this PR', 'code review', 'check my changes'.
            Do NOT use for: security-only assessments — use security-review for that."
  skill-B: "Security-focused review: injection risks, auth bypass, data leaks.
            Use for: 'security review', 'check for vulnerabilities'.
            Do NOT use for: general bug review — use code-review for that."
```

**关键技巧**: description 中的 **NOT 子句**明确告诉 agent 什么情况下不要触发自己。

#### 方法 2: 粒度分层

用操作范围/耗时区分：
```
  skill-A: "Run unit tests quickly (single command, <30s)"
  skill-B: "Run full CI pipeline (build + test + lint + deploy check, ~10min)"
```

#### 方法 3: 场景锚定

用用户所处的工作阶段区分：
```
  skill-A: "Create a git commit during active development. Use when mid-work."
  skill-B: "Complete workflow: commit + push + open PR. Use when work is done."
```

#### 方法 4: 合并消除

当无法建立边界时，合并为最精确版本。

### 5.6 功能保持约束 (Hard Constraint)

这是 skill-refactor 最严谨的部分 — 任何重构都必须保证功能等价：

**操作前**: 提取"功能指纹" — 原 skill 的完整功能清单（每个 step 的输入/输出/工具调用/边界处理）

**操作后**: 逐条 trace 验证 — 原 skill 的每个 step 在新结构中可找到对应，0 偏差才通过。

**三层验证**:
1. **Layer 1: 功能等价性** (Must Pass) — 100% trace 通过
2. **Layer 2: 路由精准性** (Should Pass) — 正样本命中率 ≥ 90%
3. **Layer 3: 精简完备性** (Nice to Pass) — body ≤ 500 行，无重复

### 5.7 "Ruthless Cut" — 无意义内容清除

这是 skill-refactor 中最激进也是最容易忽略的设计原则：

```
判断标准: "删掉它，agent 还能正确执行吗？"
  如果能 → 删掉
  如果不能 → 保留，但检查是否可以写得更短

必须删除:
  ├── 显而易见的常识说明
  ├── 重复 description 的内容
  ├── 空洞的鼓励语
  ├── 过度详细的示例
  ├── 模糊的多选指引 → 给一条最优路径
  └── 大段背景介绍 → 移入 references/

必须精简:
  ├── 超过 4 行的代码块 → agent 不需要看完整实现
  ├── 重复的指令块 → 提取为一句引用
  └── "Step 1...Step N" + 重复的 summary → 删 summary
```

---

## 6. Anthropic 内部实践：9 大分类与设计原则

> 来源: [Lessons from building Claude Code: How we use skills](https://claude.com/blog/lessons-from-building-claude-code-how-we-use-skills) (Anthropic 官方博客, 2026 年 6 月)

### 6.1 9 大 Skill 分类

| # | 分类 | 目的 | 实例 |
|---|------|------|------|
| 1 | **Library & API Reference** | 正确使用库/CLI/SDK | `billing-lib`, `internal-platform-cli` |
| 2 | **Product Verification** | 测试/验证代码行为 | `signup-flow-driver`, `tmux-cli-driver` |
| 3 | **Data Fetching & Analysis** | 连接数据和监控栈 | `funnel-query`, `grafana`, `datadog` |
| 4 | **Business Process & Team Automation** | 自动化重复工作流 | `standup-post`, `create-ticket`, `weekly-recap` |
| 5 | **Code Scaffolding & Templates** | 生成框架样板代码 | `new-workflow`, `new-migration`, `create-app` |
| 6 | **Code Quality & Review** | 执行代码质量/审查 | `adversarial-review`, `code-style` |
| 7 | **CI/CD & Deployment** | 代码交付和部署 | `babysit-pr`, `deploy-service`, `cherry-pick-prod` |
| 8 | **Runbooks** | 症状 → 调查 → 结构化报告 | `service-debugging`, `oncall-runner` |
| 9 | **Infrastructure Operations** | 运维操作（带护栏） | `resource-orphans`, `cost-investigation` |

关键洞察：**最好的 skill 干净地落入一个分类**。试图做太多事的 skill "跨越多个分类并让 agent 困惑"。

### 6.2 官方设计原则

#### 原则 1: 不陈述显而易见的事
Claude 已经会编码、会读代码库。重申默认行为"增加上下文但不增加价值"。

> 示例: 前端设计 skill 没有解释 "Inter 字体和紫色渐变"，因为 agent 设计中已经知道。

#### 原则 2: 建立 Gotchas 部分
"任何 skill 中信号密度最高的内容就是 Gotchas 部分"。这些是从实际使用中积累的常见故障点。

> 示例: "这个表是 append-only 的 — 你想要最高版本号，不是最近时间戳"

#### 原则 3: 使用文件系统和渐进式披露
Skill 文件夹本身就是"上下文工程和渐进式披露的一种形式"。

#### 原则 4: 避免 Railroading Claude
给出信息丰富但足够灵活的指令。过于具体的指令限制可重用性。

#### 原则 5: 考虑设置成本
需要用户上下文的 skill（如"发到哪个 Slack 频道"）应主动询问。好模式：在 skill 目录中存 `config.json`。

#### 原则 6: 为模型写 Description，不是为人
Description 字段是 Claude 用来决定相关性的 — "它不是摘要，而是何时触发此 skill 的描述"。

#### 原则 7: 帮助 Claude 记忆
Skill 可以包含持久化数据存储（append-only logs、JSON 文件、SQLite）。`CLAUDE_PLUGIN_DATA` 环境变量提供稳定目录。

#### 原则 8: 存储脚本和生成代码
"让 Claude 在组合上花费轮次，决定下一步做什么，而不是重建样板。"

#### 原则 9: 使用按需 Hooks
仅在 skill 被调用时激活的 hooks，仅持续会话期间。如 `/careful` hook 阻止 `rm -rf`、`DROP TABLE`。

### 6.3 治理与演进模式

Anthropic 的内部 marketplace 采用**有机治理**而非中央控制：

1. 作者上传到 GitHub sandbox 文件夹，通过 Slack/论坛推广
2. Skill 获得 traction 后，所有者决定何时提 PR 进入主 marketplace
3. 通过 `PreToolUse` hook 记录内部 skill 使用情况
4. 团队通过使用数据识别热门 skill 和"触发不足"的 skill

**演进路径**：
> "大多数我们最好的 skill 始于几行代码和一个 gotcha，然后因为人们不断在 Claude 遇到新边界情况时添加内容而变得更好。"

---

## 7. 核心设计原则横切对比

下图展示了三大 skill 系统中共同出现的设计原则：

| 设计原则 | Skill Creator | Skill Development | Skill Refactor | Anthropic 内部 |
|---------|:---:|:---:|:---:|:---:|
| **渐进式披露** (3 层加载) | ✅ 核心机制 | ✅ 核心机制 | 隐含 (500行上限) | ✅ 核心机制 |
| **Description 承载路由信息** | ✅ 有优化子系统 | ✅ 第三人称+触发短语 | ✅ 决策边界+NOT子句 | ✅ "写给模型看" |
| **Explanation > MUST** | ✅ "Explain the why" | ✅ 命令式但不严苛 | ✅ 零 filler, 删常识 | ✅ "Don't railroad" |
| **确定性优先** (scripts/) | ✅ 检测模式→抽取脚本 | ✅ 确定性可靠性 | ✅ 提取共享步骤 | ✅ "Store scripts" |
| **迭代闭环** | ✅ Create→Eval→Improve | ✅ Test→Iterate | ✅ 备份→变换→trace | ✅ "Small→Grow" |
| **定量评估** | ✅ assertions+metrics | 人工审查 | ✅ 歧义评分+路由测试 | ✅ 使用数据追踪 |
| **子 Agent 协作** | ✅ 并行 Executor+Grader | skill-reviewer | 隐含 (路由地图) | ✅ 多 Agent 审查 |
| **功能保持/非破坏性** | ✅ 版本追踪 | ✅ 渐进迭代 | ✅ 硬约束 (逐条 trace) | ✅ 渐进推广 |
| **Token 效率** | ✅ 3 层 loading | ✅ 1.5-2k 词上限 | ✅ ≤500行 + ruthless cut | ✅ "Don't state obvious" |

### 核心洞察：三条线的互补性

```
Skill Creator:    🏭 工厂 — 自动化创建、评估、优化 skill
Skill Development: 📖 手册 — 规范化的写作和结构指南
Skill Refactor:   🔧 维护 — 消除已有 skill 之间的冲突

三者关系:
  Skill Development 定义了"好 skill 长什么样"
  Skill Creator 自动化了"如何创建好 skill"
  Skill Refactor 解决了"好 skill 多了之后如何共存"
```

---

## 8. 实现模式总结

### 8.1 子 Agent 并行评估模式

Skill Creator 的评估流程体现了一个通用的并行模式：

```
Pipeline (并行评估 → 聚合分析):
  ┌──────────────────────────────────────────────────┐
  │ 同一轮中同时启动:                                  │
  │   with-skill Agent × N 个测试用例                  │
  │   baseline Agent × N 个测试用例                    │
  │                                                  │
  │ 同时做 (利用等待时间):                              │
  │   起草 assertions                                 │
  │                                                  │
  │ 运行完成后:                                       │
  │   Grader Agent × N → grading.json                │
  │   aggregate → benchmark.json                     │
  │   Analyst pass → 隐藏模式发现                      │
  │   generate_review.py → 可视化报告                  │
  └──────────────────────────────────────────────────┘
```

### 8.2 Train/Test 隔离防止过拟合

```
完整 eval set (20 queries)
        │
        ▼
  ┌─────────────────────┐
  │ 分层随机分割 (60/40)  │  ← 按 should_trigger 分层
  └──────┬──────────────┘
         │
    ┌────┴────┐
    ▼         ▼
 train (12)  test (8)
    │         │
    │         │  ← test 对改进模型 **设盲**
    ▼         │
  改进循环     │
    │         │
    └────┬────┘
         ▼
   按 test 分数选最优  ← 防止过拟合到 train
```

### 8.3 结构化 JSON 作为 Agent 间通信协议

所有子 Agent 之间通过严格的 JSON Schema 通信：

```
Executor ──(metrics.json)──► Grader
Grader   ──(grading.json)──► aggregate_benchmark.py
aggregate ──(benchmark.json)──► generate_review.py
Comparator ──(comparison.json)──► Analyzer
Analyzer  ──(analysis.json)──► 用户
用户     ──(feedback.json)──► 下一轮迭代
```

这种设计的优势：
- 子 Agent 的输出可验证、可缓存、可重放
- 不同组件可以独立开发和测试
- JSON Schema 本身是 Agent 和脚本之间的契约

### 8.4 可视化反馈循环

Skill Creator 通过 `generate_review.py` 构建的 Web 查看器：

```
┌─────────────────────────────────────────────┐
│  Outputs 标签          │  Benchmark 标签     │
│                        │                    │
│  ┌──────────────────┐  │  pass_rate: +50%   │
│  │ Eval 1: prompt   │  │  time: +13s        │
│  │ Output: files    │  │  tokens: +1700     │
│  │ Previous Output  │  │                    │
│  │ Formal Grades    │  │  Per-eval 细分     │
│  │ Feedback textbox │  │  Analyst 观察      │
│  └──────────────────┘  │                    │
│                        │                    │
│  ←prev  next→         │                    │
│  [Submit All Reviews]  │                    │
└─────────────────────────────────────────────┘
```

### 8.5 Routing Map — 可解释的决策树

Skill Refactor 的最终输出是一张**路由地图**，让用户理解 agent 的选择逻辑：

```
当用户说 "review" 时:
┌─────────────────────┬───────────────┬──────────────────────────┐
│ 用户实际意图         │ 正确 Skill    │ 识别信号                  │
├─────────────────────┼───────────────┼──────────────────────────┤
│ 检查 bugs + 规范    │ code-review   │ "review PR", "check bugs" │
│ 只做安全检查        │ security-review│ "security", "vulnerability"│
│ 全面多维度审查      │ pr-review-toolkit│ "comprehensive", "full" │
└─────────────────────┴───────────────┴──────────────────────────┘
```

---

## 9. 生态与分发

### 9.1 分发路径

```
Skill 的创建和分发路径:

  个人使用                      团队共享                     公开发布
  ────────                     ────────                    ────────
  ~/.claude/skills/    →    项目 .claude/skills/   →   Marketplace
  或个人 commands/            或内部 marketplace          公开 plugin
```

### 9.2 Marketplace 的两级结构

```
claude-plugins-official (官方 marketplace)
├── plugins/
│   ├── skill-creator/          # 元技能
│   ├── plugin-dev/             # 插件开发工具
│   ├── commit-commands/        # Git 提交命令
│   ├── code-review/            # 代码审查
│   ├── hookify/                # Hooks 管理
│   ├── frontend-design/        # 前端设计
│   ├── claude-md-management/   # CLAUDE.md 管理
│   ├── mcp-server-dev/         # MCP 服务器开发
│   ├── session-report/         # 会话报告
│   └── ...

permafrost (第三方 marketplace)
├── commands/
│   ├── benchmark.md
│   ├── doctor.md
│   ├── status.md
│   └── wrap.md
```

### 9.3 Plugin 内的 Skill 组织结构

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json             # 插件清单
├── commands/                   # 斜杠命令 (也是 skill)
│   └── my-command.md
├── agents/                     # 定制 Agent
│   └── my-agent.md
└── skills/                     # Skill 定义
    └── my-skill/
        ├── SKILL.md
        ├── references/
        ├── examples/
        └── scripts/
```

### 9.4 发现与加载机制

1. Claude Code 自动扫描 `skills/` 目录
2. 找到包含 `SKILL.md` 的子目录
3. 解析 YAML frontmatter 获取 metadata
4. 所有 skill 的 metadata 始终在上下文中（Level 1）
5. 当 agent 根据 description 判断需要时，加载 SKILL.md 正文（Level 2）
6. Agent 在需要时自主决定读取 references/ 或执行 scripts/（Level 3）

---

## 总结：将一切连接起来

### 设计哲学的一致性

Anthropic 的 skill 系统（包括社区扩展）展现出非常一致的设计哲学：

1. **上下文是稀缺资源** — 每一层都精心控制 token 消耗。Progressive Disclosure 和 Ruthless Cut 是同一原则的两面。

2. **Description 是路由协议** — 不是给人看的摘要，而是 Agent 的触发信号。这决定了 skill 生态的互操作性。

3. **确定性外包给脚本** — LLM 擅长组合和决策，脚本擅长确定性执行。Skill 设计的艺术在于区分两者。

4. **迭代是默认模式** — 从 Skill Creator 的 Eval→Improve 循环，到 Anthropic 内部 "从几行 + 一个 gotcha" 开始的演进路径，再到 Skill Refactor 的备份→变换→trace 安全网。

5. **Agent 间通信需要结构化契约** — JSON Schema 作为 Agent 和脚本之间的协议，使子系统可独立开发、测试和缓存。

### 系统的优雅之处

这套系统的真正强大之处不在于任何一个 skill，而在于**它们之间的关系**：

- Skill Creator **创建** skill
- Skill Development **规范化** skill 的结构
- Skill Refactor **维护** skill 之间的关系
- skill-reviewer **审查** skill 的质量
- Evolve 系统（用户构建）**持续优化** skill

这是一个可以自我改进的递归系统 — "用 skill 构建 skill" 不仅是口号，而是实际的架构选择。

---

## 参考来源

1. [Lessons from building Claude Code: How we use skills](https://claude.com/blog/lessons-from-building-claude-code-how-we-use-skills) — Anthropic 官方博客, 2026 年 6 月
2. [Skill Creator — Ultimate Guide](https://skywork.ai/blog/claude-code-skill-creator-ultimate-guide/) — Skywork.ai, 2026
3. [Anthropic Skills Repository](https://github.com/anthropics/skills) — GitHub, 141k+ stars
4. [The Recursive Advantage](https://shellypalmer.com/2026/03/the-recursive-advantage/) — Shelly Palmer, 2026
5. Anthropic 官方 marketplace: `claude-plugins-official` 仓库中的 skill-creator 和 plugin-dev
6. 用户构建的 skill-refactor 和 evolve 系统（本地 `.claude/skills/` 目录）
