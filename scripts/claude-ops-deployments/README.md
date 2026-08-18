---
title: claude-ops-deployments README
aliases: [Claude-Ops 部署脚本库, claude-ops-deployments]
tags: [ai/ops, meta]
created: 2026-08-17
updated: 2026-08-17
status: review
source: github.com/L-ingqin12/agent-knowledge-base
source_urls: [https://github.com/L-ingqin12/agent-knowledge-base]
fetched_at: 2026-08-17
---

# claude-ops-deployments — 部署脚本库索引

> [!abstract] 本文档是 `scripts/claude-ops-deployments/` 的目录索引，收录从远程仓库迁移的全部代码/脚本/配置。

## 来源

- **源仓库**: [github.com/L-ingqin12/agent-knowledge-base](https://github.com/L-ingqin12/agent-knowledge-base) @ `f493130`
- **迁移日期**: 2026-08-17
- **迁移方式**: 只读源 `_install-tmp/akb-remote` → `scripts/` 下归集，保持目录结构
- **源 README 原件**: 保存于 [[deployment-framework|deployment-framework.md]]（部署管控框架原文）

## 目录结构

| 目录 | 文件数 | 内容 |
|------|--------|------|
| `root-scripts/` | 16 | 仓库根脚本/配置：12 个 .sh（守护/hook/部署/回滚）+ 2 个 .py + 1 个 .js + resource-patterns.conf |
| `patches/` | 3 | Permafrost 补丁（model_router.py、permafrost_align.py） |
| `components/` | 3 | 审计/分类组件（根目录版；scripts/components 重复副本未复制） |
| `diagnostic-relay/` | 4 | relay.js + 双版本逃生脚本（deployments 版与根目录版合并，见下方说明） |
| `tests/` | 1 | agent-gate-test.sh |
| `.githooks/` | 1 | pre-commit 钩子 |
| `demos/` | 59 | 原 scripts/ 内容：skill 注册/demo、interp、logsystem、migration |
| 部署项目（本目录根） | 38 | 6 个部署项目目录（不含 diagnostic-relay，见下） |
| 根文件 | 3 | README.md（本文档）、deployment-framework.md、deployment-log.md |
| `../claude-ops-dumps/` | 7 | 已脱敏 dump 对比数据（本地保留，不进入 git） |

部署项目明细（`deployments/` 原样迁移）：

| 项目 | 说明 |
|------|------|
| `agent-gate/` | Claude 网关（hooks-reference.json） |
| `cc-version-switch/` | CC 版本切换（deploy/rollback） |
| `diagnostic-relay/` | 诊断中继 relay.js（与根目录版合并，见下） |
| `log-analysis-agent/` | Windows 版日志分析 agent（nginx + workers） |
| `log-analysis-agent-pi/` | 集群版日志分析 agent（TypeScript fanout） |
| `proxy-gate/` | 代理网关（gate.sh，含 backups/） |
| `proxy-timeout-fix/` | 代理超时修复（deploy/rollback，含 backups/） |

> [!note] diagnostic-relay 双版本说明
> 源仓库根 `diagnostic-relay/` 与 `deployments/diagnostic-relay/` 的 `README.md`、`relay.js` 内容一致，仅 `rollback.sh` 不同。迁移时两版均保留：
> - `rollback.sh` — 增强版（deployments 版，追踪 relay.port、清理残留 relay 进程、4 步验证）
> - `rollback-basic.sh` — 基础版（根目录原版，3 步流程）

## 部署四规则（摘录自 deployment-framework.md）

每次生产环境改动必须满足四个条件，缺一不可：

| # | 规则 | 含义 |
|---|------|------|
| 1 | **记录可追溯** | 改动前 git commit，描述 What/Why/How |
| 2 | **部署前验证** | deploy.sh 含预检步骤，验证通过才执行 |
| 3 | **逃生机制** | rollback.sh 可一键恢复到部署前状态 |
| 4 | **日志可审计** | 每次部署/逃生写入 deployment-log.md |

> [!tip] 本规则已同步写入 [[AGENTS#五·五、远程知识库融合补充规范（2026-08-17）|AGENTS 融合补充规范]]，适用于本 Vault `scripts/` 目录治理。

## 脱敏与 git 说明

| 内容 | 处理 |
|------|------|
| `dumps/` → `scripts/claude-ops-dumps/` | 已脱敏（README 注明），由 `.gitignore` 排除，本地保留不上传 |
| `**/backups/`（proxy-gate、proxy-timeout-fix） | 部署前原始文件备份，由 `.gitignore` 排除 |
| `*.pyc` / `__pycache__/` | 迁移时已排除，目标 0 残留，`.gitignore` 兜底 |
| `_install-tmp/` | 迁移源本身不进入 git |

> [!warning] 推送前必须脱敏（占位符替换密码/IP/API 端点），详见 [[AGENTS]] 敏感信息推送规则。

## 相关链接

- [[Claude-Ops-KB-Home]] — Claude Code 运维子 Vault 首页
- [[AGENTS]] — 知识库 AI 协作规范（含部署四规则）
- [[deployment-framework|deployment-framework.md]] — 部署管控框架原文
- `deployment-log.md` — 部署/逃生审计日志（四规则之"日志可审计"）
