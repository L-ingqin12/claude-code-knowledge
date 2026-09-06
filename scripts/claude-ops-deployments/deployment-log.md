# 部署审计日志

## 2026-06-23

### diagnostic-relay (部署)
- **时间**: 08:34
- **操作**: 部署
- **变更**: 插入透明 TCP 中继 relay.js 于 permafrost→proxy 之间
- **目的**: 捕获 CC 185 cancelRetry() 导致的 ECONNRESET 证据
- **预检**: ✅ proxy 在线, relay 语法通过, 端口可用
- **E2E**: ✅ CC→permafrost→relay→proxy→DeepSeek
- **逃生**: `bash diagnostic-relay/rollback.sh`
- **commit**: 96796d0

### diagnostic-relay (逃生)
- **时间**: 08:36
- **操作**: 逃生回滚
- **结果**: ✅ permafrost upstream 恢复为 proxy 直连, relay 进程已停止

### diagnostic-relay (重新部署)
- **时间**: 09:22
- **操作**: 部署
- **目的**: 捕获 session fddcf916 持续 attempt 状态证据
- **预检**: ✅
- **E2E**: ✅
- **结果**: ✅ 成功捕获 9 次 ECONNRESET 证据 (37.5% 异常率)

### diagnostic-relay (当前状态)
- **状态**: 🟢 运行中
- **relay PID**: 26354
- **逃生**: `bash deployments/diagnostic-relay/rollback.sh`

## 变更管控框架就绪

### 可用部署项

| 部署项 | 状态 | 逃生 |
|--------|------|------|
| diagnostic-relay | 🟢 运行中 | `bash deployments/diagnostic-relay/rollback.sh` |
| proxy-timeout-fix | ⬜ 待部署 | `bash deployments/proxy-timeout-fix/rollback.sh` |
| cc-version-switch | ⬜ 待部署 | `bash deployments/cc-version-switch/rollback.sh` |

### 部署规则 (强制)

1. 部署前 git commit 记录改动
2. deploy.sh 含预检 + E2E 验证 + 失败自动回滚
3. rollback.sh 可一键恢复到部署前状态
4. 每次部署/逃生均追加本日志

### proxy-timeout-fix (部署)
- **时间**: 2026-06-23T11:49+08:00
- **操作**: 部署
- **变更**: timeout 180s→90s, retries 3→1, backoff env var化
- **备份**: /root/workspace/claude-code-knowledge/deployments/proxy-timeout-fix/backups/proxy.js.20260623-114915
- **逃生**: `bash deployments/proxy-timeout-fix/rollback.sh`

### proxy-timeout-fix (逃生)
- **时间**: 2026-06-23T11:49+08:00
- **操作**: 逃生回滚
- **恢复**: timeout=180s retries=3 backoff=1s/3s/8s
- **备份来源**: /root/workspace/claude-code-knowledge/deployments/proxy-timeout-fix/backups/proxy.js.20260623-114915

### proxy-timeout-fix (测试部署→逃生)
- **时间**: 2026-06-23T11:49
- **操作**: 完整部署→验证→逃生测试
- **测试结果**:
  - 阶段1 语法检查: ✅
  - 阶段2 测试端口(8791)运行: ✅ API正常, env var覆盖生效
  - 阶段3 脚本安全性: ✅ 语法/幂等/重复部署检测
  - 阶段4 生产部署+逃生: ✅ 部署成功(timeout=90s,retries=1), API正常, 逃生恢复原始参数
- **结论**: 补丁安全, 部署/逃生有效, 生产已恢复原始状态
- **逃生**: `bash deployments/proxy-timeout-fix/rollback.sh`

### proxy-timeout-fix (部署)
- **时间**: 2026-06-23T11:51+08:00
- **操作**: 部署
- **变更**: timeout 180s→90s, retries 3→1, backoff env var化
- **备份**: /root/workspace/claude-code-knowledge/deployments/proxy-timeout-fix/backups/proxy.js.20260623-115104
- **逃生**: `bash deployments/proxy-timeout-fix/rollback.sh`

## 2026-07-03

### proxy.js 状态归档
- **时间**: 2026-07-03
- **操作**: 归档当前生产 proxy.js 状态至仓库
- **变更**: 将生产部署路径 `/root/claude-resilience-proxy.js` (含 timeout-fix 生产调优版) 同步至仓库
- **md5**: `d129c2e139ff5d2610abcdb913c5fa14` (部署) → 同步至仓库
- **关键参数**:
  - RETRIES: env `PROXY_RETRIES` 默认 1
  - BACKOFF: env `PROXY_BACKOFF_MS` 默认 1000ms
  - timeout: env `PROXY_TIMEOUT_MS` 默认 90000ms
  - abort: 已加入 retryable 列表
- **代理链路**: CC → permafrost (:8788) → proxy (:8787) → DeepSeek
  - permafrost_proxy.py 运行中 (PID 30738)
  - proxy.js 运行中 (端口 :8787)
- **逃生通道**:
  - L1: `bash /root/claude-permafrost-rollback.sh` → permafrost 绕过 proxy
  - L2: 直连 DeepSeek
- **已知问题**: 
  - `ANTHROPIC_BASE_URL=http://127.0.0.1:8788` (permafrost 端口), 非直接 :8787
  - CC v2.1.198 → v2.1.199 升级失败 (`install_failed`, 已记录于 `2026-07-02T15:39:40.687Z`)
  - SessionStart hook 可用: `bash /root/claude-version-hook.sh full`
- **commit**: 5d6bbd5

### subagent 资源管理体系 (Phase 2+2b+2d 部署)
- **时间**: 2026-07-03 20:02 CST
- **操作**: 部署 agent-gate 三层防护至生产环境
- **部署文件**:
  - `/root/claude-agent-gate.sh` (550+行, Phase 2+2b+2d)
  - `/root/claude-gate-bash.sh` (27行, Bash透明包装)
  - `/root/.claude/resource-patterns.conf` (25行, 命令模式)
  - `/root/.claude/resource-protocol.md` (76行, Claude资源协议)
- **Hook 变更**:
  - SessionStart: +cleanup, +mark-idle
  - PreToolUse: +mark-interactive(全工具), +check(Agent), +acquire-auto(Bash)
  - PostToolUse: +release-acquired(Bash) ← 新增 hook 类型
  - Stop: +mark-idle ← 新增 hook 事件
- **备份**: settings.local.json.20260703-200216
- **测试**: agent-gate-test.sh 27/27 ✓
- **架构文档**: docs/subagent-resource-architecture-2026-07-03.md
- **逃生**: 所有 hook 含 `|| true`; `rm /root/claude-agent-gate.sh` 完全卸载
- **commit**: (本次提交)

### proxy.js 诊断隔离声明
- **时间**: 2026-07-03
- **操作**: 添加 DO NOT ADD DIAGNOSTIC CODE 注释头
- **变更**: 3行注释, 无控制流改动
- **备份**: deployments/proxy-gate/backups/proxy.js.pre-header-20260703-*

### 收尾项
- **resource-protocol.md**: 部署至 /root/.claude/
- **proxy.js header**: 同步至仓库
- **Phase 3 轻量替代**: 无 hermes 环境下的 long-task 路由建议 (见 resource-protocol.md §Fan-out pattern)
- **commit**: a88655c

## 2026-07-06

### agent-gate 生产优化 (4项修复 + 1项文档化)
- **时间**: 2026-07-06
- **操作**: 基于部署后首次生产运行诊断，发现并修复 5 个问题
- **诊断方法**: ps 进程审查 → STAT 标志位 → 逆向追溯代码 → 最小修复
- **修复清单**:
  1. 🔴 `find_main_claude_pid()` — 主 session 不再被 renice+19 (之前 $PPID 穿透失败)
  2. 🟡 swap 门控 — SWAP_RED=70% / SWAP_YELLOW=55% 加入 memcheck 决策
  3. 🟡 mark-interactive 节流 — MARK_THROTTLE_SEC=3s, 减少重复 I/O
  4. 🟡 D 状态检测 — count_d_state_claude(), status + cleanup 暴露
  5. 🟢 覆盖扩面 — resource-patterns.conf 文档化注释
- **部署验证**:
  - 修复前: MemLevel=GREEN (无视 swap 55%)
  - 修复后: MemLevel=YELLOW (正确感知 swap 66%)
  - 修复前: 主 session nice=19
  - 修复后: 主 session nice=0
  - mark-interactive throttle 生效
- **备份**: /root/claude-agent-gate.sh.bak.20260706-*
- **回归测试**: 27/27 ✓
- **排查文档**: docs/production-diagnosis-2026-07-06.md
- **优化计划**: plans/agent-gate-optimization-plan-2026-07-06.md
- **commit**: 44130d4

## 2026-08-26

### lognet-poc M0 数据层原型 (入库)
- **时间**: 2026-08-26 ~01:30
- **操作**: 新增 scripts/lognet-poc/（非运行时部署，代码资产入库）
- **变更**: hilog/kmsg 解析注册表、连续重复折叠、SQLite+FTS5 LogNet 建库（WAL/synchronous=NORMAL/keyset 分页）、query_logs/get_subgraph 工具、合成故障链生成器、27 项 unittest
- **预检**: ✅ miniconda Python 3.13 + sqlite3 FTS5 可用性验证内建
- **E2E**: ✅ run_tests.ps1 全绿（unittest 27/27 + CLI build/query/subgraph 冒烟 + FTS 基准 P50=12.7ms/P95=348ms@291k 折叠行，500ms CI 闸通过）
- **逃生**: `git revert 7a7ba14` 或直接删除 scripts/lognet-poc/（无外部副作用；派生 db 可随时重建）
- **日志可审计**: builder.stats 结构化输出（每文件 events/folded_rows/skipped_lines/unknown_files）
- **commit**: 7a7ba14

## 2026-09-06

### cache-relay 内容审核 400 兜底扩展（Content Exists Risk → OpenRouter GLM）
- **时间**: 2026-09-06
- **操作**: 扩展 `scripts/claude-ops-deployments/cache-relay/cache-relay.mjs` 加 400 内容审核兜底；本地 `~/.cache-relay/config.json` 加 fallback 块；全局 `~/.claude/CLAUDE.md` 加会话红线
- **变更**:
  1. `forward()` 支持 overrideHeaders；新增 `readBody` / `fallbackConfig` / `isRisk400`
  2. `serve()`：命中 `400 + content exists risk` → 改投 OpenRouter `z-ai/glm-5.3-flash`（换 auth+model，成功路径纯透传）
  3. 兜底 key 走 `authTokenSource` → `~/.claude/oxalpha-settings.json`（密钥不落地）
- **预检**: ✅ `node --check` 语法通过；✅ authTokenSource 可读、token 可解析
- **部署**: ✅ 热部署（stop + deploy），端口 8790 监听
- **逃生**: `node cache-relay.mjs undeploy`（软回滚写 .disabled）；删 config.json 的 fallback 块即禁用兜底
- **待验证**: 端到端兜底触发未做（需构造审核命中请求）；恢复脚本 `sanitize-session.py` 待用户确认放行
- **commit**: 待提交（本地 main 分支）
