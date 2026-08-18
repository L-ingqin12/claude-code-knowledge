---
title: DSH 提效与 Token 用量插件调研
aliases: [DSH插件调研, Token插件, DSH提效插件]
tags: [ai/agent, ai/tools, ai/links]
created: 2026-08-18
updated: 2026-08-18
status: review
---

# DSH 提效与 Token 用量插件调研

See also: [[AI-Links-KB-Home]] | [[DSH-TUI插件使用手册]] | [[DSH插件与Hook开发最佳实践]] | [[DSH跨框架Skills与MCP加载]] | [[AGENTS]]

> [!abstract] 概述
> 调研 DeepSeek Harness（DSH）生态中「提效」与「查看 token 耗用量」相关插件。数据来源：GitHub API / npm registry / 1024Store 目录 API / 仓库 README（2026-08-18 时点实测，星标会漂移）。**核心结论：TUI 状态栏已内建 token 显示（官方 dsh-token-meter），无需额外装 token 插件；长期统计/费用治理可用 Web 插件或日志分析工具。**

## 一、官方 token 能力（已内建，无需安装）

**`@deepseek-ai/dsh-token-meter`**（官方仓库 `packages/llm/token-meter`）：

- 回放感知（replay-aware）的 token 计量服务：从持久会话日志为每个会话推进独立 fold，启发式计价（4 字符 ≈ 1 token）+ 复用提供方真实上报用量。
- 服务：`ctx.tokenMeter.measure()` 返回 `TokenMeasurement`（logRevision/baseline/totalTokens/surfaceTokens 等）；`estimateMessage()` 单条消息计价。
- 会话投影三个单元：`tokenUsage`（uncachedInput/output/cacheRead/cacheWrite）、`contextPressure`（pressureTokens + projectedTokens + contextWindow）、`contextBreakdown`（system/tools/message 启发式拆分，CJK/JSON 会低估，非账单口径）。
- **已含在 dsh-base 组合**（所有 profile 默认自带）；`@dsh-tui/dsh-tui` 状态栏的 `↑输入 ↓输出 / cache% / %context` 即其消费方；官方 `dsh-compaction-basic` 直读 `measure()` 决定何时压缩。

## 二、社区 Token/费用插件（多为 Web 面插件）

> [!warning] 表面适配
> 社区 token 面板基本是 **Web UI 插件**（设置页/悬浮面板），TUI/headless 下不生效；TUI 用户直接用官方状态栏，headless 走日志分析（见 2.4）。

### 2.1 费用/余额/预算类

| 插件 | 仓库 | 定位 | 星标 |
|---|---|---|---|
| dsh-cost-meter | Han-1413141/dsh-cost-meter | 会话/当日费用、预算框、官方余额、90+ 模型价格目录、峰谷计价 | 94★ 活跃 |
| TokenLedger | zh667/TokenLedger | 按中转站/项目/模型统计与归属，余额+订阅周期 | 99★ |
| dsh-web-billing | bpc-oss/dsh-web-billing | 人民币/美元计费、官方峰谷计价、逐条消息账本 | 10★ |
| dsh-balance-meter | Ghost011118/dsh-balance-meter | 输入框 dock 显示余额与会话成本 | 17★ |
| dsh-balance-tide | huanyuLv/dsh-balance-tide | 余额+会话花费、峰/谷价格徽章 | 6★ |
| dsh-budget | PerryLink/dsh-budget | 预算上限+阈值告警，超限 alert/block/degrade | 1★ |
| dsh-bill | Jannchie/dsh-bill | 每轮成本行、归因到工具/模型/系统提示词，8000+ 模型定价 | 2★ |
| dsh-whale-meter | Shiye-10Pages/dsh-whale-meter | 用量段位(🐟→🐳)+可分享战绩卡 | 4★ |
| dsh-deepseek-quota | yingjunnan/dsh-deepseek-quota | 右下角悬浮卡显示 API 余额 | 3★ |
| dsh-quota-hub | penguin-oo/dsh-quota-hub | 聚合 OpenCodeGo/DeepSeek/OpenRouter/SiliconFlow/Moonshot 额度 | 9★ |

### 2.2 Token 统计/仪表盘/历史类

| 插件 | 仓库 | 定位 | 星标 |
|---|---|---|---|
| dsh-token-cost | le-soleil-se-couche/dsh-token-cost | 费用嵌入官方底部状态条，逐请求明细，自定义单价 | 6★ |
| dsh-token-stats | H1a3x/dsh-token-stats | 可拖拽面板：输入/输出/缓存命中率、按月热力图 | 6★ |
| dsh-token-usage | LeemanCheung/dsh-token-usage | 每会话持久化 + 52 周热力图 | 11★ |
| dsh-token-usage | LaoYueHanNi/dsh-token-usage | 每日 JSONL 持久化 + 趋势图 | 5★ |
| dsh-token-usage-dashboard | solstice621/dsh-token-usage-dashboard | Codex 风格 5 卡仪表盘 | 0★ |
| dsh-usage-panel | AlfredChaos/dsh-usage-panel | KPI/半年热力图/按模型堆叠图 | 1★ |
| ds-api-usage | Sev7een/ds-api-usage | API 余额 + 24h 用量时间线 | 6★ |
| dsh-token-pet | pk7j7sqryy-ops/dsh-token-pet | 会话头卡通用量小部件 | 3★ |

### 2.3 上下文压力可视化

| 插件 | 仓库 | 定位 | 星标 |
|---|---|---|---|
| dsh-context | bowenliang123/dsh-context | 上下文构成/演变/压缩事件/消息级 token | 313★ 活跃 |
| context-vista | GooodWei/context-vista | 右侧悬浮栏 + `/context` 环形图 | 8★ |
| dsh-context-doctor | Zhenyu98/dsh-context-doctor | 指令链/技能/工具 schema token 成本量化+裁剪建议 | 15★ |
| dsh-scope | helloxkk/dsh-scope | 会话级 KV 缓存命中率与 token 构成 | 1★ |

### 2.4 Headless / 可观测性（跨表面）

- [zoahdev/dsh-trace](https://github.com/zoahdev/dsh-trace) — 解码 `session.jsonl.zstd` 渲染 token/工具/延迟 HTML 报告（零依赖）
- [vivekchand/clawmetry](https://github.com/vivekchand/clawmetry) — 本地零配置仪表盘：会话/token/成本/工具调用
- [loongsuite/dsh-plugin](https://github.com/loongsuite/dsh-plugin) — OpenTelemetry GenAI 调用链（OTLP 上报）
- [PerryLink/dsh-observe](https://github.com/PerryLink/dsh-observe) — OTLP/Langfuse 导出器

## 三、提效类插件

### 3.1 侧边栏/工作台

| 插件 | 定位 | 星标 |
|---|---|---|
| [DSH-better-sidebar](https://github.com/omdsh-dev/DSH-better-sidebar) | VS Code 式工作台：文件/编辑器/终端/Git/后台任务，暴露 ctx.betterSidebar 服务 | 2155★ 非常活跃 |
| dsh-workspace-search | better-sidebar 扩展：工作区关键词搜索 | — |

### 3.2 会话管理

| 插件 | 定位 | 星标 |
|---|---|---|
| [dsh-sidechain](https://github.com/omdsh-dev/dsh-sidechain) | `/side` 侧会话 + `/btw` 一次性侧问（不污染主上下文） | 10★ |
| [dsh-session-manager](https://github.com/Semidia/dsh-session-manager) | 置顶/重命名/归档/续聊/深度链接 | 2★ |
| [dsh-session-handoff](https://github.com/WeiYe6/dsh-session-handoff) | `/handoff` 长会话交接 | 1★ |
| dsh-session-export | 导出可移植 Markdown/JSON | — |
| dsh-fork-graph / dsh-fork-diff | fork 血缘图 / 分支比较 | — |

### 3.3 上下文压缩/精简

| 插件 | 定位 | 星标 |
|---|---|---|
| dsh-compaction-basic（官方） | 官方压缩策略，直读 tokenMeter.measure() | — |
| [billion-context-dsh](https://github.com/Tyan66666/billion-context-dsh) | 模型驱动压缩（ACP），模型决定何时压缩 | 25★ |
| dsh-compressor | 压缩工具输出，最多省 20% 上下文 | 1★ |
| context-pruner | 自动清理过期/重复/失败/超大/低价值消息 | 0★ |
| dsh-minimal-first-turn | 首轮精简：prompt/工具目录最小化 | — |
| dsh-context-proxy | 按需取回薄层：context_query/slice/grep | — |

### 3.4 搜索/批量/编排/皮肤/市场

- 搜索：[dsh-web-search-pro](https://github.com/anweat/dsh-web-search-pro)（多引擎路由+缓存）、[dsh-tavily](https://github.com/moguiyu/dsh-tavily)、[dsh-tool-search](https://github.com/Letter2025/dsh-tool-search)（工具渐进披露）
- 批量：[dsh-taskswarm](https://github.com/february2015/dsh-taskswarm)（依赖分波多 lane 并行）、[dsh-background-agents](https://github.com/PerryLink/dsh-background-agents)（持久化后台子代理）、[dsh-automation](https://github.com/titanwings/dsh-automation)（定时任务）
- 皮肤：[dsh-web-ui](https://github.com/zhu1090093659/dsh-web-ui) **4532★** 全家桶（实时 token 统计/任务看板/皮肤中心，npm `@linxin666/dsh-web-ui-all`）、[dsh-stylevault](https://github.com/GptsApp/dsh-stylevault)（30 套配色）
- 市场：[DSH 1024Store](https://github.com/imsai-sh/awesome-deepseek-harness-plugins)（**4120 插件**目录，`dsh plugin add dsh1024` 或 CLI `npm i -g dsh1024`）、[awesome-deepseek-harness](https://github.com/0xsline/awesome-deepseek-harness)（723★ 精选，官网 deepseekdocs.com）

## 四、推荐组合（结合本机 TUI 场景）

> [!success] 本机推荐
> 1. **Token 显示**：官方 TUI 状态栏已内建（↑in ↓out / cache% / %context）——**零安装**。
> 2. **长期统计**（需要热力图/费用时）：Web 面装 [dsh-token-cost](https://github.com/le-soleil-se-couche/dsh-token-cost)（最轻，嵌官方状态条）或 [LeemanCheung/dsh-token-usage](https://github.com/LeemanCheung/dsh-token-usage)；纯 TUI/headless 用 [clawmetry](https://github.com/vivekchand/clawmetry) 读会话日志零侵入。
> 3. **提效三件套**（Web 面）：DSH-better-sidebar（2155★）+ dsh-web-ui（4532★）+ dsh-context（313★）；会话提效用 dsh-sidechain + dsh-session-manager。
> 4. **费用治理**：[dsh-cost-meter](https://github.com/Han-1413141/dsh-cost-meter)（功能最全）或 [dsh-budget](https://github.com/PerryLink/dsh-budget)（预算告警）。
> 5. **压缩节流**：官方 compaction-basic（自带）+ 可选 billion-context-dsh 或 context-pruner。

## 五、注意事项

1. **rc 线兼容风险**：官方 master 已是 0.1.0-rc.7，本机 CLI 是 rc.6；装前看插件 peer 依赖与适配声明。
2. **安装与重启**：`dsh plugin --profile <p> add github:owner/repo`（或 npm 包名）；安装/更新后**必须重启 dsh/TUI 会话**才生效。
3. **来源信任**：生态 4120+ 插件，第三方可在 host 侧执行任意代码；1024Store 只做只读校验 ≠ 安全审计。优先高星/活跃/有审计徽章插件，陌生插件先读 cordis.patch.yml。
4. **同名冲突**：存在 3 个 dsh-token-usage、2 个 dsh-cost-meter，用 `github:owner/repo` 区分，勿重复安装同功能插件。
5. **口径认知**：社区费用数字均为「估算非账单」；涉及准确计费以提供方账单为准。
6. **表面适配**：Web 插件在 TUI/headless 无 UI；headless 只能走日志分析/OTel。

## Related

- [[DSH-TUI插件使用手册]] — TUI 状态栏 token 显示即本文 §一 的消费方
- [[DSH插件与Hook开发最佳实践]] — 插件安装/开发机制
- [[DSH跨框架Skills与MCP加载]] — 插件加载三路径
- [[AI-Links-KB-Home]] — 本子库 MOC
- [[AGENTS]] — 知识库规范
