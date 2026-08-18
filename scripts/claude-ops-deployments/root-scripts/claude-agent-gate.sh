#!/bin/bash
# ============================================================================
# Agent Resource Gate — 子代理资源门控 (Phase 2 + 2b)
# ============================================================================
# 子命令:
#   cleanup          — 清理孤儿 claude 进程 (PPID=1, age>120s)
#   count            — 计数 claude 进程 (含当前, max=4)
#   memcheck         — 检查 MemAvailable (RED<800MB, YELLOW<1200MB)
#   status           — 单行状态摘要
#   check            — 组合门控: cleanup → read-state → count → memcheck
#   mark-interactive — 标记交互状态 (PreToolUse hook)
#   mark-idle        — 标记空闲状态 (Stop hook)
#   read-state       — 读取交互状态 (含过期检测)
#   prioritize       — 根据状态 renice/ionice 子代理
#   acquire          — 获取资源锁 (Phase 2d)
#   release          — 释放资源锁 (Phase 2d)
#   lock-status      — 查看资源锁状态 (Phase 2d)
#   detect           — 检测命令资源类别 (Phase 2d)
# ============================================================================
# 退出代码:
#   0 = 通过 (可 spawn) | 1 = 警告 (降级) | 2 = 拒绝 (不 spawn)
#   其他 = 故障安全 (允许, 不阻塞操作)
# ============================================================================
set +e

# ── 配置常量 ────────────────────────────────────────────────────────
MIN_MEM_GREEN=1200          # MB, 允许全部并发
MIN_MEM_RED=800             # MB, 拒绝新子代理
SWAP_RED=70                 # swap% 硬拒绝 (临界压力)
SWAP_YELLOW=55              # swap% 警告 (中度压力)
MARK_THROTTLE_SEC=3         # mark-interactive 节流窗口秒数
INTERACTIVE_NICE_SOFT=5      # interactive 初始 nice 值 (温和)
INTERACTIVE_NICE_HARSH=19    # interactive 持续>15s 后的 nice 值 (激进)
INTERACTIVE_HARSH_DELAY=15   # 切换到激进 nice 的等待秒数
IDLE_RESTORE_DELAY=30        # idle 状态完全恢复 nice=0 的等待秒数
MAX_TOTAL_PROCS=4           # 含父进程的 claude 进程总数上限 (idle)
MAX_INTERACTIVE_PROCS=3     # 含父进程的进程总数上限 (interactive, 仅1个子代理)
ORPHAN_AGE=120              # 孤儿进程最小存活秒数
STATE_TTL=120               # 状态文件过期秒数
STATE_FILE="/root/.claude/session-state.json"
MAIN_PID_FILE="/root/.claude/main-pid"       # 主 claude session PID (SessionStart 写入)
COOLDOWN_FILE="/tmp/claude-agent-gate-cooldown"
COOLDOWN_SEC=5              # spawn 冷却窗口 (缓解竞态)

# Phase 2d: 资源类锁
RESOURCE_LOCK_DIR="/tmp/claude-resource-locks"
RESOURCE_PATTERNS_CONF="/root/.claude/resource-patterns.conf"
LOCK_TTL=600                # 锁文件过期秒数 (10min)
NET_MAX=2                   # 网络类最大并发
SPIN_INTERVAL=0.5           # 自旋等待间隔秒数
SPIN_DEFAULT_TIMEOUT=30     # 默认自旋超时秒数
CPU_LOAD_THRESHOLD=4.0      # loadavg 阈值 (自动检测用)

# ── 工具函数 ────────────────────────────────────────────────────────

now_ts() { date -u +%s 2>/dev/null || echo 0; }

# 安全计数 claude 进程 (容错 pgrep 不可用)
count_claude_procs() {
    pgrep -x claude 2>/dev/null | wc -l || echo 0
}

# 计数 D 状态 (uninterruptible sleep) 的 claude 进程 (PRoot I/O 瓶颈检测)
count_d_state_claude() {
    local count=0
    for pid in $(pgrep -x claude 2>/dev/null); do
        ps -o stat= -p "$pid" 2>/dev/null | grep -q 'D' && count=$((count + 1))
    done
    echo "$count"
}

# 读取 MemAvailable (kB → MB), 容错 /proc 不可读
read_mem_available_mb() {
    local val
    val=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        echo $((val / 1024))
    else
        # 退而求其次: MemFree + Cached
        local free cached
        free=$(awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        cached=$(awk '/^Cached/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        echo $(((free + cached) / 1024))
    fi
}

# 读取 Swap 使用率 (%)
read_swap_pct() {
    local total free used
    total=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    free=$(awk '/SwapFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$total" -gt 0 ] 2>/dev/null; then
        used=$((total - free))
        echo $((used * 100 / total))
    else
        echo 0
    fi
}

# 走 PPID 链找到真正的 claude 祖先 PID (绕过中间 shell)
find_main_claude_pid() {
    local pid=$$
    while [ "$pid" -gt 1 ] 2>/dev/null; do
        local ppid
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$ppid" ] || [ "$ppid" -le 1 ] 2>/dev/null && break
        if ps -o comm= -p "$ppid" 2>/dev/null | grep -qx 'claude'; then
            echo "$ppid"
            return 0
        fi
        pid=$ppid
    done
    echo ""
    return 0
}

# 获取主 claude PID (优先读文件, 回退走进程树)
get_main_pid() {
    if [ -f "$MAIN_PID_FILE" ]; then
        local saved_pid
        saved_pid=$(cat "$MAIN_PID_FILE" 2>/dev/null)
        if [ -n "$saved_pid" ] && kill -0 "$saved_pid" 2>/dev/null; then
            echo "$saved_pid"
            return 0
        fi
    fi
    # 回退: 走进程树
    find_main_claude_pid
}

# 保存主 claude PID 到文件 (SessionStart/hook 调用, 总是覆盖)
save_main_pid() {
    local pid
    pid=$(find_main_claude_pid)
    if [ -n "$pid" ]; then
        echo "$pid" > "$MAIN_PID_FILE" 2>/dev/null || true
    fi
    # 如果走进程树失败，用 pgrep 找最老的 claude --resume 进程
    if [ -z "$pid" ]; then
        pid=$(pgrep -f "claude.*--resume" 2>/dev/null | head -1)
        [ -n "$pid" ] && echo "$pid" > "$MAIN_PID_FILE" 2>/dev/null || true
    fi
}

# 检查冷却窗口 (防止竞态: 两次 check 间隔太短)
check_cooldown() {
    local now cooldown_ts elapsed
    now=$(now_ts)
    if [ -f "$COOLDOWN_FILE" ]; then
        cooldown_ts=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
        elapsed=$((now - cooldown_ts))
        if [ "$elapsed" -lt "$COOLDOWN_SEC" ] 2>/dev/null; then
            return 1  # 冷却中
        fi
    fi
    return 0  # 冷却已过
}

# 设置冷却时间戳
set_cooldown() {
    now_ts > "$COOLDOWN_FILE" 2>/dev/null || true
}

# ── Phase 2d: 资源锁工具函数 ──────────────────────────────────────

# 确保锁目录存在
lock_dir_init() {
    mkdir -p "$RESOURCE_LOCK_DIR" 2>/dev/null || true
}

# 读取锁文件内容 "PID EPOCH"
lock_read() {
    local lockfile="$1"
    [ -f "$lockfile" ] && cat "$lockfile" 2>/dev/null || echo ""
}

# 原子写入锁文件 (tmpfile + mv 防撕裂)
lock_write() {
    local lockfile="$1" pid="$2"
    local tmpfile="${lockfile}.tmp.$$"
    echo "$pid $(now_ts)" > "$tmpfile" 2>/dev/null && mv "$tmpfile" "$lockfile" 2>/dev/null || true
}

# 删除锁文件
lock_remove() {
    rm -f "$1" 2>/dev/null || true
}

# 检查 PID 是否存活
lock_pid_alive() {
    kill -0 "$1" 2>/dev/null
}

# 获取锁对应的资源类名
lock_class_from_file() {
    basename "$1" | sed 's/\..*//'
}

# 检查指定资源类的锁是否被活跃进程持有
# 返回: 0=被持有 (held), 1=空闲 (free)
lock_is_held() {
    local class="$1"
    local lockfile="$RESOURCE_LOCK_DIR/${class}.lock"
    local content pid ts age

    # net 类是计数器, 特殊处理
    if [ "$class" = "net" ]; then
        local countfile="$RESOURCE_LOCK_DIR/net.count"
        local count
        count=$(cat "$countfile" 2>/dev/null || echo 0)
        [ "$count" -ge "$NET_MAX" ] 2>/dev/null && return 0
        return 1
    fi

    # mem 用 .flag
    [ "$class" = "mem" ] && lockfile="$RESOURCE_LOCK_DIR/mem.flag"

    content=$(lock_read "$lockfile")
    [ -z "$content" ] && return 1  # 锁文件不存在 = 空闲

    pid=$(echo "$content" | awk '{print $1}')
    ts=$(echo "$content" | awk '{print $2}')
    age=$(($(now_ts) - ts))

    # 过期检测
    [ "$age" -gt "$LOCK_TTL" ] 2>/dev/null && { lock_remove "$lockfile"; return 1; }

    # PID 存活检测
    lock_pid_alive "$pid" 2>/dev/null || { lock_remove "$lockfile"; return 1; }

    return 0  # 被活跃进程持有
}

# 检查锁是否被自身持有 (重入检测)
lock_is_held_by_me() {
    local class="$1"
    local lockfile="$RESOURCE_LOCK_DIR/${class}.lock"
    [ "$class" = "mem" ] && lockfile="$RESOURCE_LOCK_DIR/mem.flag"

    local content pid
    content=$(lock_read "$lockfile")
    [ -z "$content" ] && return 1
    pid=$(echo "$content" | awk '{print $1}')
    [ "$pid" = "$$" ] && return 0
    return 1
}

# 清理过期/僵尸锁
lock_cleanup_stale() {
    lock_dir_init
    for lockfile in "$RESOURCE_LOCK_DIR"/*.lock "$RESOURCE_LOCK_DIR"/*.flag; do
        [ -f "$lockfile" ] || continue
        local content pid ts age
        content=$(lock_read "$lockfile")
        [ -z "$content" ] && { lock_remove "$lockfile"; continue; }
        pid=$(echo "$content" | awk '{print $1}')
        ts=$(echo "$content" | awk '{print $2}')
        age=$(($(now_ts) - ts))
        if [ "$age" -gt "$LOCK_TTL" ] 2>/dev/null || ! lock_pid_alive "$pid" 2>/dev/null; then
            lock_remove "$lockfile"
        fi
    done
    # net.count 不自动清理 (计数器, 靠 release 递减)
}

# 读取 loadavg (1min)
read_loadavg() {
    awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0
}

# 检测命令的资源类别
# 输入: 命令字符串
# 输出: cpu|io|net|mem|light (或空)
detect_class() {
    local cmd="$1"
    local conf="${RESOURCE_PATTERNS_CONF}"

    # 优先从配置文件读取
    if [ -f "$conf" ]; then
        while IFS= read -r line; do
            case "$line" in
                ""|\#*) continue ;;
                cpu:*)
                    echo "$line" | grep -qE "^cpu:" && echo "$cmd" | grep -qE "$(echo "$line" | sed 's/^cpu://')" 2>/dev/null && { echo "cpu"; return 0; } ;;
                io:*)
                    echo "$line" | grep -qE "^io:" && echo "$cmd" | grep -qE "$(echo "$line" | sed 's/^io://')" 2>/dev/null && { echo "io"; return 0; } ;;
                net:*)
                    echo "$line" | grep -qE "^net:" && echo "$cmd" | grep -qE "$(echo "$line" | sed 's/^net://')" 2>/dev/null && { echo "net"; return 0; } ;;
                mem:*)
                    echo "$line" | grep -qE "^mem:" && echo "$cmd" | grep -qE "$(echo "$line" | sed 's/^mem://')" 2>/dev/null && { echo "mem"; return 0; } ;;
            esac
        done < "$conf"
    fi

    # 回退: 内建默认模式
    if echo "$cmd" | grep -qE '(npm|yarn|pnpm) (install|build|rebuild|add|update)|pip(3)? install|cmake |make\b|(gcc|g\+\+|clang)\b|npx (tsc|build|webpack|vite build)|cargo (build|install)'; then
        echo "cpu"; return 0
    fi
    if echo "$cmd" | grep -qE 'grep\s+-r\s+/|find\s+/|rsync|dd\b|tar\s+-[cx]'; then
        echo "io"; return 0
    fi
    if echo "$cmd" | grep -qE 'curl\s+.*-[oO]\s|wget\b|git\s+(clone|pull)|pip3? download'; then
        echo "net"; return 0
    fi
    if echo "$cmd" | grep -qE 'python3? .*(train|model)|ffmpeg\b|convert\b'; then
        echo "mem"; return 0
    fi

    echo "light"
}

# ── 子命令实现 ──────────────────────────────────────────────────────

# cleanup: 清理孤儿 claude 进程
do_cleanup() {
    local my_pid cleaned
    my_pid=$$
    cleaned=0

    local main_pid
    main_pid=$(get_main_pid)

    for pid in $(pgrep -x claude 2>/dev/null); do
        # 跳过自身
        [ "$pid" = "$my_pid" ] && continue
        # 跳过主 claude session (走进程树检测, 绕过中间shell)
        [ -n "$main_pid" ] && [ "$pid" = "$main_pid" ] && continue

        local ppid age
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')

        # 孤儿检测: PPID=1 (init 收养) 或 父进程不存在
        if [ "$ppid" = "1" ] 2>/dev/null || ! kill -0 "$ppid" 2>/dev/null; then
            if [ -n "$age" ] && [ "$age" -gt "$ORPHAN_AGE" ] 2>/dev/null; then
                kill "$pid" 2>/dev/null && cleaned=$((cleaned + 1))
            fi
        fi
    done

    # 60s 后仍未死 → SIGKILL (后台异步)
    if [ "$cleaned" -gt 0 ]; then
        (
            sleep 60
            for pid in $(pgrep -x claude 2>/dev/null); do
                [ "$pid" = "$my_pid" ] && continue
                local ppid
                ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
                if [ "$ppid" = "1" ] 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null || true
                fi
            done
        ) &
    fi

    # D 状态告警 (不可杀, 指示 I/O 瓶颈)
    local d_procs
    d_procs=$(count_d_state_claude)
    [ "$d_procs" -gt 0 ] 2>/dev/null && echo "cleanup: WARNING — ${d_procs} claude process(es) in D state (I/O blocked)"

    echo "cleanup: $cleaned orphans terminated"
}

# count: 检查进程数上限 (独立使用默认 MAX_TOTAL_PROCS, check() 内动态调整)
do_count() {
    local total
    total=$(count_claude_procs)

    if [ "$total" -ge "$MAX_TOTAL_PROCS" ] 2>/dev/null; then
        echo "count: DENY ($total running, max $MAX_TOTAL_PROCS)"
        return 2
    fi
    echo "count: OK ($total running)"
    return 0
}

# memcheck: 内存门槛检查
do_memcheck() {
    local mem swap
    mem=$(read_mem_available_mb)
    swap=$(read_swap_pct)

    # swap 临界压力优先 (系统即将 thrash)
    if [ "$swap" -gt "$SWAP_RED" ] 2>/dev/null; then
        echo "memcheck: DENY (swap ${swap}% > ${SWAP_RED}%, mem ${mem}MB)"
        return 2
    fi
    if [ "$mem" -lt "$MIN_MEM_RED" ] 2>/dev/null; then
        echo "memcheck: DENY (${mem}MB available < ${MIN_MEM_RED}MB, swap ${swap}%)"
        return 2
    fi
    if [ "$swap" -gt "$SWAP_YELLOW" ] 2>/dev/null; then
        echo "memcheck: WARN (swap ${swap}% > ${SWAP_YELLOW}%, mem ${mem}MB)"
        return 1
    fi
    if [ "$mem" -lt "$MIN_MEM_GREEN" ] 2>/dev/null; then
        echo "memcheck: WARN (${mem}MB available < ${MIN_MEM_GREEN}MB, swap ${swap}%)"
        return 1
    fi
    echo "memcheck: OK (${mem}MB available, swap ${swap}%)"
    return 0
}

# read-state: 读取交互状态 (含过期检测, epoch 秒比较)
do_read_state() {
    local state epoch now age
    now=$(now_ts)

    if [ ! -f "$STATE_FILE" ]; then
        echo "read-state: missing → interactive (safe default)"
        return 1
    fi

    state=$(grep -oP '"state":"\K[^"]+' "$STATE_FILE" 2>/dev/null || echo "interactive")
    epoch=$(grep -oP '"epoch":\K[0-9]+' "$STATE_FILE" 2>/dev/null || echo 0)

    if [ -z "$epoch" ] || [ "$epoch" -eq 0 ] 2>/dev/null; then
        echo "read-state: corrupt → interactive (safe default)"
        return 1
    fi

    age=$((now - epoch))

    if [ "$age" -gt "$STATE_TTL" ] 2>/dev/null; then
        echo "read-state: stale (${age}s > ${STATE_TTL}s) → interactive"
        return 1
    fi

    echo "read-state: $state (${age}s ago)"
    if [ "$state" = "idle" ]; then
        return 0
    else
        return 1
    fi
}

# 写入状态文件 (epoch 秒, 无时区歧义)
write_state() {
    local state="$1" hook="${2:-manual}"
    local epoch
    epoch=$(date +%s 2>/dev/null || echo 0)
    echo "{\"state\":\"$state\",\"epoch\":$epoch,\"hook\":\"$hook\"}" > "$STATE_FILE" 2>/dev/null || true
}

# mark-interactive: PreToolUse hook 调用
do_mark_interactive() {
    # 节流: 已 interactive 且 <3s 内写过 → 跳过
    if [ -f "$STATE_FILE" ]; then
        local cur_state cur_epoch now age
        now=$(now_ts)
        cur_state=$(grep -oP '"state":"\K[^"]+' "$STATE_FILE" 2>/dev/null || echo "")
        cur_epoch=$(grep -oP '"epoch":\K[0-9]+' "$STATE_FILE" 2>/dev/null || echo 0)
        if [ "$cur_state" = "interactive" ] && [ "$cur_epoch" -gt 0 ] 2>/dev/null; then
            age=$((now - cur_epoch))
            if [ "$age" -lt "$MARK_THROTTLE_SEC" ] 2>/dev/null; then
                echo "mark-interactive: throttled (${age}s ago, already interactive)"
                return 0
            fi
        fi
    fi
    save_main_pid  # 总是刷新 (防止死PID残留)
    write_state "interactive" "PreToolUse"
    do_prioritize
    echo "mark-interactive: state=interactive"
}

# mark-idle: Stop / SessionStart hook 调用
do_mark_idle() {
    # SessionStart 时保存主 PID (最可靠时机)
    save_main_pid  # 总是刷新 (防止死PID残留)
    write_state "idle" "Stop"
    do_prioritize
    echo "mark-idle: state=idle"
}

# prioritize: 根据状态 + 持续时间渐变 renice/ionice 子代理
# 消抖: idle↔interactive 不再 0↔19 瞬切, 而是按时长渐变
do_prioritize() {
    local state target_nice target_ionice my_pid state_age
    my_pid=$$

    # 读取当前状态和年龄
    if [ -f "$STATE_FILE" ]; then
        local cur_state cur_epoch now
        now=$(now_ts)
        cur_state=$(grep -oP '"state":"\K[^"]+' "$STATE_FILE" 2>/dev/null || echo "")
        cur_epoch=$(grep -oP '"epoch":\K[0-9]+' "$STATE_FILE" 2>/dev/null || echo 0)
        state_age=$((now - cur_epoch))
    else
        cur_state="interactive"
        state_age=999
    fi

    # 按状态 + 持续时间决定 nice 值
    if [ "$cur_state" = "idle" ]; then
        # idle: 渐进恢复 — 先在 +5 停留 30s, 再完全恢复 0
        if [ "$state_age" -gt "$IDLE_RESTORE_DELAY" ] 2>/dev/null; then
            target_nice=0
            target_ionice="2 -n 0"
        else
            target_nice="$INTERACTIVE_NICE_SOFT"
            target_ionice="2 -n 0"
        fi
        state="idle"
    else
        # interactive: 渐进加压 — 先 +5 (温和), 持续>15s 后 +19 (激进)
        if [ "$state_age" -gt "$INTERACTIVE_HARSH_DELAY" ] 2>/dev/null; then
            target_nice="$INTERACTIVE_NICE_HARSH"
            target_ionice="3"
        else
            target_nice="$INTERACTIVE_NICE_SOFT"
            target_ionice="2 -n 0"
        fi
        state="interactive"
    fi

    local main_pid
    main_pid=$(get_main_pid)

    for pid in $(pgrep -x claude 2>/dev/null); do
        [ "$pid" = "$my_pid" ] && continue
        [ -n "$main_pid" ] && [ "$pid" = "$main_pid" ] && continue

        renice -n "$target_nice" -p "$pid" 2>/dev/null || true
        ionice -c $target_ionice -p "$pid" 2>/dev/null || true
    done
}

# status: 单行状态摘要
do_status() {
    local mem swap procs state_info
    mem=$(read_mem_available_mb)
    swap=$(read_swap_pct)
    procs=$(count_claude_procs)

    if do_read_state >/dev/null 2>&1; then
        state_info="idle"
    else
        state_info="interactive"
    fi

    # D 状态进程检测
    local d_procs d_clause
    d_procs=$(count_d_state_claude)
    [ "$d_procs" -gt 0 ] 2>/dev/null && d_clause=" D-procs=${d_procs}" || d_clause=""

    # 判断内存状态等级 (含 swap)
    local mem_level
    if [ "$mem" -lt "$MIN_MEM_RED" ] 2>/dev/null || [ "$swap" -gt "$SWAP_RED" ] 2>/dev/null; then
        mem_level="RED"
    elif [ "$mem" -lt "$MIN_MEM_GREEN" ] 2>/dev/null || [ "$swap" -gt "$SWAP_YELLOW" ] 2>/dev/null; then
        mem_level="YELLOW"
    else
        mem_level="GREEN"
    fi

    # 资源锁摘要 — 仅在有 subagent 时读取
    if [ "$procs" -gt 1 ] 2>/dev/null; then
        local locks_summary cpu_locked io_locked net_count_val
        [ -f "$RESOURCE_LOCK_DIR/cpu.lock" ] && cpu_locked="CPU:locked" || cpu_locked="CPU:free"
        [ -f "$RESOURCE_LOCK_DIR/io.lock" ] && io_locked="IO:locked" || io_locked="IO:free"
        net_count_val=$(cat "$RESOURCE_LOCK_DIR/net.count" 2>/dev/null || echo 0)
        locks_summary="Locks=[${cpu_locked} ${io_locked} NET:${net_count_val}/${NET_MAX}]"
    else
        local locks_summary="Locks=[skipped:single]"
    fi

    echo "MemAvail=${mem}MB SwapUsed=${swap}% ClaudeProcs=${procs} MemLevel=${mem_level} State=${state_info}${d_clause} $locks_summary"
}

# check: 组合门控 (Agent tool PreToolUse hook 调用)
do_check() {
    local result max_procs is_interactive

    # 1. 清理孤儿
    do_cleanup >/dev/null 2>&1 || true

    # 2. 冷却检查 (缓解竞态)
    if ! check_cooldown; then
        echo '{"status":"DENY","reason":"cooldown (spawn too fast)","action":"wait_5s"}'
        return 2
    fi

    # 3. 交互状态 → 降低并发上限 (不拒绝, 用户主动请求的 spawn 应允许)
    is_interactive=0
    if ! do_read_state >/dev/null 2>&1; then
        is_interactive=1
        max_procs=$MAX_INTERACTIVE_PROCS
    else
        max_procs=$MAX_TOTAL_PROCS
    fi

    # 4. 进程数检查
    local total
    total=$(count_claude_procs)
    if [ "$total" -ge "$max_procs" ] 2>/dev/null; then
        echo "{\"status\":\"DENY\",\"reason\":\"process limit ($total >= $max_procs)\",\"action\":\"wait_or_reduce\",\"interactive\":$is_interactive}"
        return 2
    fi

    # 5. 内存检查
    result=$(do_memcheck)
    local mem_rc=$?
    if [ "$mem_rc" -eq 2 ]; then
        echo "{\"status\":\"DENY\",\"reason\":\"memory critical\",\"detail\":\"$result\",\"action\":\"clean_orphans_first\"}"
        return 2
    elif [ "$mem_rc" -eq 1 ]; then
        echo "{\"status\":\"WARN\",\"reason\":\"memory moderate\",\"detail\":\"$result\",\"action\":\"reduce_concurrency\",\"interactive\":$is_interactive}"
        set_cooldown
        return 1
    fi

    # 6. 资源锁冲突检查 (Phase 2d) — 仅在有 subagent 时执行
    if [ "$total" -gt 1 ] 2>/dev/null; then
        local lock_json
        lock_json=$(do_lock_status --json 2>/dev/null)
        # 检查 cpu/io/mem 锁是否被其他 PID 持有
        if echo "$lock_json" | grep -qE '"(cpu|io|mem)":\{'; then
            local held_class
            held_class=$(echo "$lock_json" | grep -oE '"(cpu|io|mem)":\{[^}]*"pid":[0-9]+' | head -1 | grep -oE '"(cpu|io|mem)"' | tr -d '"')
            if [ -n "$held_class" ]; then
                echo "{\"status\":\"DENY\",\"reason\":\"resource $held_class busy\",\"action\":\"wait_10s_retry\",\"locks\":$lock_json,\"interactive\":$is_interactive}"
                return 2
            fi
        fi
        # 检查 net 是否饱和
        local net_count
        net_count=$(echo "$lock_json" | grep -oE '"net":\{[^}]*"count":([0-9]+)' | grep -oE '"count":[0-9]+' | grep -oE '[0-9]+')
        if [ -n "$net_count" ] && [ "$net_count" -ge "$NET_MAX" ] 2>/dev/null; then
            echo "{\"status\":\"WARN\",\"reason\":\"network saturated ($net_count/$NET_MAX)\",\"action\":\"reduce_net_concurrency\",\"locks\":$lock_json,\"interactive\":$is_interactive}"
            set_cooldown
            return 1
        fi
        # 合并锁状态到输出
        local lock_part=",\"locks\":$lock_json"
    else
        local lock_part=""
    fi

    # 7. 通过
    set_cooldown
    echo "{\"status\":\"OK\",\"reason\":\"resources sufficient\",\"detail\":\"$result\"$lock_part,\"interactive\":$is_interactive}"
    return 0
}

# ── Phase 2d 子命令 ─────────────────────────────────────────────────

do_acquire() {
    local class wait_sec lockfile pid_file
    class=""
    wait_sec=0

    # 解析参数: acquire <class> [--wait N] | acquire <class> [N]
    while [ $# -gt 0 ]; do
        case "$1" in
            --wait) wait_sec="${2:-$SPIN_DEFAULT_TIMEOUT}"; shift 2 ;;
            --try-only) wait_sec=0; shift ;;
            [0-9]*) wait_sec="$1"; shift ;;
            *) class="$1"; shift ;;
        esac
    done

    [ -z "$class" ] && { echo "acquire: missing class"; return 2; }

    # 快速路径: 无 subagent 时跳过锁 (非 fan-out 模式零开销)
    local total_procs
    total_procs=$(count_claude_procs)
    if [ "$total_procs" -le 1 ] 2>/dev/null; then
        echo "acquire: $class skipped (single process, no contention)"
        return 0
    fi

    lock_dir_init
    lock_cleanup_stale

    case "$class" in
        cpu|io) lockfile="$RESOURCE_LOCK_DIR/${class}.lock" ;;
        net)    pid_file="$RESOURCE_LOCK_DIR/net.count" ;;
        mem)    lockfile="$RESOURCE_LOCK_DIR/mem.flag" ;;
        auto)
            # 自动检测: 优先 $CC_TOOL_INPUT, 其次 loadavg
            if [ -n "${CC_TOOL_INPUT:-}" ]; then
                class=$(detect_class "$CC_TOOL_INPUT")
            fi
            if [ "$class" = "auto" ] || [ "$class" = "light" ]; then
                local loadavg
                loadavg=$(read_loadavg)
                if [ "$(echo "$loadavg > $CPU_LOAD_THRESHOLD" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
                    class="cpu"
                else
                    echo "acquire: auto → light (loadavg=${loadavg}, no lock needed)"
                    return 0
                fi
            fi
            ;;
        *)  echo "acquire: unknown class '$class'"; return 2 ;;
    esac

    # 重入检测: 同一 PID 已持有同类锁 → 直接返回
    if [ "$class" != "net" ]; then
        lock_is_held_by_me "$class" && { echo "acquire: $class already held by $$ (re-entrant)"; return 0; }
    fi

    # 自旋等待
    local deadline elapsed
    deadline=$(($(now_ts) + wait_sec))

    while true; do
        # net: 计数器递增
        if [ "$class" = "net" ]; then
            local count
            count=$(cat "$pid_file" 2>/dev/null || echo 0)
            if [ "$count" -lt "$NET_MAX" ] 2>/dev/null; then
                echo $((count + 1)) > "$pid_file" 2>/dev/null
                echo "acquire: net count=$((count + 1))/$NET_MAX"
                return 0
            fi
        else
            # cpu/io/mem: 互斥锁
            if ! lock_is_held "$class"; then
                lock_write "$lockfile" "$$"
                echo "acquire: $class locked by $$"
                return 0
            fi
        fi

        # 超时检查
        elapsed=$(($(now_ts) - (deadline - wait_sec)))
        [ "$elapsed" -ge "$wait_sec" ] 2>/dev/null && break

        sleep "$SPIN_INTERVAL" 2>/dev/null || sleep 1
    done

    # 超时: 返回忙, 不阻塞调用者
    echo "acquire: $class BUSY (waited ${wait_sec}s), proceeding anyway"
    return 1
}

do_release() {
    local target="$1"

    lock_dir_init

    if [ "$target" = "all" ]; then
        local released=0
        # 释放 cpu/io/mem 锁
        for lockfile in "$RESOURCE_LOCK_DIR"/*.lock "$RESOURCE_LOCK_DIR"/*.flag; do
            [ -f "$lockfile" ] || continue
            local content pid
            content=$(lock_read "$lockfile")
            pid=$(echo "$content" | awk '{print $1}')
            if [ "$pid" = "$$" ]; then
                lock_remove "$lockfile"
                released=$((released + 1))
            fi
        done
        # 释放 net 计数 (如果当前 PID 有计数)
        local net_pids="$RESOURCE_LOCK_DIR/net.pids"
        if [ -f "$net_pids" ]; then
            grep -v "^$$$" "$net_pids" > "${net_pids}.tmp" 2>/dev/null && mv "${net_pids}.tmp" "$net_pids"
            local new_count
            new_count=$(wc -l < "$net_pids" 2>/dev/null || echo 0)
            echo "$new_count" > "$RESOURCE_LOCK_DIR/net.count" 2>/dev/null
        fi
        echo "release: all locks released ($released)"
        return 0
    fi

    if [ "$target" = "acquired" ]; then
        # PostToolUse hook: 释放当前 PID 的最可能锁
        do_release "all"
        return $?
    fi

    # 释放指定类别
    case "$target" in
        cpu|io|mem)
            local lockfile="$RESOURCE_LOCK_DIR/${target}.lock"
            [ "$target" = "mem" ] && lockfile="$RESOURCE_LOCK_DIR/mem.flag"
            lock_is_held_by_me "$target" && lock_remove "$lockfile" && echo "release: $target unlocked"
            ;;
        net)
            local countfile="$RESOURCE_LOCK_DIR/net.count"
            local count
            count=$(cat "$countfile" 2>/dev/null || echo 1)
            echo $((count > 0 ? count - 1 : 0)) > "$countfile" 2>/dev/null
            echo "release: net count=$((count > 0 ? count - 1 : 0))/$NET_MAX"
            ;;
        *)  echo "release: unknown class '$target'"; return 2 ;;
    esac
    return 0
}

do_lock_status() {
    local use_json="${1:-}"
    lock_dir_init
    lock_cleanup_stale

    if [ "$use_json" = "--json" ]; then
        echo -n '{"locks":{'
        local first=1
        for lockfile in "$RESOURCE_LOCK_DIR"/*.lock "$RESOURCE_LOCK_DIR"/*.flag; do
            [ -f "$lockfile" ] || continue
            local content pid ts age class
            content=$(lock_read "$lockfile")
            pid=$(echo "$content" | awk '{print $1}')
            ts=$(echo "$content" | awk '{print $2}')
            age=$(($(now_ts) - ts))
            class=$(lock_class_from_file "$lockfile")
            [ "$first" = "0" ] && echo -n ','
            echo -n "\"$class\":{\"pid\":$pid,\"age\":$age}"
            first=0
        done
        local net_count
        net_count=$(cat "$RESOURCE_LOCK_DIR/net.count" 2>/dev/null || echo 0)
        [ "$first" = "0" ] && echo -n ','
        echo -n "\"net\":{\"count\":$net_count,\"max\":$NET_MAX}"
        echo '}}'
    else
        echo "Resource locks:"
        for lockfile in "$RESOURCE_LOCK_DIR"/*.lock "$RESOURCE_LOCK_DIR"/*.flag; do
            [ -f "$lockfile" ] || continue
            local content pid ts age class
            content=$(lock_read "$lockfile")
            pid=$(echo "$content" | awk '{print $1}')
            ts=$(echo "$content" | awk '{print $2}')
            age=$(($(now_ts) - ts))
            class=$(lock_class_from_file "$lockfile")
            echo "  $class: PID=$pid age=${age}s"
        done
        local net_count
        net_count=$(cat "$RESOURCE_LOCK_DIR/net.count" 2>/dev/null || echo 0)
        echo "  net: count=$net_count/$NET_MAX"
    fi
}

do_detect() {
    local cmd="${1:-}"
    [ -z "$cmd" ] && { echo "light"; return 0; }
    detect_class "$cmd"
}

# ── 主入口 ──────────────────────────────────────────────────────────

case "${1:-}" in
    cleanup)          do_cleanup ;;
    count)            do_count ;;
    memcheck)         do_memcheck ;;
    read-state)       do_read_state ;;
    status)           do_status ;;
    check)            do_check ;;
    mark-interactive) do_mark_interactive ;;
    mark-idle)        do_mark_idle ;;
    prioritize)       do_prioritize ;;
    acquire)          do_acquire "${@:2}" ;;
    release)          do_release "${2:-all}" ;;
    lock-status)      do_lock_status "${2:-}" ;;
    detect)           do_detect "${2:-}" ;;
    *)
        echo "Usage: $0 {cleanup|count|memcheck|read-state|status|check|mark-interactive|mark-idle|prioritize|acquire|release|lock-status|detect} [args]"
        echo ""
        echo "Agent Resource Gate — subagent spawn + resource scheduling"
        echo ""
        echo "Gate commands (Phase 2):"
        echo "  cleanup           Kill orphan claude processes (PPID=1, age>${ORPHAN_AGE}s)"
        echo "  count             Check total claude processes (max ${MAX_TOTAL_PROCS})"
        echo "  memcheck          Check MemAvailable (RED<${MIN_MEM_RED}MB, YELLOW<${MIN_MEM_GREEN}MB)"
        echo "  status            Single-line resource + lock summary"
        echo "  check             Combined gate: cleanup→state→count→mem→locks (Agent PreToolUse)"
        echo ""
        echo "Interactive state (Phase 2b):"
        echo "  mark-interactive  Set interactive state + deprioritize subagents (PreToolUse hook)"
        echo "  mark-idle         Set idle state + restore priority (Stop hook)"
        echo "  read-state        Print current state with staleness check"
        echo "  prioritize        Apply nice/ionice to subagents based on state"
        echo ""
        echo "Resource locks (Phase 2d):"
        echo "  acquire <class> [--wait N]  Acquire resource lock (cpu|io|net|mem|auto)"
        echo "  release <class|all>         Release resource lock"
        echo "  lock-status [--json]        Show lock status"
        echo "  detect <command>            Detect resource class of a command"
        exit 0
        ;;
esac
