---
title: OpenCode深入使用与扩展实战
aliases: [opencode实战, opencode二开指南]
tags: [ai/agent, ai/ops]
created: 2026-08-26
updated: 2026-08-26
status: review
source: 基于库内实机核验结论（v1.18.23）整理的实操手册；版本敏感处标待确认，事实口径以 [[参考-OpenCode-技术调研报告]] §11 为准
fetched_at: 2026-08-26
---

# OpenCode 深入使用与扩展实战

> [!abstract] 定位
> 调研报告回答"OpenCode 是什么/缺什么"，本文回答"怎么用透/怎么扩展"：配置体系、四内置件路由、自定义 tool/agent 落码、plugin hook 实战、MCP 接线、serve/SSE 集成与排障。选型论证见 [[opencode-pi-base-development-analysis]]。

See also: [[Claude-Ops-KB-Home]] · [[参考-OpenCode-技术调研报告]] · [[agent-harness-anatomy]] · [[MEMORY-INDEX]]

## 一、配置体系速览（opencode.json）

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "theme": "dark", "autoupdate": true,
  "mcp": { "fs": { "type": "local", "command": ["npx","-y","mcp-server-fs"] } },
  "permission": {
    "edit": "allow", "bash": { "*": "ask", "git push*": "deny" },
    "webfetch": { "domain.com": "allow" }
  },
  "agent": { /* 见 §二 */ }
}
```

- **permission 是 last-match 规则引擎**：数组顺序即优先级，后命中覆盖先命中——写规则按"宽→窄"排
- 权限键实为 `doom_loop` 与 `external_directory` 等少数键+工具级 action（edit/bash/webfetch），不要臆造键名（§11 核验口径）
- MCP 工具命名空间：`<server>_<tool>`（非 Claude Code 的 mcp__server__tool 双下划线）——跨框架迁移脚本注意替换

## 二、Agent frontmatter 实战

```markdown
---
description: 日志包解析专家——只读分析，产出结构化结论
mode: subagent        # primary | subagent | all
model: ox-alpha       # 继承铁律: 不指定 provider 覆盖
temperature: 0.1
tools:
  write: false        # 只读件禁写
  bash: allow
---

你是日志根因分析专家…（系统提示词正文：角色/边界/输出 schema）
```

- `description` 同时是主 agent 的路由依据——**委派质量的上限写在 description 里**（对照 [[Anthropic多智能体研究系统拆解]] 委派三要素）
- 四内置件 build/plan/general/explore 各有默认 tools 集；explore 只读适合检索型 fan-out（§11.2 口径）
- task 委派四缺口（异步 #5887/嵌套 #9280/并行 #29638/resume #6584 未全解）决定编排策略：**同步扇出为主**，异步需求走外层编排器（下一节 serve 模式）

## 三、自定义 Tool 落码（TypeScript 插件式）

```typescript
import type { Plugin } from "@opencode-ai/plugin"

export const MyPlugin: Plugin = async ({ project, client }) => ({
  tool: {
    // 注册后以 mypkg_secure_read 出现在模型工具面
    "mypkg_secure_read": async (args: { path: string; max_bytes?: number }) => {
      const p = path.resolve(args.path)
      if (!p.startsWith(SANDBOX_ROOT)) throw new Error("path escapes sandbox")
      const stat = await fs.stat(p)
      const cap = args.max_bytes ?? 65536
      return { content: await readHead(p, cap), truncated: stat.size > cap,
               meta: { size: stat.size } }   // 结构化返回优于散文
    }
  }
})
```

要点：① 返回带 `truncated/meta` 的结构体，让模型可推理；② 边界校验放工具内层而非只靠 permission；③ 命名前缀=插件命名空间防撞。

## 四、Plugin Hook 实战清单

| Hook | 典型用途 | 注意 |
|------|---------|------|
| `chat.params` | 注入系统提示词片段(时间/环境) | 幂等注入防重复拼接 |
| `chat.headers` / `message` | 审计/打标 | 别在热路径做重 IO |
| `tool.execute.before` | 参数改写/敏感命令拦截 | 返回 abort 即阻断执行 |
| `tool.execute.after` | 结果脱敏/审计落盘 | 异步化避免拖慢回合 |
| event bus(`event` 订阅) | session.idle 触发归档、file watcher | 事件风暴下加节流 |

模式：审计类逻辑全部走 after/event 落 JSONL——天然形成 [[agent-evals-observability]] 需要的 trace 数据源。

## 五、服务化集成（serve + SSE）

```
opencode serve --port 4096
POST /session            → 建 session
POST /session/:id/message → 发消息(EventSource 流回 token/工具事件)
GET  /event              → 全局 SSE 总线
```

- Web/移动端壳或 CI 机器人都走此面；abort 用对应 message cancel 端点
- 会话池管理（多用户复用）：cache 亲和=同用户粘 session；背压=队列深度阈值拒绝——设计推演见 [[opencode-pi-base-development-analysis]] §会话池
- 已知缺口对冲：resume 弱(#6584) → 外层把 session id+checkpoint 自管；并行弱(#29638) → 多进程实例+前置路由

## 六、排障速查

| 症状 | 处置 |
|------|------|
| 工具没出现在面板 | 插件未加载(路径/schema)；`opencode debug` 类命令核对；MCP 命名 `<server>_<tool>` 是否记错 |
| permission 规则不生效 | last-match 顺序错——窄规则放后面 |
| 子代理不返回 | 同步委派超时；检查 description 是否被误当 primary(mode 配错) |
| MCP server 起不来 | stdio 命令路径/env；remote 型查 SSE 端点可达性 |
| 升级后行为漂移 | 0.x→1.x 式大版本破坏面；锁版本+回归脚本 |

## 七、待确认项

> ① plugin API 的稳定版本承诺(当前标注 experimental 的面有多大)；② permission 对 MCP 工具的细粒度键支持；③ LSP 集成对各语言的诊断回灌质量；④ #29638 并行委派 issue 的最新进展。

## Related

[[参考-OpenCode-技术调研报告]] · [[opencode-pi-base-development-analysis]] · [[pi-agent深入使用与扩展实战]] · [[main-subagent-realtime-interaction]] · [[agent-evals-observability]] · [[fan-out-subagent-pattern]]
