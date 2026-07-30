# 多 PRoot Session 架构 — 发现与设计补充

> 日期: 2026-07-09 | 来源: 生产环境两 session 并行运行观察

---

## 关键发现

### 1. 真正的跨 session 隔离存在且可验证

```
$ grep TracerPid /proc/self/status
TracerPid: 19742

同一 pid 的 TracerPid 相同 → 同 session → 共享 ptrace 链
不同 TracerPid → 不同 session → 独立 I/O 路径
```

当前 2 个 session 并行运行，各自的 claude 进程 TracerPid 不同。

### 2. 当前 session 可能有多个 claude 进程

Session 1 中同时存在 19815 (DNl+) 和 21996 (RN+)。两者共享同一 TracerPid → 共享 I/O 路径。当其中一个进入 D-state，虽然不阻塞另一个的 CPU 调度，但共享的 I/O 路径可能受影响。

### 3. D-state 在跨 session 时不传染

PID 30335 在 Session 2 中 SNl+（正常 sleep），而 Session 1 的 19815 是 DNl+（D-state）。两者的 I/O 路径独立 → D-state 不跨 session 传染。**验证了跨 session 隔离的核心假设。**

### 4. 当前 nice 问题

Session 1 中的 21996 (活跃) 和 19815 (D-state) 都是 nice=5。按照设计，相同 session 内的所有"非主"claude 进程应被降权。但当前逻辑只跳过一个主 PID (19815)，导致 21996 也被降权。

**同一个 session 内可能有两个 claude 进程都是"主"的** — 一个阻塞在 D-state，另一个在运行。当前单 PID 排除不够。

---

## 设计改进

### 改进 1: TracerPid 感知的主 PID 检测

不再依赖进程树遍历或 pgrep 模式匹配，改用 TracerPid 精确识别：

```bash
get_self_tracer() {
    grep TracerPid /proc/self/status 2>/dev/null | awk '{print $2}'
}

# 获取当前 session 中所有 claude 进程
get_self_session_pids() {
    local self_tracer
    self_tracer=$(get_self_tracer)
    for pid in $(pgrep -x claude 2>/dev/null); do
        local pid_tracer
        pid_tracer=$(grep TracerPid /proc/$pid/status 2>/dev/null | awk '{print $2}')
        [ "$pid_tracer" = "$self_tracer" ] && echo "$pid"
    done
}

# 获取其他 session 中的 claude 进程
get_other_session_pids() {
    local self_tracer
    self_tracer=$(get_self_tracer)
    for pid in $(pgrep -x claude 2>/dev/null); do
        local pid_tracer
        pid_tracer=$(grep TracerPid /proc/$pid/status 2>/dev/null | awk '{print $2}')
        [ "$pid_tracer" != "$self_tracer" ] && echo "$pid"
    done
}
```

### 改进 2: 同 session 进程全部排除 renice

`do_prioritize()` 应排除**所有**当前 session 的 claude 进程，而非仅一个主 PID。因为同 session 内的任何降权都无助于 I/O 竞争（它们共享 ptrace 链，瓶颈在内核 I/O 而非 CPU）。

只有**其他 session** 的 claude 进程才应被降权（降低它们抢占全局 CPU 和内存的能力）。

```bash
do_prioritize() {
    local self_tracer target_nice
    self_tracer=$(get_self_tracer)
    # ... determine target_nice based on state ...
    
    for pid in $(pgrep -x claude 2>/dev/null); do
        local pid_tracer
        pid_tracer=$(grep TracerPid /proc/$pid/status 2>/dev/null | awk '{print $2}')
        
        # 当前 session 的所有进程: 跳过 (不降权自己人)
        [ "$pid_tracer" = "$self_tracer" ] && continue
        
        renice -n "$target_nice" -p "$pid" 2>/dev/null || true
        ionice -c $target_ionice -p "$pid" 2>/dev/null || true
    done
}
```

### 改进 3: 跨 session 子代理计数分离

`do_count()` 和 `do_check()` 应区分同 session 和其他 session 的进程：

- 同 session 子代理：受内存/CPU 限制约束（共享资源）
- 其他 session 子代理：不受当前 session 门控限制（独立资源）

```bash
# 只统计当前 session 的 claude 进程
count_self_session_procs() {
    get_self_session_pids | wc -l
}
```

`s/MAX_TOTAL_PROCS` 只对同 session 进程生效。其他 session 的进程数不影响当前 session 的 spawn 决策。

### 改进 4: D-state 按 session 区分告警

- 同 session 的 D-state → CRITICAL（直接影响当前交互）
- 其他 session 的 D-state → WARNING（影响全局 I/O，但不直接阻塞当前 session）

---

## 不做的事

- 不杀任何进程
- 不修改 PID 文件（除非新代码部署后自然更新）
- 不改变跨 session 通信协议（文件轮询已验证可行）

## 实施路径

1. 先改 `get_self_tracer()` + `get_self_session_pids()` → 测试
2. 改 `do_prioritize()` → 排除同 session 所有进程
3. 改 `do_count()` → 只统计同 session
4. 改 D-state 告警 → 区分 session
