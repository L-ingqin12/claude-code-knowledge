---
title: DeepSeek 400 规避与恢复 — 使用说明
aliases: [DeepSeek 400 使用说明, sanitize-session 使用说明, cache-relay 兜底使用, 消毒脚本使用说明]
tags: [ai/ops, ai/agent]
created: 2026-09-06
updated: 2026-09-06
status: review
---

# DeepSeek 400 规避与恢复 — 使用说明

See also: [[deepseek-400-mitigation-design]] · [[claude-cache-relay-design]] · [[Claude-Ops-KB-Home]]

> [!abstract] 概述
> 本文是 [[deepseek-400-mitigation-design]] 的**速查手册**：三层方案（预防/恢复/兜底）的日常用法、架构图、消毒脚本命令速查。根因、源码级决策与 todo 见设计文档。

## 一、架构信息

```
Claude Code
   │  settings.local.json: ANTHROPIC_BASE_URL = http://127.0.0.1:8790
   ▼
┌──────────────────────────────────────────────────────┐
│ cache-relay（cache-relay.mjs，常驻 :8790）              │
│  ① 缓存对齐（提升 DeepSeek 前缀命中率）                 │
│     判源 detectProvider → alignRequest：               │
│       · deepseek/glm：剥 cache_control + 工具排序 +      │
│         日期稳定化 + env/易变块搬迁                      │
│       · anthropic：保留断点，只排序+稳定                │
│       · openrouter/generic：仅确定性排序                │
│  ② 内容审核 400 兜底                                    │
│      命中 400 + "content exists risk" → 改投备用源       │
└──────────────────────────────────────────────────────┘
   │ 默认（纯透传）             │ 仅兜底（最后手段）
   ▼                            ▼
 DeepSeek 官方                OpenRouter
 api.deepseek.com/anthropic   openrouter.ai/api → z-ai/glm-5.3-flash
```

**关键配置**（均在本地，不进仓库）：
- `~/.cache-relay/config.json` — `defaultUpstream`（DeepSeek）+ `fallback` 块（`upstream`/`modelMap`/`riskKeywords`/`authTokenSource`）
- `authTokenSource` 指向 `~/.claude/oxalpha-settings.json`，运行时读 OpenRouter key（密钥不落地到 relay 配置）

**三层防护关系**：预防（不触发）→ 恢复（触发后清毒回 DeepSeek）→ 兜底（清不掉才切 GLM）。

## 二、整体使用说明

| 层 | 你平时做什么 | 说明 |
|---|---|---|
| **预防** | 聊天时不贴裸节点域名/`host:port`/订阅链接，改用文件路径引用 + 伪名 | 已写进全局 `CLAUDE.md` 会话红线，自动生效 |
| **恢复** | 会话被 400 打死时，跑 `sanitize-session.py` 清毒 → `claude --continue` | 见 §三专用说明 |
| **兜底** | **无需操作** | 自动生效：命中审核 400 自动改投 GLM，会话不死 |

### cache-relay 运维命令

目录 `D:\Document\local\knowledge\scripts\claude-ops-deployments\cache-relay\`：

```bash
node cache-relay.mjs deploy      # 热部署（清 .disabled + 起守护）
node cache-relay.mjs stop        # 停（读 pid kill）
node cache-relay.mjs undeploy    # 软回滚（写 .disabled + 停守护，不删文件）
node cache-relay.mjs doctor [baseUrl] [model]   # 判源自测
node cache-relay.mjs start       # 前台启动（看日志）
bash deploy.sh rollback          # 软回滚 + 恢复 settings.local.json 备份
bash deploy.sh status            # 状态
```

> [!tip] 逃生阀
> `touch ~/.cache-relay/.disabled` 或 `RELAY_DISABLED=1`（停中继）；`RELAY_FORCE_PROVIDER=passthrough`（全直通不做对齐）。软回滚优先，**绝不删脚本**。

## 三、消毒脚本 `sanitize-session.py` 使用说明

位置 `D:\Document\local\knowledge\network\scripts\sanitize-session.py`，解释器 `D:\ProgramData\miniconda3\python.exe`。

### 命令速查

```bash
PY="D:/ProgramData/miniconda3/python.exe"
SCRIPT="D:/Document/local/knowledge/network/scripts/sanitize-session.py"

# 1. 只读扫描（先看有没有毒，绝不写文件）
$PY $SCRIPT --check                       # 扫当前目录最近会话
$PY $SCRIPT --check --session <id前缀>     # 扫指定会话

# 2. 脱敏（自动备份 + 指纹校验 + 原子写）
$PY $SCRIPT                              # 脱敏最近会话（safe 模式）
$PY $SCRIPT --session <id前缀>            # 指定会话
$PY $SCRIPT --mode aggressive            # 额外套话题词 + scheme:// 链接清洗
$PY $SCRIPT --replace-str '<占位>'         # 自定义占位符（默认 [节点已脱敏]）
```

### 完整恢复流程（会话被 400 打死时）

```
1. 退出该会话（必须：文件被占用 + 每轮仍复发）
2. 会话原目录跑  $PY $SCRIPT            # 自动备份 .pre-sanitize-<ts>.jsonl
3. 确认       $PY $SCRIPT --check       # 应报"命中行 0"
4. 同目录     claude --continue         # 用不涉敏措辞续聊
```

### 它做什么 / 不做什么

- ✅ 只做**整行原始文本的子串替换**（节点域名 → `[节点已脱敏]`），**绝不删行、不改 uuid/tool_use↔tool_result 配对** → JSON 结构天然不坏
- ✅ 触发词**运行时现读** `node-pool.txt` + `proxy-nodes.json`，新节点自动进表；话题词走 `sanitize-extra.txt`（`--mode aggressive` 才启用）
- ✅ 安全闸门：改前备份 → 逐行 `json.loads` 校验 → 结构指纹前后对比 → 原子写，任一失败即回滚
- ❌ 不打印命中行内容（`--check` 只报行数，避免脚本自己再踩审核红线）

## 四、常见场景速查

| 场景 | 动作 |
|---|---|
| 会话突然报 `400 Content Exists Risk` | 先看是否被兜底自动续上（日志 `[cache-relay] 400 risk → fallback`）；若想回 DeepSeek → 跑消毒脚本 + `--continue` |
| 想提前知道某会话有没有毒 | `$PY $SCRIPT --check --session <id>` |
| 新节点加入后想纳入脱敏 | 无需操作，脚本运行时现读 `node-pool.txt`/`proxy-nodes.json` |
| 兜底想把某类话题词也脱敏 | 往 `sanitize-extra.txt` 加一行词 |
| 怀疑 cache-relay 出问题 | `touch ~/.cache-relay/.disabled` 或 `RELAY_FORCE_PROVIDER=passthrough` 逃生 |
| 彻底停用兜底 | 删 `~/.cache-relay/config.json` 的 `fallback` 块，或 `undeploy` |
