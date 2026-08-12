---
name: deploy-workflow-write-to-repo-first
description: 代码变更工作流规则：先在归档仓库编写测试，用户确认后再部署到生产路径
metadata: 
  node_type: memory
  type: feedback
  tags: 
    - workflow
    - deploy
    - safety
    - repo-first
  priority: high
  trigger: before-any-code-change
  originSessionId: b6eb8d1f-ac12-442d-8dc9-1a516ba4bad1
---

# 代码变更工作流：先仓库，后部署

## 规则

所有代码变更（proxy.js、agent-gate.sh、hook 配置、deploy 脚本等）必须遵循：

1. **先在归档仓库编写** — 所有代码在 `~/workspace/agent-knowledge-base/` 中完成编写和测试
2. **测试没问题** — 在仓库中验证语法、逻辑、边界条件
3. **用户确认** — 向用户展示变更内容，等待确认
4. **再执行部署** — 用户确认后，通过 `deploy.sh` 或手动 `cp` 部署到生产路径

## 禁止事项

- ❌ 直接在 `/root/claude-resilience-proxy.js` 等生产路径编辑
- ❌ 未经用户确认就修改 `/root/.claude/settings.local.json`
- ❌ 未先在仓库提交就执行 `kill`/重启生产服务

## 当前状态

- **崩溃改进方案**: 已设计完成（`plans/crash-improvement-plan-2026-07-03.md` + `plans/interactive-aware-subagent-plan-2026-07-03.md`），等待用户准备好后开始编码
- **所有实施工作**: 暂停中，等用户指令

## 来源

用户 2026-07-03 明确要求："后续编写时先在归档仓编写，测试没问题后由用户确认后再执行部署，先暂时不开始，等用户准备好后再尝试开始编码以及编写"

**Why:** 防止 [[proxy-cancelretry-hook-incident]] 事故重演 — 那次事故的直接原因就是在生产路径直接编辑 proxy.js，无 git 追踪、无隔离测试、无用户确认。
**How to apply:** 任何代码变更前，先在 `~/workspace/agent-knowledge-base/` 中完成，`git commit`，向用户展示 diff，等确认后再部署。
