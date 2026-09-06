---
title: tianshu-tui 缓存命中率目标方案（cache-aim）
aliases: [tianshu cache aim, 天枢缓存命中率]
tags: [ai/ops, ai/agent]
created: 2026-09-06
updated: 2026-09-06
status: review
---

# tianshu-tui 缓存命中率目标方案（cache-aim）

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-strategy]] · [[claude-cache-optimization]] · [[claude-cache-postmortem-2026-06-13]]

> 背景：`D:\Document\local\Tianshu-harness`（包 `tianshu-tui` v3.12.0，二进制 `rivet`）是面向 DeepSeek V4 前缀缓存的 TUI coding agent。本方案把本库（Claude Code × DeepSeek）沉淀的缓存经验与脚本，应用到 tianshu-tui，以达成命中率目标 **Pro >95% / Flash >80%**（告警 Pro<85% / Flash<60%，与本库口径一致）。

---

## 一、三方现状对比结论

tianshu-tui 已经把本库的 Hermes 三原则 + currentDate 教训**全部内置且做得更深**：

| 维度 | 本库教训 | tianshu-tui v3.12.0 实际 |
|---|---|---|
| currentDate 头号杀手 | CC 注入 `messages[0]` → 跨天全量 miss | **完全不注入日期**（grep 无 date/timestamp）✅ |
| 工具排序 | 需 `sort_tools()` | 已按 name 排序（`registry.ts:48-53`）✅ |
| 动态 system | 需 `freeze_volatile()` | 冻结前缀 + volatile appendix 置尾（`volatile.ts`）✅ |
| 记忆冻结快照 | Hermes 原则② | `frozen-snapshot.ts` 逐 user 消息冻结 ✅ |
| 分叉定位 | permafrost `/doctor` | `fingerprint.ts` SHA-256 + drift 归因 ✅ |
| 命中率度量 | permafrost `/stats` | `usage-aggregator` + `/cache` 面板 + 悬崖自动诊断 ✅ |

**核心结论**：命中率目标靠 tianshu 现有设计已可达；真正缺的是本库那套「独立时间驱动监控 + 原始证据捕获」，以及 3 个边角（gap 排序见下）。

## 二、差距清单（按缓存影响）

1. 无独立 60s 守护（只 turn/frame 驱动）。
2. 命中率骤降无请求体快照（只 diagnose 字符串 + hash 面包屑）。
3. 无聚合 `/doctor` 端点。
4. system-reminder 合并改写 live last-user 尾部（**低-中，重估中**，见 §P3）。
5. sub-1M 窗口 collapse/prune 重写历史（已知权衡，`CACHE_ANCHOR_MESSAGES=2` 保护）。
6. `invalidateFreshCache()` 中途触发（~99%→16%，已加诊断）。
7. 无 date-stability 守卫（潜在）。

## 三、方案设计（本轮落地 P0 + P3）

### P0 — 独立缓存监控守护（复用本库脚本）

- **设计**：复用 `scripts/claude-ops-deployments/root-scripts/claude-cache-monitor.sh` 骨架（state.json 增量对比 + 阈值 + 自动 dump），把 stats 端点指向 tianshu 的 `GET /cache/usage`（`src/server/cache-routes.ts`）。
- **阈值**（对齐本库）：Pro <0.85 告警、<0.70 dump；Flash <0.60（简化首版按统一 0.70 dump）。
- **动作**：只 dump（快照 + 日志），**不重启任何进程**（本库教训：自动重启导致会话中断）。
- **落地位置**：`D:\Document\local\Tianshu-harness\scripts\tianshu-cache-monitor.sh`（新文件，零侵入）。
- **回滚**：软回滚优先（`.disabled`/env 禁用，不删脚本），见 §四。

**P0 使用说明**：

```bash
bash scripts/tianshu-cache-monitor.sh once     # 单次检查（无参数默认 once）
bash scripts/tianshu-cache-monitor.sh run      # 前台循环（每 60s）
bash scripts/tianshu-cache-monitor.sh daemon   # 后台守护（写 daemon.pid）
bash scripts/tianshu-cache-monitor.sh stop     # 停守护（软回滚 E0，读 pid kill）
bash scripts/tianshu-cache-monitor.sh status   # 最近记录 + dump 历史
```

环境变量：`TIANSHU_URL`（默认 `http://127.0.0.1:3100`）· `TIANSHU_TOKEN`（`rivet serve` 若设 `RIVET_SERVER_TOKEN` 需一致）· `MONITOR_DIR`（默认 `~/.tianshu/cache-monitor`）· `TIANSHU_CACHE_MONITOR_DISABLED=1`（软回滚开关，等价 `touch ~/.tianshu/cache-monitor/.disabled`）。

阈值：命中率 <85% 告警 / <70% dump；新增 miss 占比 >0.5 dump。动作**只 dump（不重启进程）**，产物 `~/.tianshu/cache-monitor/dump-*/`。

### P3 — system-reminder 合并路径（**重估裁决：不是 bug，不改代码**）

- **裁决（2026-09-06 深挖）**：`appendSystemReminder` 的合并路径**只改写数组末尾元素**（`context.ts:247,250`），从不碰中间消息；`'replace'` 事件只被 `session-persist-listener.ts` 消费（触发落盘），**PromptEngine 不订阅**；合并确定性 → 后续 build 字节一致；引擎 frozen snapshot 按已合并内容取键。**「tail 是最新位置，其后无缓存」的注释是对的**。
- **依据**：`context-sr-append.test.ts:6-25` 刻意 pin 合并、`:94-135` pin append；`engine-cache-stability.test.ts` pin 冻结快照字节同一。
- **真实代价**：仅 abort/retry / `writeProbe` 预热边缘下「单条 tail 消息」缓存 miss（几个 token，非前缀崩溃）。
- **决定**：按「如果没坏就别修」**不改代码**。最划算加固 = 补一条引擎级端到端测试（`addUserMessage → appendSystemReminder merge → buildOaiRequest → 增长 → 重建`，断言历史消息 + trailer 字节不变），关闭唯一未测缺口（**本轮暂缓，列遗留**）。

## 四、逃生与回滚通道（与功能同时设计；对齐本库 L0m/L0a/L0b 模式）

**原则（本库教训）**：逃生（快速止血、逐层关开关，系统保持运行）与回滚（恢复到已知好状态）**必须同时设计、与功能同步交付**；每个改动先 `cp` 快照；每个可独立关闭的组件留独立开关。

### P0 监控守护的逃生/回滚（**软回滚优先，禁止硬删除**）

| 级别 | 类型 | 操作 | 场景 |
|---|---|---|---|
| E0 停守护 | 逃生 | `bash scripts/tianshu-cache-monitor.sh stop`（读 `daemon.pid` kill） | 守护刷屏/异常，立即止血 |
| S0 软回滚 | 软回滚 | `touch ~/.tianshu/cache-monitor/.disabled` 或 `TIANSHU_CACHE_MONITOR_DISABLED=1` | **不需要监控时禁用**——保留脚本+数据，随时 `rm .disabled` 恢复 |
| R0 硬回滚 | 硬回滚 | `git revert 1bd8f83`（**不 `rm` 脚本，避免硬删除**） | 仅当要正式撤销本次部署 |

> **软回滚原则**：监控「停用」一律走 `.disabled`/env 开关（软回滚），**绝不 `rm` 删除脚本**——脚本是版本化资产，删除会丢历史、无法一键恢复。硬回滚（`git revert`）只用于正式撤销部署，且仍不触碰工作区文件。

### 未来代码改动（P1–P5）的逃生梯度（对齐本库 L0m/L0a/L0b）

| 级别 | 类型 | 操作 | 场景 |
|---|---|---|---|
| F0 关单 feature | 逃生 | 每个 feature 留独立 env/配置开关（如 `RIVET_CACHE_SNAPSHOT=0`） | 单 feature 出问题，关它，其余照跑 |
| F1 撤销单提交 | 回滚 | `git revert <commit>` | 单个改动出问题 |
| F2 还原单文件 | 回滚 | `cp 快照` 恢复 / `git checkout <file>` | 局部还原 |
| F3 整分支回退 | 回滚 | `git reset --hard <基线 commit>` | 全面回退 |

**硬约束（本库部署四规则）**：记录可追溯（每次改动 commit）· 部署前验证（隔离测试跑通）· 逃生机制（本表，与功能同步交付）· 日志可审计（dump + monitor.log）。

**快照纪律**：任何源文件改动前 `cp <file> <file>.bak-$(date +%s)`；Python 改动后清 `__pycache__`（本库 06-16 事故教训）。

## 五、测试计划（务必跑通后再部署）

| 项 | 命令 | 通过标准 |
|---|---|---|
| typecheck | `npx tsc --noEmit` | 0 error |
| build | `npm run build` | BUILD_EXIT=0 |
| SR 相关单测 | `node --import tsx --test src/agent/__tests__/context-sr-append.test.ts`（按仓库 test runner） | 全绿 |
| 缓存稳定单测 | `src/prompt/__tests__/engine-cache-stability.test.ts` | 全绿 |
| P0 脚本 | `bash scripts/tianshu-cache-monitor.sh once` | 能读到 stats、无报错 |

**部署门槛**：以上全部通过后才 commit + push（fork `L-ingqin12/Tianshu-harness`，分支 `clean-room-pro`）。

## 六、应用的本库经验教训（逐条）

1. **先仓库后部署**（本方案即先落盘本 doc）。
2. **改配置不动代码**：P0 是新脚本，不碰现有代码。
3. **如果没坏就别修**：P3 有测试 pin + 明确动机，重估后决定，不盲改。
4. **补丁先隔离测试**：P3 改前先跑 `context-sr-append.test.ts`。
5. **保存工作快照**：改前 `cp` 备份。
6. **重启前先验证**：P0 只 dump 不重启；P3 不涉及进程重启。
7. **生产操作需确认**：push 前用户确认。
8. **监控先于排查**：P0 就是补「无独立守护」这个监控缺口。

## 七、遗留 / 后续（本轮不做）

- P1（命中率悬崖请求体快照）、P2（聚合 `/doctor` 端点）、P4（date-stability 守卫）、P5（移植 permafrost coalescer + keepalive 冷启动优化）。
- 相关脚本复用清单见 `scripts/claude-ops-deployments/`（`permafrost_align.py` 算法可移植，需 Anthropic→OpenAI schema shim）。
