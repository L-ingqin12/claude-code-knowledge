---
title: SESSION-ARCHIVE-2026-08-26
aliases: [会话归档20260826, LogNet-PoC归档]
tags: [meta, ai/ops]
created: 2026-08-26
updated: 2026-08-26
status: stable
---

# SESSION-ARCHIVE-2026-08-26

> [!abstract] 本日会话 = 前夜会话 `main-session-7f08eaca`（OpenCode/Pi 双基座调研 + 四篇架构方案）的续篇：**Phase A 实机核验收官 → Pi 报告回写 → 全库一致性审计 → LogNet PoC（M0）实现与验收**。前夜产出见 [[SESSION-ARCHIVE-2026-08-25]]。

## 一、Phase A 实机核验收官（两份调研报告回写）

| 报告 | 动作 | 关键结论 |
|------|------|---------|
| [[参考-OpenCode-技术调研报告]] | §11 实机核验增补（前夜完成，本轮校对） | explore 内置四件套实锤、top_p 支持、权限键实为 `doom_loop`+`external_directory`、MCP timeout 默认 5000ms、hook 全集增补（chat.headers/tool.definition 等）、二进制取证无 `mcp__` 分隔符 |
| [[参考-Pi-Agent-技术调研报告]] | ✅ 本轮新增 §11（8 项待确认解决 5 项） | `defineTool<TParams extends TSchema>` = **TypeBox 非 zod**；steer/followUp 双队列源码实锤；内置工具九件套含 **powershell**；运行模式 interactive/rpc/print；MIT 许可；0.84.3 版本快照 |
| [[opencode-pi-base-development-analysis]] | 纠偏 2 处被推翻表述 | zod→TypeBox；`mcp__<server>__<tool>`→`<server>_<tool>` |

## 二、全库一致性审计（子代理执行）

六项检查全部执行：**333 条 wikilink 0 断链** · frontmatter 补齐 updated=2026-08-26（12 文件）· 0 Mermaid 违例 · 5 处事实矛盾修正（Pi「4原子工具」→9 工具勘误、v1.18.23 快照等）· MOC 计数校准（56→60）· 新文档连通性 11/14/10/13 条出链。逐文件明细见 `_install-tmp/audit-report.md`（不入库）。commit `1e83c71`。

## 三、LogNet PoC（M0 数据层）— 主会话自研

> [!warning] 教训记录
> 「构建 PoC」任务两次委派子代理均**零产出失败**（无 closing message、无文件落盘），send_message 重试亦失败；最终由主会话直接实现并验收。后续大颗粒实现类任务建议主会话直做或分片委派+增量落盘要求。

### 交付物（commit `7a7ba14`，23 文件 +1690 行）

`scripts/lognet-poc/`：解析器注册表（hilog/kmsg 容错正则）、连续重复折叠、SQLite(+FTS5) 单文件 lognet.db（WAL / synchronous=NORMAL / keyset 分页 50k / 批量 executemany）、四类边建图（temporal_next / same_entity 线性链 / causal_hint R1 / co_occurrence R2）、query_logs（FTS MATCH+结构化过滤+引用指针）、get_subgraph（BFS+时间窗剪枝+token 预算闸+环防护）、CLI、合成故障链生成器、27 项 unittest、FTS 基准、一键 run_tests.ps1。部署四规则闭环见 deployment-log 2026-08-26 条目。

### 调试过程中抓获的 7 个真实缺陷

| # | 缺陷 | 定位手段 |
|---|------|---------|
| 1 | hilog 正则字符类 `[DIVEF]` 把级别 **W** 写成了字母 **V** → 恰好 100 条 W 行静默跳过 | CLI stats skipped_lines==100 → 二分正则探针 |
| 2 | causal 回溯解包反序 `(ets,enid)` ↔ 实际存 `(id,ts)` → 边的 dst 是时间戳浮点 | 套件内分层 JOIN 诊断（边计数 3 但端点 JOIN 为 0） |
| 3 | kmsg 行 tag=None 直插 FTS5 的隐患 | 代码复查预防性修复 |
| 4 | flush() 中 fts 行 zip 全局 signals 与批次 nodes 错配 | 代码复查 |
| 5 | runner：Join-Path 多参 / `-c` 引号剥离 / synth_gen 直接执行不可导入 lognet_poc | 冒烟三连败逐一修 |
| 6 | `statistics.percentile` 不存在（3.13 无此 API）→ 手工分位 | bench 崩溃栈 |
| 7 | 合成器 tid 带 i%7、tag 按 i%3 抖动 → 连续折叠率恒 0，且旧断言 8000%20==0 碰巧放行 | **CLI stats folded_rows==events 暴露** → 断言收紧为精确值 |

### 验收数据（诚实口径）

- **27/27 测试 OK**；CLI build→query（精确命中 5 条植入 ext4 行）→subgraph（watchdog 信号 2 跳内达 ext4 根因，causal_hint w=0.9048）全链路通过
- **折叠降量**：kernel.log 100006→99313 行；hilog 200012→192412 行（合成包重复密度所限，真实日志预期一个数量级）
- **FTS 基准**：P50=12.7ms / P95=348ms @ 29 万折叠行（500ms CI 闸 PASS）。⚠️ 设计目标 P95<100ms 是 **5M 行**口径——本基准仅验证机制，规模外推留真实包 M0 验收（[[lognet-rootcause-multiagent-architecture]] §九.3 假设 1）

## 四、git 提交清单（正常节奏）

| commit | 内容 |
|--------|------|
| `1518130` | docs: 双基座调研五件套 + 实机核验回写（15 文件 +1299） |
| `c75d5f7` | chore: Claude Code 本地权限白名单同步 |
| `1e83c71` | docs(audit): 全库一致性审计 13 文件 |
| `7a7ba14` | feat(lognet-poc): M0 数据层原型 |
| `677d57b` | docs: 归档本篇 + DocD M0 回标 + KB-Home 挂载 + deployment-log |
| （本条） | docs: COM/CPO 两份学习文档入库 |

## 五、未解决问题与风险登记

1. **调研报告遗留待确认**：OpenCode org 归属（anomalyco vs sst）、skill allowed-tools 是否被执行、MCP 分隔符源码级确认；Pi 的 LiblibPi 名称、精确 star 数、MCP 官方一等支持——均需开放网络环境复核。
2. **push 前脱敏**：`.claude/settings.local.json` 含本地代理地址（[IP已脱敏]:10808）；推公网仓库前须处理（AGENTS 五·五）。
3. **PoC 规模缺口**：FTS 5M 行验收、R2 burst 稠密场景退化、真实日志包解析器逐个补齐（isp/sensorhub 等）。
4. **M1–M4 未启动**：crash/tombstone 符号化链路（addr2line/artget 设计已在方案 §五）、多 Agent 展开、服务化会话池。
5. **学习资料入库** ✅：经用户澄清（CPO=C++ 定制点对象/tag_invoke，非共封装光学），新增 [[参考-COM组件框架-Windows集成]]（Windows 集成实战向）与 [[参考-CPP-CPO定制点与std-execution]]（P2300 机制+stdexec 实操）；两者各含待确认清单，时效性条目已标注。

## Related

[[SESSION-ARCHIVE-2026-08-25]] · [[参考-OpenCode-技术调研报告]] · [[参考-Pi-Agent-技术调研报告]] · [[lognet-rootcause-multiagent-architecture]] · [[opencode-pi-base-development-analysis]] · [[main-subagent-realtime-interaction]] · [[agent-memory-context-knowledge-design]] · [[参考-COM组件框架-Windows集成]] · [[参考-CPP-CPO定制点与std-execution]] · [[Claude-Ops-KB-Home]]
