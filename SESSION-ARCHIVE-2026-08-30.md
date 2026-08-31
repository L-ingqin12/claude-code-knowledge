---
title: SESSION-ARCHIVE 2026-08-30
aliases: [会话归档 2026-08-30, DSH升级与思考控制归档]
tags: [meta, session-archive, ai/agent]
created: 2026-08-30
updated: 2026-08-30
status: review
---

# 会话归档 — 2026-08-30：dsh/dsh-tui 升级 + 思考强度控制 + Token 优化

See also: [[AI-Links-KB-Home]] | [[DSH-TUI插件使用手册]] | [[DSH提效与Token插件调研]] | [[AGENTS]]

> [!abstract] 主题
> 1) 升级 DeepSeek Harness 与 TUI 客户端；2) 修正 dsh-tui 安装方式为直连路线；3) 思考强度（reasoning effort）开关配置；4) 自动 compact + 降低过度思考 token 耗用。

## 一、操作记录

### 1. 升级（已完成 ✅）

| 项 | 旧 | 新 | 方式 |
|---|---|---|---|
| `@deepseek-ai/dsh`（全局） | 0.1.0-rc.6 | **0.1.1-rc.2** | `npm i -g @deepseek-ai/dsh@latest` |
| `dsh-tui`（全局） | 未装（profile 集成旧路线） | **0.2.19** | `npm i -g dsh-tui` |

### 2. 安装方式修正（已完成 ✅）

- 旧路线：`dsh --profile tui`（cordis 插件包 `@dsh-tui/dsh-tui`，profile 集成）
- 新路线（当前）：**`dsh web` 起 host（127.0.0.1:3080）+ `dsh-tui` 直连**，直接 `dsh-tui` 命令启动
- 端到端验证：`dsh-tui run "..."` 一次调用成功（非 429），会话请求头实测 `z-ai/glm-5.3-flash` + `reasoningEffort:"low"`

### 3. 模型路由修正（已完成 ✅）

- 默认模型 `z-ai/glm-5.2:free` → **`z-ai/glm-5.3-flash`**（:free 上游共享池持续 429；minimax-m3:free 实测无响应已标注失效）
- settings.yaml：`agent-default-model` 加 `reasoningEffort: low`；`reasoningEfforts` 声明 low/high/max（OpenRouter 实测仅此三档有效）

### 4. 思考强度控制（已完成 ✅，按需调整）

- **独立 dsh-tui 无内置思考控制**（源码核查 lib/commands.js：无 /model、/effort、/thinking）
- 控制入口 = **host 端 settings.yaml 热加载**：改 `agent-default-model.reasoningEffort` 新会话即生效；或 Web 端模型选择器 /model
- GLM-5.3-flash 实证：默认 max 思考（最费），`low` 有效降档（say ok 仅 26 reasoning tokens）；`disabled`/`none` 无效（GLM 思考不可关）

### 5. 自动 compact（已完成 ✅）

- web profile `cordis.patch.yml`：`compaction-basic` 配置 `auto: true` + `thresholdRatio: 0.75`（默认 0.8）+ 主力模型 0.7
- 工具结果压缩 `tool-result-pruner` 为 dsh-base 内建（8192/4096/1024），未改

## 二、排障过程（429 限流）

1. `dsh-tui run` 首次报 **429 `z-ai/glm-5.2:free is temporarily rate-limited upstream`**（OpenRouter 免费共享池）
2. 重试 6s 后仍 429 → 判定免费模型不可用
3. 直测 OpenRouter API：glm-5.3-flash 正常（付费）；minimax-m3:free 无响应（失效）
4. 切换默认模型 → 端到端恢复 ✅

## 三、关键结论

1. **免费模型不可作主力**（共享池限流 + GLM-5.2 最低思考档 high，省不了 token）
2. **GLM 系思考不可关闭，最低档 low**——省 token 唯一途径是降档
3. dsh 插件生态分 host 侧（TUI 生效）与 Web 侧（面板类，TUI 无效）；TUI 场景压缩插件官方 compaction-basic 已够用
4. settings.yaml **热加载** vs profile patch（cordis.patch.yml）**重启生效**，两者修改路径不同

## 四、产出

- [[DSH-TUI插件使用手册]] — 新增"独立客户端路线"章节（updated 2026-08-30）
- [[DSH提效与Token插件调研]] — 新增"思考强度控制实证"章节（updated 2026-08-30）
- 配置变更：`~/.dsh/settings.yaml`、`~/.dsh/profiles/web/cordis.patch.yml`（未入库，本地生效）

## 五、未解决问题 / 后续

- [ ] dsh-tui 交互式 TUI 未在真实 TTY 人工验收（本会话仅验证 run 模式）；建议用户在项目子目录跑 `dsh-tui` 体验
- [ ] 长期费用治理（budget 告警）尚未装（Web 面插件 dsh-cost-meter / dsh-budget，TUI 场景可后续评估）
- [ ] 升级到 rc.2 后 profile tui（旧路线）未验证，已保留未删
- [ ] 官方文档站 https://deepseek-harness.github.io/deepseek-harness/ 可作为后续配置查阅源

## Related

- [[DSH-TUI插件使用手册]] — TUI 两种安装路线
- [[DSH提效与Token插件调研]] — token 优化配置
- [[DSH插件与Hook开发最佳实践]] — 插件机制
- [[AI-Links-KB-Home]] — MOC
- [[AGENTS]] — 知识库规范
