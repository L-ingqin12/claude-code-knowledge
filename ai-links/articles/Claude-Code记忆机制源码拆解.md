---
title: "Claude Code 记忆机制源码级拆解"
aliases: [CLAUDE.md记忆机制, Memory机制拆解, Claude Code记忆系统]
tags: [ai/agent, ai/learning]
created: 2026-06-02
updated: 2026-08-17
status: stable
source: "微信公众号"
source_url: "https://mp.weixin.qq.com/s/CLIuogpYSPng2brQph7AHg"
author: "小林coding"
date: "2026-06-02"
fetched_at: "2026-06-22"
---

# Claude Code 记忆机制源码级拆解

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[上下文工程落地实践-从理论到Claude-Code实现]] | [[Skill规模化管理-从渐进式披露到检索式发现]] | [[Agent韧性架构分析-微信转载]]

## 摘要

Claude Code 的记忆机制分两层并行工作：（1）**静态层**——CLAUDE.md 六层级声明式指令体系，叠加 @include 引用和条件规则的按需注入；（2）**动态层**——自动记忆系统，在每轮对话结束后由后台 ExtractMemories 代理抽取用户画像/行为偏好/项目动态/外部指针四类信息，落盘为结构化 markdown 文件，下次会话由 Sonnet 从 MEMORY.md 索引中选 top-5 注入上下文，2 天以上的记忆主动加 stale 警告并强制模型验证。

**核心反直觉设计**：不用向量数据库、不用 embedding，全用磁盘上的 markdown 文件 + LLM 做选择器。索引常驻（始终在 system prompt）、内容按需加载。四条可迁移原则：结构化优于自由文本、索引常驻+内容按需、小模型做选择题优于向量检索、时间感知+主动验证。

---

## 一、LLM 是无状态的——记忆幻觉的真相

LLM 本身无状态。每次对话，客户端把 system prompt + 全部历史 + 当前问题一起发送。模型看起来「记得」，是客户端偷偷重发了历史——这属于**短期记忆**（上下文窗口）。聊天场景每轮几百 token 能撑住，agent 场景几十轮 tool call 立即爆窗口。

Agent 真正需要的**长期记忆**（跨会话持久化）是四类：

| 类型 | 内容 | 示例 |
|------|------|------|
| 用户画像 | 用户是谁、擅长什么 | 「十年 Go 后端，刚接触 React」 |
| 行为偏好 | 用户喜欢/不喜欢什么 | 「不要用 mock，连真实数据库」 |
| 项目动态 | 项目正在发生什么 | 「移动端 3 月 5 号合并冻结」 |
| 外部指针 | 去哪查什么信息 | 「pipeline bug 在 Linear 的 INGEST 项目追踪」 |

类比：LLM 是失忆的实习生——聪明但每天从零开始。记忆机制 = 工位上的便签：贴在哪、谁来贴、什么时候撕。

---

## 二、四种主流方案及其共同病根

| 方案 | 原理 | 硬伤 |
|------|------|------|
| 滑动窗口 | 保留最近 N 轮，超出的丢弃 | 关键信息随旧消息一起被砍 |
| 对话摘要 | LLM 定期摘要旧对话塞回上下文 | 摘要压糊重要细节（"Kong 不是 nginx"→"技术栈细节"） |
| 向量检索（最热） | embedding → 向量数据库 → top-K 召回 | 相似≠相关；embedding 模型换一个全崩；用户无法看懂存储内容 |
| 分层存储 | core/recall/archival 三层，LLM 主动搬数据 | 搬数据依据仍是 embedding 召回，硬伤一个不少 |

**共同病根**：自由文本无约束、不区分类型、无老化机制、重检索轻写入。

---

## 三、Claude Code 的两层架构

### 静态层：CLAUDE.md 六层级

六种来源的规则，可见范围和修改权限不同，拆成独立层级：

| 层级 | 位置 | 管理者 | 用途 |
|------|------|--------|------|
| Managed | 系统路径 | 仅管理员 | 公司强制策略 |
| User | 家目录 | 用户本人 | 全局偏好，跨项目生效 |
| Project | 项目根目录 CLAUDE.md | Git 团队共享 | 项目级约定 |
| Local | CLAUDE.local.md | 用户本人 | 本地调试约定，不签入 git |
| Auto | 项目自动记忆目录 | Claude 自动写入 | 对话中学习的偏好 |
| Team | Auto/team/ | 团队共享 | 团队积累的 AI 经验（需 feature flag） |

六层是**叠加关系**（非覆盖），启动时全部拼进 system prompt。

**子机制一：`@include`**——CLAUDE.md 中用 `@~/company/security-rules.md` 引用其他文件，类似 C 的 `#include`。防循环引用、防路径遍历。

**子机制二：条件规则**——`.claude/rules/` 下每条规则用 frontmatter 中的 `paths` glob 字段匹配当前编辑文件，匹配才注入。一个项目可定义几十条规则，每条只在需要时占用 token。

**子机制三：截断双保险**——MEMORY.md 索引同时受 `MAX_ENTRYPOINT_LINES = 200` 和 `MAX_ENTRYPOINT_BYTES = 25000` 限制，防「长行索引炸弹」（极端案例：197KB 不到 200 行）。

### 动态层：自动记忆系统闭环

#### 类型约束

只允许四种类型，强制 agent 写前做分类决策：

```typescript
export const MEMORY_TYPES = ['user', 'feedback', 'project', 'reference'] as const
```

`feedback` 和 `project` 有强制结构：正文 + **Why:**（为什么）+ **How to apply:**（何时生效）。只记规则不记原因，边界情况无法判断。

`project` 额外要求：相对日期转绝对日期（「周四前冻结」→「2026-03-05 前冻结」）。

**不该存清单**：代码模式/架构/路径（grep/CLAUDE.md 能推出来）、Git 历史（git log 是权威）、调试修复方案（已在 commit 中）、CLAUDE.md 已有内容、临时任务状态。纪律：**只记代码推不出来的东西。**

#### 存储：索引常驻 + 内容按需

每条记忆一个独立 `.md` 文件，YAML frontmatter 存 `name`/`description`/`type`。目录内一个 `MEMORY.md` 索引文件列出所有记忆的 name+description。

`MEMORY.md` → 始终加载进 system prompt（让模型知道有什么可用）  
独立记忆文件 → 真正需要时才加载完整正文

#### 写入：Extract Memories 后台代理

每轮 query loop 结束后通过 stopHook 触发，fork 主对话（复用 prompt cache 而非重新加载 system prompt）。逻辑：扫对话历史 → 与现有记忆比对去重 → 四类型分类 → 写入新文件。

#### 检索：Sonnet 做选择题，不用向量检索

1. 扫描所有记忆文件前 30 行提取 frontmatter
2. 标题清单发给 Sonnet：「用户当前问题如下，哪些相关？不确定就别选」
3. Sonnet 用 JSON schema 返回 top-5 文件名

两道过滤：`alreadySurfaced`（上轮已出现的排除）、`recentTools`（正在用的工具文档排除，但工具的坑点保留）。

选择 Sonnet 而非 Haiku：记忆判错的代价（污染整条回复）>> 多花的 token 成本。

#### 注入与老化

```xml
<system-reminder>
This memory was saved 5 days ago. Verify it's still accurate before acting on it.
[记忆内容]
</system-reminder>
```

今天/昨天 → 不警告；2 天以上 → stale 警告。附加验证提示：「记忆说文件在路径 X，先检查文件是否存在」「记忆说函数叫 Y，先 grep 一下」——记忆不是真理，是历史快照。

---

## 四、可迁移的设计原则

| 原则 | 内容 | 迁移方法 |
|------|------|----------|
| 结构化优于自由文本 | 强制类型 + frontmatter 约束 | 给记忆定 schema，哪怕 4 个字段也比无约束强 |
| 索引常驻 + 内容按需 | 索引始终在 system prompt，内容按需加载 | 适用于任何「总量大但只需少数展开」的场景 |
| 小模型做选择题 | 检索 = 自然语言判断，不是相似度数值 | 候选集 < 几百时，小模型选 > 向量检索 |
| 时间感知 + 主动验证 | 2 天 stale 警告，用前 grep 验证 | 记忆不是 ground truth，是历史快照 |

核心哲学：不堆复杂度，用文件系统 + LLM 组合出比向量检索更好用的系统。
