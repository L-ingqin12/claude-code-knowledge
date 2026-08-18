# Agent Gate — Hook 配置参考

子代理资源门控 (Phase 2 + 2b) 的 Hook 配置说明。本组件依赖
`/root/workspace/agent-knowledge-base/claude-agent-gate.sh`，通过 Claude Code
的 hook 系统实现交互感知的并发控制。

---

## 状态流转

```
   ┌──────────────────────────────────────────────────────────┐
   │                     SessionStart                         │
   │  ┌────────── cleanup orphans ──→ mark-idle ──────────┐   │
   │  │ 更新 state=idle, 恢复子代理 nice=0                 │   │
   │  └────────────────────────────────────────────────────┘   │
   └──────────┬───────────────────────────────────────────────┘
              │
              ▼
       ┌──────────────┐         PreToolUse (无 matcher)
       │              │─────────────────────────────────►
       │    idle       │     mark-interactive: state=interactive
       │  (nice=0)     │     子代理 renice 19 + ionice idle
       │              │◄─────────────────────────────────
       └──────────────┘              Stop
           │     ▲            mark-idle: state=idle
           │     │            子代理 renice 0 + ionice best-effort
           │     │
           │     └────────────────────┘
           │
           │           PreToolUse (delegate_task)
           │    ┌─────────────────────────────────►
           │    │   check → cleanup → read-state → count → memcheck
           │    │     通过 → spawn (子代理进入 idle)
           │    │     拒绝 → 返回 DENY (不 spawn)
           ▼    │
       ┌────────┴────────┐
       │  交互状态:       │
       │  interactive    │
       │  (nice=19)      │
       │                  │
       │  子代理:         │
       │  idle (nice=0)   │
       └──────────────────┘
```

- **idle**: Claude 未在回复或后台子代理执行中。子代理以正常优先级运行。
- **interactive**: Claude 正在回复用户。子代理被降权 (renice 19 + ionice idle)，
  确保主 session 的响应速度。

---

## 需要的 Hook

| Hook | Matcher | 命令 | 作用 |
|------|---------|------|------|
| `SessionStart` | (无) | `cleanup` + `mark-idle` | 清理上次残留的孤儿进程，初始化 idle 状态 (append 到已有配置) |
| `PreToolUse` | (无) | `mark-interactive` | 标记交互状态，降权已有子代理 — 所有工具共用 |
| `PreToolUse` | `delegate_task` | `check` | 组合门控 — 仅子代理 spawning 前执行资源检查 |
| `Stop` | (无) | `mark-idle` | 标记空闲状态，恢复子代理优先级 |

### 为什么需要这些 Hook

1. **`SessionStart`**: 每次新 session 开始时确保环境干净。
   - `cleanup` 杀死孤儿 claude 进程 (PPID=1, 存活>120s)，防止进程泄漏。
   - `mark-idle` 初始化状态文件，避免沿用上次的过期状态。

2. **`PreToolUse` (无 matcher)**: 用户每次交互前标记 interactive。
   - 所有工具执行前都会触发，确保主 session 获得最高优先级。
   - 已有子代理通过 `renice 19 + ionice idle` 降权，不影响用户操作。

3. **`PreToolUse` (delegate_task)**: 子代理 spawning 前的资源检查。
   - 仅 `delegate_task` 工具触发，不干扰其他工具。
   - 组合门控: cleanup → read-state → count → memcheck。
   - 交互状态为 interactive 时拒绝 spawn，避免子代理与主 session 竞争。

4. **`Stop`**: Claude 停止回复时标记 idle。
   - 子代理恢复 `nice=0 + ionice best-effort`，充分利用空闲资源执行后台任务。

### 为什么 delegate_task 的 hook 没有 run-before/run-after

Claude Code hook 系统不支持 `run-before`/`run-after` 属性。
所有 PreToolUse hook 在工具执行前同步执行。hook 的退出码不影响工具的
执行 — 资源门控的状态判断由 `claude-agent-gate.sh` 内部处理，拒绝信号
通过 `read-state` 的交互状态文件传递。

---

## 合并到 settings.local.json

### 目标文件

```
/root/.claude/settings.local.json
```

### 合并步骤

1. 备份当前配置:
   ```bash
   cp /root/.claude/settings.local.json /root/.claude/settings.local.json.bak
   ```

2. 编辑 `settings.local.json`，将 `hooks-reference.json` 中的 `hooks` 节合并到
   顶层 JSON。现有的 `SessionStart` hook (版本检查) 保留不动，新增的 hook 追加
   在数组末尾。

3. 验证 JSON 格式:
   ```bash
   python3 -m json.tool /root/.claude/settings.local.json >/dev/null && echo "OK" || echo "INVALID"
   ```

4. 将脚本中的 `/root/workspace/agent-knowledge-base/` 路径替换为实际部署路径。
   推荐将 `claude-agent-gate.sh` 复制到固定位置:
   ```bash
   cp /root/workspace/agent-knowledge-base/claude-agent-gate.sh /root/claude-agent-gate.sh
   ```
   然后更新 hook 命令中的路径。

### 合并后的结构示例

```json
{
  "env": { ... },
  "permissions": { ... },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash /root/claude-version-hook.sh full 2>/dev/null || true" }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash /root/claude-agent-gate.sh cleanup 2>/dev/null || true; bash /root/claude-agent-gate.sh mark-idle 2>/dev/null || true" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "bash /root/claude-agent-gate.sh mark-interactive 2>/dev/null || true" }
        ]
      },
      {
        "matcher": "delegate_task",
        "hooks": [
          { "type": "command", "command": "bash /root/claude-agent-gate.sh check 2>/dev/null || true" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash /root/claude-agent-gate.sh mark-idle 2>/dev/null || true" }
        ]
      }
    ]
  }
}
```

---

## 验证 hooks 是否工作

### 1. SessionStart 验证

启动一个新 session:
```bash
claude -p "echo hello"
```

检查状态文件是否创建:
```bash
cat /root/.claude/session-state.json
```
预期输出: `{"state":"idle","epoch":<ts>,"hook":"Stop"}`

### 2. PreToolUse 验证

执行任意工具 (如 `echo`):
```bash
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh read-state
```
预期输出: `read-state: interactive (<n>s ago)`

### 3. delegate_task 门控验证

模拟交互状态:
```bash
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh mark-interactive
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh check
```
预期输出: `{"status":"DENY","reason":"interactive state",...}`

模拟空闲状态:
```bash
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh mark-idle
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh check
```
如果资源充足，预期输出: `{"status":"OK","reason":"resources sufficient",...}`

### 4. Stop 验证

claude 回复完成后，检查状态是否恢复为 idle:
```bash
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh read-state
```
预期输出: `read-state: idle (<n>s ago)`

### 5. 完整 E2E 验证

```bash
# 模拟完整生命周期
echo "=== 模拟 SessionStart ==="
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh cleanup
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh mark-idle
echo "状态: $(bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh read-state)"

echo "=== 模拟 PreToolUse (用户交互) ==="
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh mark-interactive
echo "状态: $(bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh read-state)"

echo "=== 模拟 delegate_task ==="
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh check
echo "exit code: $?"

echo "=== 模拟 Stop ==="
bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh mark-idle
echo "状态: $(bash /root/workspace/agent-knowledge-base/claude-agent-gate.sh read-state)"
```

---

## Rollback 指令

### 紧急回滚 (还原配置)

```bash
# 从备份恢复
cp /root/.claude/settings.local.json.bak /root/.claude/settings.local.json

# 如果没有备份，手动删除新增的 hooks
# 编辑 settings.local.json，移除:
#   - SessionStart 数组中新增的 cleanup+mark-idle 条目
#   - PreToolUse 整个键
#   - Stop 整个键
```

### 保留状态文件但移除 hooks (调试用)

```bash
# 只移除 hook 执行权，但保留状态文件供手动调试
# 将 hooks 节中的命令注释掉或移除对应的 hooks 键
```

### 清理残留状态文件

```bash
rm -f /root/.claude/session-state.json /tmp/claude-agent-gate-cooldown
```

### 验证回滚

```bash
# 确认 hook 已移除
cat /root/.claude/settings.local.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
hooks=d.get('hooks',{})
print('SessionStart count:', len(hooks.get('SessionStart',[])))
print('PreToolUse present:', 'PreToolUse' in hooks)
print('Stop present:', 'Stop' in hooks)
"
```

---

## 状态文件格式

`/root/.claude/session-state.json`:
```json
{
  "state": "interactive" | "idle",
  "epoch": 1234567890,
  "hook": "PreToolUse" | "Stop" | "manual"
}
```

- `epoch`: Unix 时间戳 (秒)，用于过期检测 (TTL=120s)。
- `hook`: 最后修改状态文件的 hook 名，辅助调试。
- 文件损坏或过期时默认为 `interactive` (安全默认)。

---

## 相关文件

| 文件 | 作用 |
|------|------|
| `../../claude-agent-gate.sh` | 门控脚本 (实际执行体) |
| `hooks-reference.json` | Hook 配置参考 (本目录) |
| `README.md` | 本文档 |
