---
title: "Skill 规模化管理——从渐进式披露到检索式发现"
aliases: [Skill规模化管理, 检索式发现, Skill Discovery]
tags: [ai/skills, ai/learning]
created: 2026-06-22
updated: 2026-08-25
status: review
source: "基于 Claude Code Skills 体系推演"
date: "2026-06-22"
fetched_at: "2026-06-22"
---

# Skill 规模化管理——从渐进式披露到检索式发现

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[Agent驱动Skill迁移设计]] | [[日志检索分析系统-Skill管理Demo设计]] | [[Claude-Code记忆机制源码拆解]] | [[上下文工程落地实践-从理论到Claude-Code实现]]

## 摘要

当 Skill 从 10 个增长到 1000 个，渐进式披露的 Level 1（元信息始终在 system prompt）本身就成为瓶颈——1000 个 skill × 30 token/行 = 30000 token，还没加载任何内容就把 system prompt 吃掉了。

解法：把上下文工程的四层解法**递归应用到 Skill 管理自身**。Skill 元信息不再是常驻列表，而是一个可检索、可发现、按时效性分层的动态目录。核心转变：**从「渐进式披露」（先列目录再展开）到「检索式发现」（先搜再列）。**

---

## 一、问题的缩放曲线

```
Skill 数量        渐进式披露开销          瓶颈在哪
──────────────────────────────────────────────────
10-50            300-1500 token        ✅ 完全可接受
100-300          3000-9000 token       ⚠️ 开始挤压其他元信息
500-1000         15000-30000 token     ❌ system prompt 被淹没
5000+            不可行                  ❌❌ 模型根本看不全
```

当前阶段（10-50 个 skill）渐进式披露完全够用。但问题出在**信息密度**：30 token 的一行 Skill 元信息，它的「信息密度」远低于一条 30 token 的记忆 description。因为记忆是对话中长出来的、高度个性化的，而 Skill 是通用的——「这个 skill 是干什么的」对当前任务而言，大部分时候是噪声。

Skill 数量和当前任务的**相关性比例**，决定了瓶颈到来的速度：

| 场景 | Skill 总数 | 与当前任务相关的 | 相关性比例 | 浪费的元信息 token |
|------|-----------|----------------|-----------|------------------|
| 单人全栈 | 20 | 8-12 | 40-60% | 可接受 |
| 团队多项目 | 200 | 10-20 | 5-10% | 90% 是噪声 |
| 公司级市场 | 2000 | 5-10 | < 1% | 99% 是噪声 |

规模越大，**相关性比例越低，渐进式披露的浪费越严重**。

---

## 二、解法：检索式发现——把四层递归应用到自己身上

核心思路：不是因为 Skill 多了就「不要渐进式披露了」，而是**在渐进式披露的前面再加一层——Skill 发现层**。

```
渐进式披露（当前）
  system prompt: [skill_a, skill_b, skill_c, ... skill_z] ← 全部列出
  model 自己判断用哪个

检索式发现（规模化后）
  system prompt: search_skills(query) ← 一个工具，一句说明（30 token）
  model 调用 search_skills("current task description") → 返回 top-5 匹配
  system prompt 只注入这 5 个的元信息
```

### 2.1 四层递归对照

| 上下文工程四层 | 应用于 Context | 递归应用于 Skill 管理 |
|--------------|---------------|---------------------|
| **检索** | 从文档库检索相关片段 | 从 Skill 注册中心检索相关 Skill |
| **压缩** | 压缩长对话历史 | 压缩 Skill 元信息（description → 一行摘要 → 嵌入向量） |
| **子 Agent 隔离** | 独立 context 执行子任务 | Skill 独立 context 执行，不污染主 prompt |
| **渐进式披露** | 指令按需加载 | Skill 按三层加载：搜索结果 → 元信息 → 完整 SKILL.md |

### 2.2 三层架构

```
Layer 0 — Skill 发现（检索式，替代常驻列表）
  ├── model 调用 search_skills(task_description) 
  ├── 返回 top-5 候选 skill 的 name + description
  └── 开销：5 × 30 = 150 token（vs 1000 × 30 = 30000 token）

Layer 1 — Skill 元信息（渐进式披露 Level 1）
  ├── 只加载 Layer 0 返回的 top-5 的元信息
  └── 与当前渐进式披露完全兼容

Layer 2 — Skill 完整内容（渐进式披露 Level 2 & 3）
  ├── model 判断要用了 → 加载完整 SKILL.md
  └── 需要具体文件 → 按需读取
```

---

## 三、Layer 0 的实现方案

### 3.1 方案 A：小模型选择器（候选 < 500）

和记忆系统的 Sonnet 选择器完全一致：

```python
def search_skills(query: str, all_skills: list, top_k: int = 5) -> list:
    """用小模型从所有 skill 中选 top-k"""
    candidates = [
        {"name": s.name, "description": s.description, "namespace": s.namespace}
        for s in all_skills
    ]
    prompt = f"""
    Task: {query}
    Available skills (only name + description):
    {json.dumps(candidates, ensure_ascii=False)}

    Select the {top_k} most relevant skills. Be selective — 
    if uncertain, do NOT include. Return only the skill names.
    """
    result = small_llm(prompt, schema=TopKSchema)
    return [s for s in all_skills if s.name in result.names]
```

优点：简单、和记忆系统统一、可解释。  
局限：候选超过 500 时，candidates 字符串本身可能超过小模型 context。

### 3.2 方案 B：两阶段检索（候选 > 500）

当 skill 数量超过小模型一次性处理的阈值时，加一层粗筛：

```python
def search_skills_large(query: str, index, top_k: int = 5) -> list:
    # Stage 1: 向量粗筛（embedding → top-50）
    query_vec = embed(query)
    coarse = index.search(query_vec, k=50)
    
    # Stage 2: LLM 精排（50 个候选 → top-5）
    return small_llm_selector(query, coarse, top_k=5)
```

这里用了向量检索，但和记忆系统的区别在于：**向量只做粗筛，不做最终决策**。最终选择仍是 LLM——避免「0.87 相似度但实际不相关」的向量检索老问题。

### 3.3 方案 C：命名空间 + 触发条件前置过滤

在任何检索发生之前，先用规则砍掉不相关的 skill：

```yaml
# 每个 skill 的 frontmatter 声明
---
name: react-hooks-guide
namespace: frontend/react
paths: ["**/*.tsx", "**/*.jsx"]
tasks: ["ui-development", "code-review"]
requires: ["node", "npm"]
conflicts: ["vue-best-practices"]
---

# Skill 内容...
```

```python
def pre_filter(skills, context):
    """规则前置过滤——不花 token，纯逻辑匹配"""
    filtered = []
    for s in skills:
        if s.namespace and context.project_type not in s.namespace:
            continue  # 前端项目不加载 backend skill
        if s.paths and not glob_match(s.paths, context.current_files):
            continue  # 编辑 .go 不加载 React skill
        if s.conflicts and any(c in context.active_skills for c in s.conflicts):
            continue  # vue 和 react skill 互斥，只加载一个
        filtered.append(s)
    return filtered
```

这个过滤是**零 token 开销**的——在候选技能进入 LLM 视野之前，先砍掉确定不相关的。

---

## 四、时效性分层——Skill 的「stale 管理」

记忆系统有 2 天 stale 警告。Skill 同样有时效性问题：某个 Skill 对应的工具升级了、API 变了、团队规范改了，旧的 SKILL.md 就成了「权威的错误」。

### 4.1 三层时效

| 层级 | 内容 | 时效性 | 检查方式 |
|------|------|--------|---------|
| 官方 Skills | Anthropic 维护的 doc-coauthoring、mcp-builder 等 | 跟随上游仓库更新 | `git pull` 检查 |
| 团队 Skills | 团队沉淀的规范和流程 | 随项目演进更新 | 与 CLAUDE.md 同步 review |
| 个人 Skills | 个人偏好和快捷指令 | 自己维护 | 使用频率统计 + 废弃提示 |

### 4.2 时效性元信息

```yaml
---
name: api-gateway-deploy
namespace: team/backend
last_verified: "2026-06-15"
stale_after_days: 30
source_repo: "https://github.com/team/backend-skills"
---

skill 内容...
```

类似记忆系统的 `<system-reminder>This memory was saved N days ago</system-reminder>`，超过 `stale_after_days` 的 Skill 在加载时自动附带提示。

---

## 五、依赖式引入：`@include` 级联加载——编程式的按需关联

检索式发现解决的是「模型不知道有哪些 Skill 时如何发现」。但还有另一条路径：**Skill 之间本就有明确的组合/依赖关系，不需要「搜索」，只需要「声明」。**

这和 C 语言的 `#include`、Python 的 `import` 完全同构——父 Skill 声明依赖，依赖只在父 Skill 被激活时才级联加载。

### 5.1 现有基础：CLAUDE.md 的 `@include`

CLAUDE.md 中已经实现了这个机制：

```
@~/company/security-rules.md
```

加载时自动读取目标文件内容拼入，同时有防循环引用和防路径遍历的工程保护。Skills 可以直接复用同一套语法和实现。

### 5.2 Skill 依赖声明

```yaml
# skills/data-pipeline-deploy/SKILL.md
---
name: data-pipeline-deploy
description: 数据管道部署流程
includes:
  - @skills/shared/docker-build       # 必选依赖
  - @skills/shared/k8s-apply          # 必选依赖
  - @skills/team/secret-management    # 必选依赖
optional_includes:
  - @skills/team/slack-notify         # 可选：有就加载，没有也不报错
---
```

**效果**：

```
System prompt（始终加载，30 token）：
  "data-pipeline-deploy — 数据管道部署流程"

模型选中 data-pipeline-deploy 后（级联自动展开）：
  Level 1: data-pipeline-deploy 元信息
  Level 2: 检测 includes → 自动加载 docker-build + k8s-apply + secret-management
  Level 3: 需要具体文件时按需读取
```

模型只需要知道父 Skill 的存在（30 token），三个子 Skill 的元信息根本不在 system prompt 里——只在被需要时才出现。

### 5.3 与检索式发现的对比

| 维度 | 检索式发现 | 依赖式引入 |
|------|-----------|-----------|
| 触发方式 | 模型调用 search_skills(query) | Skill 声明 includes 字段 |
| 关系类型 | 语义相似（动态） | 组合/依赖（静态，声明时确定） |
| 适合场景 | 「这个任务大概需要哪些 Skill」 | 「Skill A 的执行一定需要 Skill B/C」 |
| 模型开销 | 一次 LLM 调用做选择题 | 零——纯规则级联 |
| 典型例子 | 模型自己判断部署任务需要 docker-build | data-pipeline-deploy 声明依赖 docker-build |

两者互补，不是互斥：

```
1000 个 Skill
  │
  ├── 有明确依赖关系的（~60%）
  │     → 依赖式引入，父 Skill 激活时级联加载
  │     → system prompt 只列父 Skill，子 Skill 隐形
  │
  └── 独立/无预设关系的（~40%）
        → 检索式发现，按需搜索
        → search_skills(query) 返回 top-5
```

### 5.4 依赖树的 token 节省计算

假设 1000 个 Skill 中有 600 个是子 Skill（被其他 Skill 依赖），只有 400 个是顶层入口：

```
全部列出：1000 × 30 = 30000 token
只列顶层：400 × 30 = 12000 token
  → 省 18000 token（60%）
```

而 12000 token 仍然偏多——再加上检索式发现（search_skills），只返回 top-5，就只有 150 token。

**两条路径叠加后的效果**：

```
System prompt 中 Skill 相关开销：
  search_skills 工具声明：30 token
  + depends_on/include 依赖解析引擎：0 token（纯规则引擎）
  = 30 token（vs 原始方案的 30000 token）
```

### 5.5 自建 Agent 实现

```python
class SkillLoader:
    def __init__(self, registry):
        self.registry = registry  # 所有 skill 的索引
        self.loaded = set()       # 已加载的 skill（防循环）

    def load(self, skill_name: str, depth: int = 0) -> list:
        """加载一个 skill 及其依赖链"""
        if depth > 5:
            raise CircularDependencyError(f"Max depth exceeded at {skill_name}")
        if skill_name in self.loaded:
            return []  # 已加载，跳过（防循环）

        skill = self.registry.get(skill_name)
        if not skill:
            return []

        self.loaded.add(skill_name)
        loaded = [skill.content]

        # 级联加载依赖
        for dep in skill.includes or []:
            loaded.extend(self.load(dep, depth + 1))

        # 可选依赖：有就加载，没有跳过
        for opt_dep in skill.optional_includes or []:
            try:
                loaded.extend(self.load(opt_dep, depth + 1))
            except SkillNotFound:
                pass

        return loaded
```

---

## 六、完整架构（双路径：依赖声明 + 检索发现）

```
┌─────────────────────────────────────────────────┐
│              Skill Registry（注册中心）              │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐           │
│  │ frontend│  │ backend │  │ shared  │  ← 命名空间 │
│  │  ·react │  │  ·go    │  │  ·docker│           │
│  │  ·vue   │  │  ·db    │  │  ·k8s   │           │
│  │  ·css   │  │  ·api   │  │  ·secret│           │
│  └─────────┘  └─────────┘  └─────────┘           │
│                                                   │
│  每条 skill 声明 includes / optional_includes     │
└──────────────────┬──────────────────────────────┘
                   │
          ┌────────▼────────┐
          │  两条路径并行     │
          └────────┬────────┘
                   │
    ┌──────────────┴──────────────┐
    │                             │
    ▼                             ▼
┌───────────────┐          ┌───────────────┐
│ 路径 A: 依赖   │          │ 路径 B: 检索   │
│ @include 级联  │          │ search_skills │
│               │          │               │
│ 父 Skill 激活  │          │ Stage 0:      │
│ → 依赖链自动   │          │ 规则前置过滤   │
│   级联加载     │          │ (零 token)    │
│               │          │      ↓        │
│ 开销：0 token │          │ Stage 1:      │
│ (纯规则引擎)   │          │ 检索          │
│               │          │ (token 可控)  │
│ 适合：明确组合 │          │      ↓        │
│ 关系的 skill   │          │ 适合：独立/无  │
│               │          │ 预设关系      │
└───────┬───────┘          └───────┬───────┘
        │                          │
        └──────────┬───────────────┘
                   ▼
┌─────────────────────────────────────────────────┐
│     Stage 2: 渐进式披露（只有命中的进入 context）     │
│  · Level 1: name + description（每人一行）         │
│  · Level 2: 选中后才加载完整 SKILL.md             │
│  · Level 3: @include 的具体文件按需读取            │
│  · 防循环引用、防路径遍历                          │
└─────────────────────────────────────────────────┘
```

### 两条路径的 token 效果

| 阶段 | 全部列出 | 只列顶层 + 检索 | 顶层 + 检索 + 依赖链 |
|------|---------|---------------|-------------------|
| 100 Skill | 3000 | 150（top-5 结果） | 30（search_skills 工具声明） |
| 1000 Skill | 30000 | 150（top-5 结果） | 30 + 子 Skill 自动级联 |
| 瓶颈 | system prompt 被淹没 | LLM 选择器候选池 | 无——规模完全解耦 |

---

## 七、与现有 Claude Code 机制的对应

| 框架组件 | Claude Code 已有实现 |
|---------|-------------------|
| 命名空间隔离 | CLAUDE.md 六层级（Managed/User/Project/Local/Auto/Team） |
| 依赖链级联加载 | `@include` 指令（防循环引用 + 防路径遍历） |
| 条件匹配 | `.claude/rules/` 的 `paths` glob 匹配 |
| 小模型选择 | Sonnet 从 MEMORY.md 索引选 top-5 记忆 |
| Stale 管理 | `<system-reminder>` 2 天 stale 警告 |
| 去重过滤 | `alreadySurfaced` + `recentTools` 过滤 |
| 渐进式披露 | Skills 三级加载（元信息 → SKILL.md → 具体文件） |

**七个机制，每一个都已在 Claude Code 中运行。** 当前 Skill 数量还小，这些机制主要用在记忆系统和 CLAUDE.md 上——当 Skill 数量增长时，同样的模式可以直接平移。

---

## 八、迁移路径：从 10 到 5000

```
Phase 1（当前：10-50 个 skill）
  → 渐进式披露完全够用，所有 skill 元信息一行一个
  → 任务：无

Phase 2（增长到 100-300 个 skill）
  → 加命名空间 + 条件过滤 + @include 依赖声明
  → 把共享 skill 抽成依赖，顶层 skill 声明 includes
  → system prompt 只列顶层入口，子 Skill 隐形
  → 任务：给 skill 补 namespace/paths/includes frontmatter

Phase 3（增长到 500-1000 个 skill）
  → 加检索式发现（search_skills 工具）
  → system prompt 中不列 skill 列表，只给搜索工具 + 依赖解析引擎
  → 任务：实现 search_skills + 小模型选择器

Phase 4（增长到 5000+ 个 skill）
  → 两阶段检索（向量粗筛 + LLM 精排）
  → 加 stale 管理和废弃检测
  → 任务：建向量索引 + 时效性检查
```

核心原则不变：**任何时刻 context 里只放当前这一步真正用得上的部分。** 对文档成立、对记忆成立、对 Skill 成立——依赖声明和检索发现是这条原则在 Skill 管理上的两种互补实现。
