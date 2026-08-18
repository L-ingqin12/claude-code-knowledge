---
title: DSH 跨框架 Skills/MCP 加载指南
aliases: [DSH加载外部技能, dsh-bridges, DSH MCP 配置]
tags: [ai/agent, ai/skills, ai/links]
created: 2026-08-17
updated: 2026-08-17
status: review
---

# DSH 跨框架 Skills/MCP 加载指南

See also: [[AI-Links-KB-Home]] | [[2026-08-16-AI链接综述与归档]] | [[DSH-TUI插件使用手册]] | [[AGENTS]]

> [!abstract] 概述
> DeepSeek Harness（DSH）加载外部生态的 Agent Skills / MCP 有三条路径：**原生文件系统发现**（`.dsh/skills`、`.agents/skills`）、**原生 MCP 客户端插件**（`@deepseek-ai/dsh-mcp-client`）、以及社区桥接插件 **[dsh-bridges](https://github.com/yhlooo/dsh-bridges)**（把 Claude Code / CodeBuddy / OpenCode / Codex / Pi / Gemini CLI / Cursor 项目的技能、记忆、hooks、权限与 MCP 原样桥接进来，免迁移）。
> 依据官方仓库（deepseek-ai/deepseek-harness, dsh 0.1.0-rc 线）与 dsh-bridges 文档整理，2026-08 快照。

## 一、原生 Skill 发现（零配置）

DSH 的 skill 能力族（`dsh-skill` / `dsh-skill-filesystem` / `dsh-tool-skill`）从本地文件系统自动发现技能，模型通过 `skill` 工具加载。发现优先级（rank 小者优先，重名时近层胜出）：

| Rank | 来源 | 根目录 |
|---|---|---|
| 100 | 项目级 DSH | `<projectRoot>/.dsh/skills` |
| 200 | 项目级 agents 约定 | `<projectRoot>/.agents/skills` |
| 300 | 自定义 | `Config.customSkillDirs` |
| 400 | 用户级 DSH | `<dshHome>/skills` |
| 500 | 用户级 agents 约定 | `<agentsHome>/skills` |
| 600 | 随包内置 | `Config.bundledSkillDir` |

- **格式**：目录包 `<name>/SKILL.md` 或扁平文件 `<name>.md`；名称 kebab-case（`^[a-z0-9]+(?:-[a-z0-9]+)*$`）；不支持嵌套递归 `**/SKILL.md`。
- **项目根** = 向上最近的含 `.git` 目录；watcher 热更新，改技能无需重启会话。
- 模型目录里只暴露 `name` + `description`，正文通过 `skill` 工具按需加载。

> [!tip] 含义：遵循 Claude Code 约定的 `.agents/skills` 目录（Codex 风格）在 DSH 里**原生可用**——把技能目录放到项目或用户 agents 根即可，无需任何插件。

## 二、原生 MCP 客户端（mcp-client）

`@deepseek-ai/dsh-mcp-client` 把外部 MCP 服务器工具注册进 `ctx.tools`，模型看到 `mcp__<serverName>__<rawName>` 形式（与 Claude Code / Codex 相同的服务器限定命名）。在 profile 的 `cordis.yml` / 补丁层中每服务器一个实例：

```yaml
- id: mcp-github
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: github
    transport: stdio            # 或 streamable-http
    command: npx
    args: ['-y', '@modelcontextprotocol/server-github']
    env:
      GITHUB_TOKEN: !!js process.env.GITHUB_TOKEN

- id: mcp-web
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: web
    transport: streamable-http
    url: http://localhost:3000/mcp
```

| 关键字段 | 说明 |
|---|---|
| `transport` | `stdio`（spawn 命令）或 `streamable-http`（远程 URL） |
| `serverName` | 工具命名空间，`[A-Za-z0-9_-]{1,32}` |
| `command` / `args` / `env` / `cwd` | stdio 传输用 |
| `url` / `headers` | HTTP 传输用（认证头） |
| `toolCallTimeoutMs` | 单次调用超时，默认 60000 |
| `failOnStartupError` | 启动失败是否拒绝激活，默认 false（静默降级） |
| `reconnect.*` | 自动重连：指数退避（初始 500ms 翻倍，上限 30s，连续 10 次放弃） |

行为要点：热更新（改配置即断连重连，`serverName` 不变则工具名不变）；`notifications/tools/list_changed` 自动重同步；命名冲突/重复 serverName 会报错回滚。
限制：**只桥接工具能力**，MCP 的 resources/prompts 暂不支持。

## 三、dsh-bridges：跨框架免迁移桥接（重点）

[dsh-bridges](https://github.com/yhlooo/dsh-bridges)（npm 同名包）是一个 DSH 插件：在**已为其他 Agent 配置过的项目**里，把现有 skills、commands、memory、hooks、权限与 MCP 原样桥接进 DSH，无需迁移任何文件。

### 3.1 安装与验证

```sh
dsh plugin --profile <profile-name> add dsh-bridges   # web 或 headless profile
dsh web                                               # 或 dsh --profile <profile-name>
dsh --profile <profile-name> --dump-config            # 应出现 dsh-bridges 行
```

headless（一次性 CLI）同样支持：`dsh plugin --profile headless add dsh-bridges` 后在项目目录 `dsh --profile headless "list the skills available in your catalog"`。从仓库安装：`pnpm install && pnpm build && dsh plugin --profile <p> add .`。

### 3.2 支持矩阵

资产按会话工作区发现（项目级 + 用户级位置），全部桥默认开启，可在补丁层按工具开关/配置：

| Agent 工具 | Skills/commands | Memory | Hooks | Permissions | MCP |
|---|---|---|---|---|---|
| Claude Code | ✓ | ✓ | ✓ | ✓ | ✓ |
| CodeBuddy Code | ✓ | ✓ | ✓ | ✓ | ✓ |
| **OpenCode** | ✓ | ✓ | — | ✓ | ✓ |
| Codex | ✓ | ✓ | ✓ | ✓ | ✓ |
| Pi | ✓ | ✓ | — | — | — |
| Gemini CLI | ✓ | ✓ | ✓ | ✓ | ✓ |
| Cursor | ✓ | ✓ | ✓ | ✓ | ✓ |

### 3.3 配置（补丁层覆盖）

```yaml
# 例：禁用 Pi 桥 / 关闭 Claude Code 桥
- id: bridges
  config:
    pi:
      enabled: false
```

### 3.4 OpenCode 桥接细节（示例）

- **Skills/commands**：读取 `.opencode/skills/<name>/SKILL.md`、`.opencode/commands/<name>.md`、`opencode.json(c)` 的 `command.<name>`，注册到 DSH skill 注册表（provider `opencode`），出现在模型技能目录、经 `skill` 工具加载、可用 `/name` 调用。目录**向上**发现到 git root；`skills.paths` 增加额外根；名称须合法（小写字母数字+单连字符），frontmatter 需 `name`（等于目录名）+ `description`（1-1024 字符）；`agent.<id>`（subagent/all 模式）转成 delegation-spec 技能。
- **Memory**：注入 `~/.config/opencode/AGENTS.md`（缺省回退 `~/.claude/CLAUDE.md`）、向上最近的 `AGENTS.md`、`instructions` 文件与 glob、`references` 的 `@alias`；预算 32 KiB（宽泛的用户级先裁，具体的最先截断）；远程 URL/git 引用不抓取。
- **Permissions**：读 `opencode.json(c)` 的 `permission`（bare 字符串或按 family 的对象，last-match 规则），在 `tools/pre-execute` 缝上执行；工具族映射 `read/edit/write→edit、bash→bash、subagent→task、web_search→websearch` 等；未映射工具（todo、MCP 工具等）回退 DSH 自身审批策略；未配置 permission 时桥完全让路。
- **MCP**：`opencode.json(c)` 的 `mcp` 条目桥为 `mcp__opencode__<server>__<tool>`：`type:"local"` → stdio（command 数组 + environment），`type:"remote"` → streamable-http（url + headers）；启动失败 fail open。
- **不桥接**：hooks（OpenCode 无此配置）、JS 插件系统与自定义工具（需要 OpenCode 运行时）、`$ARGUMENTS`/`@file` 模板替换、`skills.urls`（网络）、`agent/model/subtask` 命令选项、远程 config 层、provider/model 路由等。

### 3.5 所有桥的通用行为

- **原生技能优先**：重名时原生 DSH 技能（`.dsh/skills`、`.agents/skills`、runtime）遮蔽桥接资产。
- **32 KiB 记忆预算**：每桥独立，用户级宽泛段落先被裁。
- **热更新**：技能根与配置文件被 watch，会话内即时生效。
- **工具名翻译**：上游 hook 写的工具名自动翻译为 DSH 名，hooks 原样可用。
- **Fail open**：hook 超时/失败不阻塞动作（Cursor 的 `failClosed: true` 是唯一例外）。

## 四、实操速查

```sh
# 原生：把 skill 放进这些目录即可被模型看见
<project>/.dsh/skills/<name>/SKILL.md     # rank 100
<project>/.agents/skills/<name>/SKILL.md  # rank 200（Codex 约定）
~/.dsh/skills/…                           # rank 400

# 原生 MCP：profile 补丁（cordis.patch.yml）加 mcp-client 实例

# 跨框架：装桥接插件
dsh plugin --profile web add dsh-bridges
dsh web
dsh --profile web --dump-config | grep -A2 bridges
```

## 五、与本机环境的对应

- 本机 profiles：`web`（dsh-base + dsh-web-app）、`tui`（[[DSH-TUI插件使用手册]]）。
- dsh CLI v0.1.0-rc.6；配套 Node 22.21（`C:\Users\28064\nodejs-x64\node-v22.21.0-win-x64\`），系统 PATH 里的 node 仍是 v18（TUI 需要 ^22.19，勿混用）。
- 与 [[2026-08-16-AI链接综述与归档]] 的关联：#1 antigravity-awesome-skills（1900+ 技能聚合）、#6 i-have-adhd（SKILL.md 最小样本）、#14/#15 图表技能，均可在 DSH 中以原生 skill 或 bridges 方式使用。

> [!warning] 时效性
> dsh-bridges 与官方 rc 线仍在快速迭代，矩阵与字段以上游最新文档为准；本文为 2026-08 快照。

## Related

- [[2026-08-16-AI链接综述与归档]] — 16 链接综述（技能生态条目）
- [[DSH-TUI插件使用手册]] — 本机 TUI 插件手册
- [[TYPORA-KB-Home]] — Skills 打包机制对照（typora-activation）
- [[AGENTS]] — 知识库规范
