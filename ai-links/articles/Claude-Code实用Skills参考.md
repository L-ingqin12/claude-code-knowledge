---
title: "Claude Code 实用 Skills 参考"
aliases: [Claude Code Skills, 实用Skills清单, 小金AI Skills]
tags: [ai/skills, ai/learning]
created: 2026-06-17
updated: 2026-08-17
status: stable
source: "微信公众号"
source_url: "https://mp.weixin.qq.com/s/gRzmPovqR3ygTDuxkMX-4w"
author: "小金AI"
date: "2026-06-17"
fetched_at: "2026-06-22"
---

# 10 个 Claude Code 实用 Skills 参考

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[Anthropic-Skill系统深度分析]] | [[Skill规模化管理-从渐进式披露到检索式发现]] | [[上下文工程落地实践-从理论到Claude-Code实现]]

## 摘要

覆盖开发全流程的 10 个 Skills：Superpowers（TDD+Code Review 流程约束）、Everything Claude Code（多 Agent 分工防上下文腐化）、Doc Co-Authoring（PRD/技术方案协作写作）、UI UX Pro Max（设计系统生成）、sanyuan-skills（多维度代码审查）、Web Access（CDP 浏览器自动化）、Webapp Testing（Playwright 本地验收）、MCP Builder（内部 API→Agent 工具封装）、Claude API（SDK/流式/缓存参考）、skill-creator（元技能创建工具）。

核心原则：Superpowers 和 sanyuan-skills 兜底开发流程与代码质量；Webapp Testing 补前端验收；MCP Builder 和 skill-creator 面向团队工具化。按需选取，不必全装。

---

## 技能清单

### 1. Superpowers — 开发流程约束

将需求澄清、方案拆解、Git Worktree、TDD、Code Review、调试、完成前验证固化为 Skills，让 AI 按固定步骤执行。

| 技能 | 触发 | 功能 |
|------|------|------|
| brainstorming | `/superpowers:brainstorm` | 追问目标/约束/边界 → 设计文档 |
| using-git-worktrees | 自动 | 独立 Git worktree 隔离任务 |
| writing-plans | 自动 | 拆成 2-5 分钟粒度小任务 |
| test-driven-development | 自动 | 红-绿-重构，先补测试再补实现 |
| subagent-driven-development | 自动 | 独立子 Agent 执行，事后检查 |
| code-review | 自动 | 合入前第二轮质量检查 |
| systematic-debugging | 触发式 | 分阶段定位问题来源 |
| verification-before-completion | 自动 | 无测试/日志/命令输出则不能宣布完成 |

安装：`/plugin marketplace add obra/superpowers-marketplace` → `/plugin install superpowers@superpowers-marketplace`

仓库：[github.com/obra/superpowers](https://github.com/obra/superpowers)

### 2. Everything Claude Code — 多 Agent 分工

将 Claude Code 工作拆到 Agents/Skills/Hooks/Rules/Commands 五类配置中，对抗长任务上下文腐化。

- Agents：规划、架构、TDD、审查分别交给不同子 Agent
- Skills：沉淀可复用工作流（测试优先、后端规范等）
- Hooks：关键节点自动检查（提交前扫调试日志）
- Rules：团队/个人长期生效的编码规则
- Commands：`/tdd`、`/code-review` 等快捷触发

仓库：[github.com/affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code)

### 3. Doc Co-Authoring — 需求文档协作

编码前使用，将模糊需求整理为 PRD、技术方案、决策文档、RFC。

三阶段流程：
1. Context Gathering — 收集背景、约束、历史讨论、架构依赖
2. Refinement & Structure — 按章节打磨：提问→展开→筛选→成段
3. Reader Testing — 换全新上下文 Claude 读文档，检查遗漏和误解

安装：`/plugin marketplace add anthropics/skills` → `/plugin install example-skills@anthropic-agent-skills`

仓库：[github.com/anthropics/skills](https://github.com/anthropics/skills)

### 4. UI UX Pro Max — 设计系统生成

根据产品类型和行业特性自动输出完整设计系统（Design System）。

内置知识库：67 种 UI 风格、161 个行业色板、57 种字体搭配、161 条推理规则、99 条 UX 准则、13 种技术栈。

安装：`/plugin marketplace add nextlevelbuilder/ui-ux-pro-max-skill` → `/plugin install ui-ux-pro-max@ui-ux-pro-max-skill`

替代方案：Anthropic 官方 `frontend-design` skill，轻量级，专注避免 AI 生成的套路美学。

仓库：[github.com/nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)

### 5. sanyuan-skills — 多维度代码审查

三个核心技能：

| 技能 | 功能 |
|------|------|
| Code Review Expert | SOLID/安全/性能/错误处理/边界条件/代码质量审查 |
| Sigma | 基于 Bloom's 2-Sigma 理论的苏格拉底式 AI 导师 |
| Skill Forge | 元技能，内置 12 种实战技术用于创建新 Skill |

安装：`npx skills add sanyuan0704/sanyuan-skills --path skills/code-review-expert`

仓库：[github.com/sanyuan0704/sanyuan-skills](https://github.com/sanyuan0704/sanyuan-skills)

### 6. Web Access — 浏览器自动化

补足 Claude Code 自带 WebSearch/WebFetch 的编排和浏览器自动化缺口。

能力：自动工具选择（WebSearch/WebFetch/curl/Jina/CDP）、CDP 直连 Chrome 携带登录态、并行分治多目标、站点经验跨会话积累、DOM 边界穿透（Shadow DOM/iframe）。

前置条件：Node.js 22+，Chrome 开启远程调试（`chrome://inspect/#remote-debugging`）。

安装：`git clone https://github.com/eze-is/web-access ~/.claude/skills/web-access`

仓库：[github.com/eze-is/web-access](https://github.com/eze-is/web-access)

### 7. Webapp Testing — 本地前端验收

基于 Playwright 的本地 Web 应用交互测试。

能力：服务生命周期管理（自动启停）、networkidle 后 DOM 检查、截图与控制台日志捕获、元素发现→可靠选择器。

典型用法：AI 写完管理后台页面后，打开 `localhost:5173`，检查按钮/表单/弹窗/暗色模式/移动端布局。

仓库：[github.com/anthropics/skills](https://github.com/anthropics/skills)

### 8. MCP Builder — 内部 API 封装

指导构建 MCP Server，将内部 API 封装为 Agent 可调用工具。覆盖 Python FastMCP 和 Node/TypeScript MCP SDK。

适用场景：OpenAPI→MCP 工具、数据库受控查询、部署/日志/告警平台动作封装、团队 Agent 工具层沉淀。

仓库：[github.com/anthropics/skills](https://github.com/anthropics/skills)

### 9. Claude API — SDK 开发参考

覆盖模型选择、价格、参数、流式输出、工具调用、MCP、Agent、缓存、Token 计算、模型迁移。支持 Python/TypeScript/Java/Go/Ruby/PHP/C#/cURL。

核心约束：「先查文档再写代码」——遇到 SDK 方法名、参数、流式事件时禁止凭印象写。

仓库：[github.com/anthropics/skills](https://github.com/anthropics/skills)

### 10. skill-creator — 元技能

创建、修改、优化 Skill 的开发工具。

工作流：意图捕获 → 起草 SKILL.md → 测试验证（有 Skill vs 无 Skill 对比实验）→ 迭代优化 → description 优化。

内置可视化评测报告系统。

仓库：[github.com/anthropics/skills](https://github.com/anthropics/skills)

---

## 选取建议

| 场景 | 推荐 |
|------|------|
| 通用开发流程 | Superpowers |
| 多角色长任务 | Everything Claude Code |
| 需求文档化 | Doc Co-Authoring |
| UI 设计 | UI UX Pro Max（重）/ frontend-design（轻） |
| 代码审查 | sanyuan-skills |
| 网页操作 | Web Access |
| 本地前端验收 | Webapp Testing |
| 工具集成 | MCP Builder |
| API 开发 | Claude API |
| 自制 Skill | skill-creator |
