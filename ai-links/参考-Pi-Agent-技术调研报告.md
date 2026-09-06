---
title: 参考-Pi Agent 技术调研报告
aliases: [Pi Agent 调研报告, pi-mono 调研, pi-coding-agent-research, earendil-pi]
tags: [reference, ai/agent]
created: 2026-08-25
updated: 2026-08-26
status: review
source: 基于 web_search 多源交叉验证（pi.dev/GitHub/npm/CHANGELOG/DeepWiki/社区解析）；§11 为 npm 官方包 0.84.3 源码实机核验
fetched_at: 2026-08-25
---

# Pi Agent 技术调研报告（截至 2026-08）

> [!abstract] 调研对象：**pi** —— Mario Zechner（GitHub ID: badlogic，libGDX 作者）的 TypeScript AI 编码 Agent 工具链，原仓库 `badlogic/pi-mono`，2026 年被 Earendil 收购后迁至 `earendil-works/pi`，官网 pi.dev。[来源](http://pyshine.com/Pi-Mono-Full-Stack-AI-Agent-Toolkit/)、[来源](https://mariozechner.at/posts/2026-04-08-ive-sold-out/)、[来源](https://pi.dev/news/2026/5/7/pi-has-a-new-home)。本文所有事实句尾附来源 URL，不确定处标注**待确认**。
>
> **See also**: [[参考-OpenCode-技术调研报告]] · [[pi-agent-framework-knowledge]] · [[opencode-pi-base-development-analysis]] · [[main-subagent-realtime-interaction]] · [[AI-Dev-KB-Home]] · [[LLM-Agent开发基础]]

## 0. 同名混淆排除与调研口径

- 判断依据：任务描述的 monorepo 包清单（pi-ai / pi-agent-core / pi-tui / pi-web-ui / pi-proxy）与 npm 维护者信息（mario@badlogicgames）完全指向 badlogic 的 pi。[来源](https://apps.iu.edu/nxs-prd/content/groups/external-npm/@mariozechner/pi-ai/)
- 排除对象 1：Inflection AI 的消费级对话助手 "Pi"（无代码框架属性）。排除对象 2：npm 上大量无关同名/镜像包如 `@dannote/pi-agent`（见第 9 节供应链风险）。[来源](https://socket.dev/npm/package/@dannote%2Fpi-agent)
- ⚠️ 任务描述中的产品名 "LiblibPi" 未在公开检索中找到任何对应来源，公开资料中产品名即 "pi / Pi coding agent"——该名称**待确认**（疑为记忆偏差）。

## 1. 仓库结构、迁移史与定位

### 1.1 收购与迁移时间线

- 2026-04-08 作者发文《I've sold out》宣布项目被收购；2026-05-07 官方公告 "Pi has a new home"，仓库迁至 Earendil 组织。[来源](https://mariozechner.at/posts/2026-04-08-ive-sold-out/)、[来源](https://pi.dev/news/2026/5/7/pi-has-a-new-home)、[来源](https://devbytes.co.in/news/earendil-acquires-pi-the-minimal-agent-within-openclaw)
- npm 随之从 `@mariozechner/pi-*` 迁往 `@earendil-works/*`，旧作用域进入弃用流程（第三方安装器 changelog 明确记录移除旧包 deprecation 警告）。[来源](https://raw.githubusercontent.com/itayinbarr/little-coder/main/CHANGELOG.md)
- 收购后继续开源并运营 pi.dev，但商业化路线由 Earendil 主导。[来源](https://learnblockchain.cn/article/27092)

### 1.2 Monorepo 包职责矩阵

| 包 | npm 名 | 职责 | 来源 |
|---|---|---|---|
| packages/ai | …/pi-ai | 统一 LLM API：多 provider、流式、工具调用 | [README](https://github.com/earendil-works/pi/blob/main/packages/ai/README.md) |
| packages/agent | …/pi-agent-core | Agent 核心循环与状态机 | [README](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md) |
| packages/coding-agent | …/pi-coding-agent | 编码 Agent CLI + SDK + 内置工具 + 扩展系统 | [docs 目录](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/docs) |
| packages/tui | …/pi-tui | 终端 UI 组件库（CLI 的 TUI 基于它） | [镜像文档](https://mintlify.wiki/pt-act/pi-mono/packages/tui) |
| packages/web-ui 等 | …/pi-web-ui | Web UI 库、Slack bot、vLLM pods 为旧 monorepo 时期产物 | [镜像文档](https://mintlify.wiki/pt-act/pi-mono/packages/web-ui)、[旧描述镜像](https://github.com/dannote/pi-mono) |

- 当前仓库自述收窄为 "AI agent toolkit: unified LLM API, agent loop, TUI, coding agent CLI"；web-ui/slack/pods 在新仓库的存续状态**待确认**。[来源](https://github-alan.17835411844.workers.dev/earendil-works/pi)、[来源](https://github.com/dannote/pi-mono)

### 1.3 定位哲学

- **刻意极简的 "coding harness"**：小内核 + 15+ LLM provider + 树状会话历史 + TypeScript 扩展系统，被评论称为 "harness rebellion"。[来源](https://openalternative.co/pi)、[来源](https://www.implicator.ai/pi-is-not-a-claude-code-rival-it-is-a-harness-rebellion/)
- 工业采用佐证：OpenClaw 将 pi 作为其 Agent 运行时内核（后进一步 internalize）。[来源](https://docs.openclaw.ai/agent-runtime-architecture)、[来源](https://github.com/openclaw/openclaw/pull/85341)

## 2. 库优先 SDK 嵌入模式（重点）

- **同一 Agent runtime 既驱动 CLI 也作为 npm 包进程内嵌入**，官方 SDK 入口 `const { session } = await createAgentSession({ resourceLoader })`；可传 `customcwd`（为其按需构建内置工具子集）、`sessionManager`、`additionalExtensionPaths`、`customTools` 等选项。[来源](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/docs/sdk.md)、[在线版](https://pi.dev/docs/latest/sdk)
- 导出的关键类型：`AuthStorage`、`createAgentSession`、`ModelRegistry`、`SessionManager`。[来源](https://socket.dev/npm/package/@simpletoolsindiaorg/ai-coding-agent)
- **三层 API 分层**：底层 `agentLoop`（纯循环）→ 中层 `Agent`（事件订阅）→ 高层 `AgentHarness`（完整托管封装）；事件粒度到 turn 级（如每轮完全结束后发 `turn_end`）。[来源](https://yuqingteck.blog.csdn.net/article/details/161451638)、[来源](https://github.com/earendil-works/pi/blob/main/packages/agent/src/types.ts)、[来源](https://deepwiki.com/earendil-works/pi/2.1-agent-loop-and-execution-engine)
- **消息结构**：role 化消息（assistant/user/toolResult），工具结果独立 role，会话 trace 带 id/parentId 树状链接。[来源](https://huggingface.co/datasets/JohnBeanerson/pi-mono-test/blob/main/2026-01-16T02-58-05-814Z_[已脱敏].jsonl)
- **工具定义**：`defineTool()` 定义类型安全契约（名称/描述/参数 schema/`execute` 回调，execute 可拿 abort signal），以 `customTools: [myTool]` 注入；参数 schema 用 zod 还是原生 JSON Schema **待确认 → ✅ 已解决：TypeBox TSchema（见 §11.1）**。[来源](https://raw.githubusercontent.com/earendil-works/pi/v0.80.0/packages/coding-agent/docs/sdk.md)
- **流式接口**：统一流式输出，事件流可直接对接 SSE 服务化场景。[来源](https://blog.frognew.com/2026/08/pi-sdk-lesson-02-events-and-sse.html)
- **运行形态**："一个 runtime、四种使用姿势"（交互 TUI / print 非交互 / RPC 或 JSON 事件流 headless / SDK 进程内嵌入，官方命名细节**待确认**）。[来源](https://kimigao.com/blog/pi-sdk-runtime/)、[来源](https://lobehub.com/skills/tangledgroup-tangled-skills-pi-mono-0-66-1)、[来源](https://www.cnblogs.com/znlgis/p/20959176)
- **与 CLI subprocess 方式的本质区别**：嵌入式下循环跑在业务 Node.js 进程内——共享内存、直接读写 session 对象、同步收结构化事件、函数调用注入工具/拦截事件；CLI/RPC 形态则隔着进程边界只能走 stdin/stdout JSON 协议，控制粒度与实时性低一档。[来源](https://www.cnblogs.com/znlgis/p/20959176)、[来源](https://deepwiki.com/agentic-dev-io/pi-agent/7-rpc-mode-and-headless-integration)

## 3. 会话与交互控制

- **会话存储**：JSONL 文件 + 树状结构（支持分支历史）；`pi --continue` 继续最近会话，另有 resume/tree 操作。[来源](https://socket.dev/npm/package/@vaayne/pi-coding-agent)、[sessions 文档](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md)、[在线版](https://pi.dev/docs/latest/sessions)
- **steer()/followUp() 双队列（标志性机制）**：原 `queueMessage()` 已拆分——`steer()` 把用户消息注入**当前正在执行的 turn**（模型本轮即可转向），`followUp()` 排队在**当前 turn 结束后**交付下一轮（PR #403）。[来源](https://github.com/earendil-works/pi/commit/93498737c04e7127714ceccc551f63a6d5059b85)、[CHANGELOG](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/CHANGELOG.md)、[中文机制解析](https://yuqingteck.blog.csdn.net/article/details/161452933)、[Steering 章节](https://www.cnblogs.com/znlgis/p/20966341)
- **中断/取消**：AbortSignal 贯穿 LLM 流与工具执行；后续补 `interrupt()` 实现"优雅 turn 中断"而非硬杀（PR #3197）。[来源](https://github.com/earendil-works/pi/pull/3197)
- **重试与恢复**：内置 provider 错误自动重试（行为边界见 issue #157；社区扩展 not-enough-retry 补齐非永久错误覆盖）；限流/token 上限自动恢复由社区扩展 pi-auto-resume 提供。[来源](https://github.com/earendil-works/pi/issues/157)、[来源](https://github.com/EnderLiquid/not-enough-retry)、[来源](https://github.com/kasaiarashi/pi-auto-resume)
- **上下文压缩**：内置 compaction（`/compact` 命令；压缩提交同样进队列排序，PR #476）。[来源](https://github.com/earendil-works/pi/pull/476)

## 4. 扩展点

- **TypeScript 扩展系统是主扩展机制**：注册自定义工具、斜杠命令、生命周期事件钩子（tool_call/tool_result 等）、自定义结果渲染 renderResult、改写 system prompt（回调返回 `{ systemPrompt: ... }` 即覆盖）。[来源](https://pi.dev/docs/latest/extensions)、[extensions 文档](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)、[Custom Tools & Event Hooks](https://deepwiki.com/badlogic/pi-mono/4.4.2-custom-tools-and-event-hooks)、[来源](https://github.com/tuansondinh/lsd/blob/HEAD/docs/architecture.md)
- **约定目录自动发现**：`extensions/`、`skills/`、`prompts/`、`themes/`。[来源](https://socket.dev/npm/package/@pie-lab/coding-agent)
- **Skills / Prompt 模板 / 上下文文件**：SKILL.md 技能体系 + prompt 模板 + AGENTS.md 类上下文文件（子目录上下文加载由社区扩展补充，反证根级加载为原生行为）。[来源](https://pi.dev/docs/latest/skills)、[DeepWiki](https://deepwiki.com/earendil-works/pi/8-skills-prompt-templates-and-context-files)、[来源](https://github.com/default-anton/pi-subdir-context)
- **MCP：内核不内置，走社区扩展**——0xKobold/pi-mcp 支持 stdio/SSE/StreamableHTTP/WebSocket 并映射 tools/resources/prompts，另有 tickernelz/pi-mcp-tools 等；是否已有官方一等支持**待确认**。[来源](https://github.com/0xKobold/pi-mcp)、[来源](https://github.com/tickernelz/pi-mcp-tools)
- **Provider/Model 切换**：ModelRegistry + models.json 自定义模型/供应商（任意 OpenAI 兼容端点→vLLM/Ollama 本地模型可接，v0.7.12 引入）；宣称 15+ providers。[来源](https://github.com/earendil-works/pi/commit/b2491aac2332a6f8cbfce3167d523ae22e3e3b1e)、[来源](https://openalternative.co/pi)

## 5. 内置工具集与权限模型

- **清单**：bash、read、write、edit 及 grep/find 类检索工具（官方文档按 `[bash]` `[edit]` 等逐工具成章；SDK 按 cwd 按需构建子集暗示可裁剪）；完整权威清单**待确认 → ✅ 已解决（见 §11.3：bash/read/write/edit/edit-diff/grep/find/ls/powershell）**。[来源](https://raw.githubusercontent.com/earendil-works/pi/v0.78.1/packages/coding-agent/docs/extensions.md)、[DeepWiki Built-in Tools](https://deepwiki.com/earendil-works/pi/2.4-built-in-tools)、[sdk.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)
- **权限模型：默认无审批弹窗、无沙箱，bash 直跑**——极简信任哲学，与 Claude Code/Codex 的 approval modes 形成鲜明对比。[来源](https://inventivehq.com/blog/ai-coding-cli-sandbox-approval-modes-compared)
- 安全加固交给扩展生态：@inobit/pi-permission、security-harness-pi、腾讯 CubeSandbox 官方集成指南（把 pi 关进沙箱跑）。[来源](https://www.npmjs.com/package/@inobit/pi-permission)、[来源](https://pi.dev/packages/@the-forge-flow/security-harness-pi?page=62)、[CubeSandbox × pi](https://raw.githubusercontent.com/TencentCloud/CubeSandbox/master/docs/guide/integrations/pi-agent.md)
- 系统提示词泄露件佐证其 harness 自述："You are an expert coding assistant operating inside pi, a coding agent harness"。[来源](https://github.com/asgeirtj/system_prompts_leaks/blob/main/Pi/instructions.md)

## 6. Windows 支持与已知坑

- 官方有专门 Windows 文档页（windows.md），属一等关注但历史坑较多。[来源](https://pi.dev/docs/latest/windows)、[仓库内文档](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/windows.md)
- **shell 兼容坑**：默认面向 bash；Windows 下曾因 `detached: true` 导致 pwsh.exe 作 shellPath 失效，PR #4013 移除修复；社区提供 PowerShell 7 方案 pi-pwsh-notify（后台作业完成自动通知）。[来源](https://github.com/earendil-works/pi/pull/4013)、[来源](https://github.com/oversk7/pi-pwsh-notify)
- **路径/引号坑**：PackageManager 在 Windows `shell:true` 下 argv 未加引号，含空格 cwd 致会话创建失败（issue #4623）；WSL 剪贴板贴图因 PowerShell 保存路径经环境变量传递失败，0.83.0 改直传修复。[来源](https://github.com/earendil-works/pi/issues/4623)、[0.83.0 CHANGELOG](https://cdn.jsdelivr.net/npm/@earendil-works/pi-coding-agent@0.83.0/CHANGELOG.md)
- 社区 Windows 专用发行/配置存在（@diegovisk/pi-windows 等）；生产化前应在目标 Windows 环境实测 bash 依赖点与空格路径场景。[来源](https://pi.dev/packages/@diegovisk/pi-windows)

## 7. 与 Claude Code / OpenCode 架构对比

| 维度 | Pi | Claude Code | OpenCode |
|---|---|---|---|
| 形态 | 开源 TS monorepo，**进程内可嵌入 SDK** + CLI/TUI + print/RPC headless | 闭源商业 CLI/TUI（附官方 SDK） | 开源 CLI/TUI，形态贴近 Claude Code |
| 内核哲学 | 极简 harness，扩展全开放 | 重内置（权限/审批/订阅一体化） | 开源中间路线，内置较全 |
| 权限/沙箱 | 默认无审批，靠扩展补 | 内置 approval modes | 内置一定审批能力 |

- 专项对比仓库 disler/pi-vs-claude-code 逐特性对照两派差异；第三方 100 小时评测称 Pi 与 OpenCode 战平。[来源](https://github.com/disler/pi-vs-claude-code/blob/main/COMPARISON.md)、[来源](https://www.aib.vote/en/news/pi-agent-opencode-100-hours-review)、[架构解读](https://dev.to/pramod_sahu_d5bd2e6de82d1/understanding-pi-coding-agent-a-minimal-extensible-architecture-for-terminal-first-ai-coding-40d4)
- **取舍结论**：要把 Agent 能力长进自家产品（服务端自动化/自建 UI/深度定制 loop）→ 嵌入式 SDK 是结构性优势；只要终端开发助手 → Claude Code/OpenCode 开箱体验更省事。[来源](https://www.implicator.ai/pi-is-not-a-claude-code-rival-it-is-a-harness-rebellion/)

## 8. Subagent / 多 Agent 编排生态

- **内核不含 subagent，官方以扩展示例给参考实现**（examples/extensions/subagent：以工具形式 spawn 子 agent 会话，父 agent 以普通工具结果收回）。[来源](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/extensions/subagent/README.md)
- 社区方案谱系：tmux 终端级并行（pi-tmux-subagents）、进程内子代理（pi-subagent-in-memory：live TUI 卡片+JSONL 日志+零 system-prompt 开销）、headless 子代理（pi-headless-subagent 含子代理重试策略）、打包套件（@clanker-code/pi-subagents、@johnnywu/pi-subagents、@piotr-oles/pi-subagents）。[来源](https://www.npmjs.com/package/pi-tmux-subagents)、[来源](https://github.com/ross-jill-ws/pi-subagent-in-memory)、[来源](https://cdn.jsdelivr.net/npm/pi-headless-subagent@1.2.0/CONTEXT.md)、[来源](https://cdn.jsdelivr.net/npm/@clanker-code/pi-subagents@0.11.1/CHANGELOG.md)
- 机制本质：复用同一 SDK 在子会话中跑子任务，会话各自成 JSONL 树天然可审计；OpenClaw 是最大规模工业案例。[来源](https://docs.openclaw.ai/agent-runtime-architecture)
- 多语言移植活跃（Rust 版 pi_agent_rust/rustpi、Go 版 pi-go、Python 版 nu-duo）反证内核接口清晰稳定。[来源](https://github.com/Dicklesworthstone/pi_agent_rust)、[来源](https://github.com/Xujieddup/rustpi)、[来源](https://github.com/guanshan/pi-go)、[来源](https://github.com/korya/nu-duo)

## 9. 风险面：0.x 变更、治理、供应链

- **0.x 破坏性变更风险**：版本高速迭代（2026-06 约 0.75.x → 随后 0.82.0、0.83.0），且已有破坏性改名先例（queueMessage→steer/followUp）。[来源](https://security.snyk.io/package/npm/%40earendil-works%2Fpi-coding-agent/0.82.0)、[来源](https://cdn.jsdelivr.net/npm/@clanker-code/pi-subagents@0.11.1/CHANGELOG.md)、[CHANGELOG](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/CHANGELOG.md)
- **商业收购治理风险**：Earendil 主导路线图，长期开源承诺与二开自主性存在不确定性。[来源](https://mariozechner.at/posts/2026-04-08-ive-sold-out/)、[来源](https://learnblockchain.cn/article/27092)
- **npm 仿冒/镜像供应链风险**：npm 存在数十个 `@xxx/pi-coding-agent` 式同名镜像包，锁错包即引入不可信代码；必须锁 `@earendil-works` 官方作用域并私有镜像。[来源](https://www.npmjs.com/package/@vandeepunk/pi-coding-agent?activeTab=versions)、[registry](https://registry.npmjs.org/@earendil-works%2fpi-coding-agent)
- License 生态普遍按 MIT 惯例发布，LICENSE 文本未直接核验**待确认 → ✅ 已确认 MIT（package.json，见 §11.4）**（OpenClaw 第三方声明收录可作旁证）。[来源](https://raw.githubusercontent.com/openclaw/openclaw/HEAD/THIRD_PARTY_NOTICES.md)
- Star 数各来源口径不一（中文报道称 9.3 万星），未经 GitHub 直接核验**待确认**。[来源](https://news.qiniu.com/archives/1787103478559)

## 10. 作为业务基座二次开发的可行路径与风险

1. **主线：SDK 进程内嵌入**——装 `@earendil-works/pi-ai + pi-agent-core`（或 pi-coding-agent 的 createAgentSession）→ defineTool 注入业务工具 → steer()/followUp() 打通人工介入 → 事件流桥接自家 UI/SSE。[来源](https://pi.dev/docs/latest/sdk)
2. **备选：headless 服务化**——print/RPC/JSON 模式外包一层 HTTP 服务。[来源](https://www.cnblogs.com/znlgis/p/20959176)
3. **必做加固**：自建权限/审批扩展或上 CubeSandbox 类沙箱；锁定版本 + 私有 npm 镜像防上游 breaking change 与仿冒包。[来源](https://raw.githubusercontent.com/TencentCloud/CubeSandbox/master/docs/guide/integrations/pi-agent.md)
4. **多代理编排**：从官方 subagent 示例起步，按需选 tmux 并行或进程内方案；勿重复造会话管理（JSONL 树已内建）。[来源](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/extensions/subagent/README.md)

> [!question] 主要待确认项汇总（2026-08-25 实机核验后更新）
> ① 产品名 "LiblibPi" 无公开来源（维持原判：疑为记忆偏差）；② 工具参数 schema 用 zod 还是原生 JSON Schema——✅ **已解决：TypeBox `TSchema`**（见 §11）；③ web-ui/slack/pods 存续状态——**部分解决**：`pi-web-ui` npm 包存在但停滞在 0.75.x（见 §11）；④ 四种运行模式官方精确命名——**部分解决**：源码 modes 目录见 interactive/rpc/print 三形态（见 §11）；⑤ 内置工具完整权威清单——✅ **已解决**（见 §11）；⑥ LICENSE 文本原文——✅ **已确认 MIT**（package.json，见 §11）；⑦ 精确 star 数（未核验）；⑧ MCP 是否已有官方一等支持（0.84.3 dist 内未见 mcp 目录，倾向无内核支持）。

## 11. 实机核验增补（2026-08-25）

> [!info] 核验方法
> npm registry 直连拉取官方包 `@earendil-works/pi-coding-agent@0.84.3`（约 6.7 MB，含完整 `dist/` 源码 + `.d.ts` 类型 + sourcemap），逐文件比对类型定义与工具实现。与 OpenCode npm 包（7.8 KB 启动器 + 平台二进制，JS 源码不在包内）形成鲜明对比——**pi 的 npm 分发物可直接做源码级二开参考**。

### 11.1 工具定义契约：TypeBox，非 zod

| 项 | 结论 | 证据 |
|----|------|------|
| defineTool 签名 | `export declare function defineTool<TParams extends TSchema, TDetails = unknown, TState = any>(tool: ToolDefinition<TParams, TDetails, TState>): ToolDefinition<...> & AnyToolDefinition` | `dist/core/extensions/types.d.ts` line 386 |
| schema 类型来源 | `import type { Static, TSchema } from "typebox"` —— **参数 schema 是 TypeBox JSON Schema（TSchema），不是 zod**；`ToolDefinition` 注释明写 "/** Parameter schema (TypeBox) */" | 同文件 line 13/344/355 |
| 注册入口 | `registerTool<TParams extends TSchema>(...)`（session/extension 侧同型约束） | 同文件 line 927 |

> [!tip] 对二开的影响
> TypeBox 的 `Static<T>` 可静态推导参数类型且原生产出 JSON Schema（可直接喂 LLM tool 定义），比 zod 少一层转换；迁移 OpenCode 插件（zod 契约）到 pi 时工具参数层需重写。

### 11.2 steer/followUp 双队列实锤

`dist/core/agent-session.d.ts` 中 40 处命中：`steering: readonly string[]`、`followUp: readonly string[]`、`_steeringMessages` / `_followUpMessages` 私有队列、`streamingBehavior?: "steer" \| "followUp"`（注释："When streaming, how to queue the message: 'steer' (interrupt) or 'followUp' (wait). Required if streaming."）。与本文 §3 公开资料结论一致，机制确凿。

### 11.3 内置工具完整清单（core/tools 目录实锤）

**面向模型的核心工具**：`bash`、`read`、`write`、`edit`、`edit-diff`、`grep`、`find`、`ls`、**`powershell`**（Windows 一等支持的直接证据）；**辅助设施**（非模型工具）：`file-mutation-queue`（写操作排队）、`output-accumulator`、`truncate`、`path-utils`、`render-utils`、`tool-definition-wrapper`、`index`。package.json description 自述 "Coding agent CLI with read, bash, edit, write tools and session management"。

### 11.4 运行模式、许可与版本快照

| 项 | 结论 |
|----|------|
| 运行模式 | `dist/modes/` 目录含 `interactive/`、`rpc/` 子目录 + `print-mode.d.ts` → CLI 至少三形态（交互 TUI / print 非交互 / RPC headless）；JSON 输出形态与 SDK 进程内嵌入未在目录级单独出现（前者可能并入 print/rpc，后者走库导入） |
| License | package.json `"license": "MIT"` ✅ |
| bin 入口 | `"pi": "dist/bundle/cli.js"`（打包单文件 CLI） |
| 版本节奏 | 核验当日 latest = **0.84.3**；`pi-web-ui` 最新 0.75.3 且长期未更（web-ui 线停滞佐证仓库自述收窄为 "unified LLM API, agent loop, TUI, coding agent CLI"） |
| MCP | 0.84.3 dist 内无 mcp 内核模块目录 → 维持 §4/⑧ 判断：MCP 走社区扩展 |

> 版本对照：同期 OpenCode npm latest = 1.18.23（见 [[参考-OpenCode-技术调研报告]] §11），两家均处高速发版期。

## 反向链接

- [[pi-agent-framework-knowledge]] — 框架知识沉淀
- [[opencode-pi-base-development-analysis]] — OpenCode/Pi 双基座二开分析
- [[main-subagent-realtime-interaction]] — 主子代理实时交互模式
- [[参考-OpenCode-技术调研报告]] — 同期对照调研
