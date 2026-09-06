---
title: Claude Code 缓存优化 — 会话策略
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-16
updated: 2026-08-25
status: review
---

# Claude Code 缓存优化 — 会话策略

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-optimization]] · [[PERMAFROST_MODIFICATIONS]]

> 更新: 2026-06-16 | CC 版本: v2.1.174 (pinned)

---

## 一、核心原理

DeepSeek 前缀缓存 = `sha256(tools + system + params)` → 逐字节匹配，从第 0 字节起。

```
缓存锚点 = tools (排序后) + system block[0] + system block[1] + params(model/max_tokens/...)
```

**锚点不变 → 缓存命中。锚点变了 → 全量 miss。**

---

## 二、版本升级策略

### 规则：不在生产环境自动升级

```bash
# 已配置 (settings.local.json)
CLAUDE_CODE_SKIP_UPDATE_CHECK=1
```

### 升级前检查清单

1. 在隔离环境安装新版本
2. 发一条请求，dump 工具集：`cat /root/.permafrost/dumps/req-XXX.json | jq '.tools[].name'`（注: req-XXX.json 为占位符，XXX 替换为实际 dump 文件名）
3. 对比工具集是否变化
4. 如果工具集变了 → 新锚点 → 需要接受 24-48h 的冷启动成本
5. 如果工具集不变 → 安全升级，缓存不受影响
6. 升级后监控 DeepSeek 后台 24h，命中率 < 85% → rollback

```bash
# 升级
bash /root/claude-version-switch.sh install 2.1.XXX    # 先安装
# 隔离测试通过后
bash /root/claude-version-switch.sh 2.1.XXX             # 切换

# 回滚
bash /root/claude-version-switch.sh rollback
```

---

## 三、工具集稳定性策略

### 规则：所有 session 使用相同工具集

v2.1.174 基准锚点工具集 (9 tools):
```
Agent, AskUserQuestion, Bash, Edit, Read, Skill, ToolSearch, Workflow, Write
```

> [!note] 口径注: 锚点工具为 9 个（与 [[hermes-cache-analysis]]/[[PERMAFROST_MODIFICATIONS]] 口径一致）；ScheduleWakeup 属变数工具，排在锚点集末尾，不参与锚点定义。

**禁止**：
- 在 session 中途添加/移除工具
- 不同 session 使用不同工具配置
- MCP 服务器动态连接（导致工具顺序变化 — permafrost 已处理排序，但工具数量变化仍会产生新锚点）

### 如果必须使用不同工具集

接受新锚点的冷启动成本。每个新工具组合的前 10-20 次请求命中率会偏低，之后逐步回升。

---

## 四、会话生命周期策略

### 长 session 优先

```
短 session (1-5 轮):    冷启动成本占比高 → 命中率 ~50%
中 session (10-50 轮):  冷启动被摊平 → 命中率 ~85-95%  
长 session (50+ 轮):    冷启动可忽略 → 命中率 ~95-99%
```

**实操**：
- 使用 `/resume` 复用长 session，避免频繁新建
- `/compact` 不触发则不主动执行（compaction 重写 msg[0] → 缓存失效）
- 子 agent 任务合并执行，减少 flash 模型冷启动次数

### 跨天策略

`currentDate` 已在 permafrost 层稳定化为 `2000-01-01`，跨天不再破坏缓存 ✅

---

## 五、监控与告警

### 自动监控（已部署）

```bash
# 每 60s 检查，命中率 < 70% → 自动 dump
bash /root/claude-cache-monitor.sh daemon
```

### 手动检查

```bash
bash /root/claude-cache-monitor.sh status   # 监控状态 + dump 历史
curl -s http://127.0.0.1:8788/permafrost/stats | jq .hit_rate  # 实时命中率
```

### DeepSeek 后台告警阈值

| 模型 | 正常 | 关注 | 告警 |
|------|------|------|------|
| Pro | >95% | 85-95% | <85% |
| Flash | >80% | 60-80% | <60% |

---

## 六、恢复手册

### 命中率骤降 → 排查顺序

1. `bash /root/claude-cache-monitor.sh status` — 检查自动 dump
2. `curl -s http://127.0.0.1:8788/permafrost/doctor` — 看 anchor 是否变化
3. `ls /root/.permafrost/dumps/ | wc -l` — 确认有新请求在捕获
4. 对比最新 dump 的 tools 列表
5. DeepSeek 后台确认是 pro 还是 flash 下降
6. 如果是版本升级导致 → `claude-version-switch.sh rollback`
7. 如果是 compaction → 正常现象，等恢复
8. 如果是 proxy 故障 → `claude-permafrost-rollback.sh` (C→B)

### 完全重置

```bash
bash /root/claude-permafrost-rollback.sh nuke   # 停止所有代理，CC 直连 DeepSeek
# 等环境稳定后
bash /root/claude-permafrost-deploy.sh start    # 重新部署方案 C
```
