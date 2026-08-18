---
title: DSH TUI 插件使用手册
aliases: [dsh-tui, DSH终端UI, TUI手册]
tags: [ai/agent, ai/tools, ai/links]
created: 2026-08-17
updated: 2026-08-17
status: review
---

# DSH TUI 插件使用手册

See also: [[AI-Links-KB-Home]] | [[2026-08-16-AI链接综述与归档]] | [[DSH跨框架Skills与MCP加载]] | [[AGENTS]]

> [!abstract] 摘要
> 本文档是插件 `@dsh-tui/dsh-tui` 官方手册（README.zh.md，MIT 许可）的知识库落盘。该插件是 DeepSeek Harness 智能体的交互式终端（TUI）入口，以树外 dsh 插件 bundle 形式安装，在终端里提供 Claude Code / Codex 同款对话体验。

## 定位

- **是什么**：DeepSeek Harness 智能体的交互式终端（TUI）入口——在终端里获得 Claude Code / Codex 同款的对话体验。
- **形态**：树外（out-of-tree）dsh 插件 bundle；基于 [`@earendil-works/pi-tui`](https://www.npmjs.com/package/@earendil-works/pi-tui) 构建。
- **与官方的关系**：组合在官方 `@deepseek-ai/dsh-base` bundle 之上，与官方 web 界面共享同一套插件生态——shell 与文件系统工具、技能、子代理、工作流、沙箱审批——**不 fork、不魔改**。

> [!tip] 一句话定位
> 同一个插件生态，换一个终端交互入口。

> [!info] 实现细节
> pi-tui 钉在 0.80.7 并带一个 pnpm 补丁（编辑器提示符前缀能力），构建时打包进 `lib/`，因此仓库之外的安装方永远不会拿到未打补丁的副本。

## 本机状态（2026-08-17 实测）

| 项 | 实测值 |
|------|----------|
| 安装位置 | profile `tui`：`C:\Users\28064\.dsh\profiles\tui\package.json` |
| 依赖 | `@dsh-tui/dsh-tui` `^0.1.2` |
| bundles | `dsh.profile.bundles` = `["@deepseek-ai/dsh-base", "@dsh-tui/dsh-tui"]` |
| dsh CLI | `C:\Users\28064\nodejs-x64\node-v22.21.0-win-x64\dsh.ps1`，版本 0.1.0-rc.6 |
| dsh 自带 Node | `node-v22.21.0-win-x64\node.exe` → v22.21.0 |
| 系统 PATH node | v18.16.1（⚠ 不满足插件要求） |

> [!warning] Node 版本注意
> 插件要求 Node `^22.19 || >=24`，而系统 PATH 上的 node 是 v18.16.1。须用 dsh 自带 Node 22.21 环境：`dsh.ps1` 通过同目录 `node.exe` 调用 dsh（`node_modules/@deepseek-ai/dsh/lib/bin.js`），直接执行该 shim 即自动使用正确的 Node。

## 功能特性

- 模型输出与思考过程的**流式 Markdown 渲染**。
- **工具调用卡片**（terminal / diff / generic 三种渲染意图）；`Ctrl+O` 三档切换：预览 → 展开 → 隐藏。
- 工具审批与 `ask_user_question` 对话框，含 **plan 模式评审**。
- `@文件` 路径自动补全与 `@session` 会话引用卡片。
- 斜杠命令：`/model`（含推理力度选择）、`/resume`、`/compact`、`/details`、`/help`，以及其他插件注册的全部命令。
- 常驻 **todo 面板**、token 用量与上下文压力状态栏、会话标题。
- 可配置主题；从 `COLORTERM` 自动检测真彩色。

## 安装

前置要求：Node `^22.19 || >=24` 和 `dsh` CLI（`npm i -g @deepseek-ai/dsh@next`）。

```sh
dsh plugin --profile tui add @dsh-tui/dsh-tui
```

**跟踪仓库最新代码**（而非 npm 发布版）：

```sh
dsh plugin --profile tui add github:dsh-tui/dsh-tui
```

git 安装的插件在安装时通过 `prepare` 脚本构建，pnpm 默认拦截构建脚本：若该 `add` 失败，按它打印的键名在 `~/.dsh/profiles/tui/pnpm-workspace.yaml` 里追加 `allowBuilds` 后重跑——

```yaml
allowBuilds:
  "@dsh-tui/dsh-tui": true
```

**API Key**：在环境变量（或启动目录 / `$DSH_HOME` 下的 `.env`）里设置 `DEEPSEEK_API_KEY`。

## 运行

```sh
dsh --profile tui                        # 在当前目录开启会话
dsh --profile tui --resume <session-id>  # 恢复历史会话
```

## 本地 / 自部署 DeepSeek 端点

零代码配置，三选一：

| 方式 | 配置 |
|------|----------|
| 1. 环境变量 | `DEEPSEEK_BASE_URL=http://localhost:8000/v1` 搭配 `DEEPSEEK_API_KEY` |
| 2. 设置文件（热加载） | `$DSH_HOME/settings.yaml` 中配置 `llm-deepseek.baseURL` |
| 3. OpenAI 兼容网关 | profile 补丁 `$DSH_HOME/profiles/tui/cordis.patch.yml` 声明 `llm-pi-ai` 路由并把默认模型指过去（vLLM、SGLang 等；参见 dsh 的 providers 指南） |

```yaml
# $DSH_HOME/settings.yaml（方式 2，热加载）
llm-deepseek:
  baseURL: http://localhost:8000/v1
```

## 状态与已知限制

- 基于 pre-release 的 `@deepseek-ai/dsh` **rc 线**开发，上游稳定前随时可能 breaking；peer 依赖钉在验证过的 rc 版本。
- 恢复出来的测试套件（`tests/`）先于本次移植，目前**尚不可运行**。
- 真实模型回合需要可达的 DeepSeek 兼容端点；请求之前的一切（组合、渲染、审批、resume）**无需 key 即可工作**。

## 来源与许可

- 许可：**MIT**。
- 出处：TUI 实现恢复自 DeepSeek Harness 仓库历史（`packages/ui/tui`，上游于 commit `10bb9cbf4a` 移除），并移植到已发布的 rc API；上游版权声明保留在 LICENSE 中。
- 仓库 / 包：`github:dsh-tui/dsh-tui`，npm 包 `@dsh-tui/dsh-tui`。

## Related

- [[2026-08-16-AI链接综述与归档]] — README 友情链接条目 dsh-TUI/dsh-tianshu-tui 的调研归档
- [[DSH跨框架Skills与MCP加载]] — 跨框架 Skills / MCP 加载
- [[AI-Links-KB-Home]] — AI 链接收藏 MOC
- [[AGENTS]] — 知识库 AI 协作规范

## 验证清单

- [ ] `dsh --profile tui --dump-config` 输出中出现 `@dsh-tui/dsh-tui`
- [ ] 校验 profile 目录 `package.json`：`dependencies` 含 `@dsh-tui/dsh-tui`（`^0.1.2`），`dsh.profile.bundles` = `["@deepseek-ai/dsh-base", "@dsh-tui/dsh-tui"]`
- [ ] 首次启动 `dsh --profile tui` 看到 welcome / todo 面板与状态栏
- [ ] 确认用 dsh 自带 Node 22.21 环境启动（而非系统 PATH 的 v18.16.1）
- [ ] `Ctrl+O` 三档切换工具卡片：预览 → 展开 → 隐藏
- [ ] 配置 `DEEPSEEK_API_KEY`（或本地端点三选一）后完成一次真实模型回合
