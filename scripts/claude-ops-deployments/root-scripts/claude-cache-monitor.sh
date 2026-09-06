#!/bin/bash
# ============================================================================
# Claude Code 缓存命中率监控 + 异常自动诊断
# ============================================================================
# 用法:
#   bash /root/claude-cache-monitor.sh run       前台运行 (每60s检查一次)
#   bash /root/claude-cache-monitor.sh once      单次检查+报告
#   bash /root/claude-cache-monitor.sh status    查看最近一次报告
#   bash /root/claude-cache-monitor.sh daemon    后台运行 (nohup)
#
# 监控指标:
#   - 缓存命中率 < 阈值 → 触发 dump
#   - prefix_changes > 0 → 触发 dump
#   - proxy 502 错误新增 → 记录告警
#   - token 消耗速率异常 → 触发 dump
#
# 输出: ~/.permafrost/monitor/ 目录下按时间戳归档
# ============================================================================
set -e

PERMAFROST_URL="${PERMAFROST_URL:-http://127.0.0.1:8788}"
MONITOR_DIR="${MONITOR_DIR:-$HOME/.permafrost/monitor}"
STATE_FILE="$MONITOR_DIR/state.json"
LOG_FILE="$MONITOR_DIR/monitor.log"
PROXY_LOG="${PROXY_LOG:-$HOME/.claude/proxy.log}"

# 阈值配置
HIT_RATE_WARN=0.85      # 命中率低于此值 → 告警
HIT_RATE_DUMP=0.70      # 命中率低于此值 → 触发 dump
PREFIX_CHANGE_DUMP=1    # 前缀变化 >= 此值 → 触发 dump
TOKEN_SPIKE_RATIO=2.0   # token 消耗速率超过基线 N 倍 → 告警

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

mkdir -p "$MONITOR_DIR"

# ── 工具函数 ──────────────────────────────────────────────────────

get_stats() {
    curl -s "$PERMAFROST_URL/permafrost/stats" 2>/dev/null || echo '{"error":"unreachable"}'
}

get_doctor() {
    curl -s "$PERMAFROST_URL/permafrost/doctor" 2>/dev/null || echo '{"error":"unreachable"}'
}

proxy_502_count() {
    grep -c "502" "$PROXY_LOG" 2>/dev/null || echo 0
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ── 状态读写 ──────────────────────────────────────────────────────

load_state() {
    if [ -f "$STATE_FILE" ]; then
        python3 -c "
import json
with open('$STATE_FILE') as f:
    d=json.load(f)
print(json.dumps({
    'last_hit_rate': d.get('last_hit_rate', 1.0),
    'last_requests': d.get('last_requests', 0),
    'last_hit_tokens': d.get('last_hit_tokens', 0),
    'last_miss_tokens': d.get('last_miss_tokens', 0),
    'last_prefix_changes': d.get('last_prefix_changes', 0),
    'last_502_count': d.get('last_502_count', 0),
    'last_check': d.get('last_check', ''),
    'baseline_hit_rate': d.get('baseline_hit_rate', 1.0),
    'dump_count': d.get('dump_count', 0),
}))
" 2>/dev/null || echo '{"last_hit_rate":1.0,"last_requests":0,"last_hit_tokens":0,"last_miss_tokens":0,"last_prefix_changes":0,"last_502_count":0,"last_check":"","baseline_hit_rate":1.0,"dump_count":0}'
    else
        echo '{"last_hit_rate":1.0,"last_requests":0,"last_hit_tokens":0,"last_miss_tokens":0,"last_prefix_changes":0,"last_502_count":0,"last_check":"","baseline_hit_rate":1.0,"dump_count":0}'
    fi
}

save_state() {
    python3 -c "
import json
with open('$STATE_FILE', 'w') as f:
    json.dump({
        'last_hit_rate': $1,
        'last_requests': $2,
        'last_hit_tokens': $3,
        'last_miss_tokens': $4,
        'last_prefix_changes': $5,
        'last_502_count': $6,
        'last_check': '$(ts)',
        'baseline_hit_rate': ${7:-$1},
        'dump_count': $8,
    }, f, indent=2)
"
}

# ── 异常诊断 dump ─────────────────────────────────────────────────

trigger_dump() {
    local reason="$1"
    local dump_id="dump-$(date '+%Y%m%d-%H%M%S')"
    local dump_dir="$MONITOR_DIR/$dump_id"
    mkdir -p "$dump_dir"

    echo -e "${RED}[$(ts)] 触发诊断 dump: $reason${NC}"
    echo "[$(ts)] TRIGGER: $reason" >> "$LOG_FILE"

    # 1. permafrost 全量快照
    get_stats > "$dump_dir/permafrost-stats.json" 2>/dev/null
    get_doctor > "$dump_dir/permafrost-doctor.json" 2>/dev/null

    # 2. 最近的请求 dump
    local latest_dumps=$(ls -t /root/.permafrost/dumps/req-*.json 2>/dev/null | head -5)
    if [ -n "$latest_dumps" ]; then
        mkdir -p "$dump_dir/requests"
        for f in $latest_dumps; do
            cp "$f" "$dump_dir/requests/$(basename $f)" 2>/dev/null
        done
    fi

    # 3. proxy 错误日志
    tail -30 "$PROXY_LOG" > "$dump_dir/proxy-recent.log" 2>/dev/null

    # 4. 触发原因报告
    cat > "$dump_dir/trigger.txt" << EOF
触发时间: $(ts)
触发原因: $reason

当前状态:
$(get_stats | python3 -m json.tool 2>/dev/null || echo 'unavailable')
EOF

    echo -e "${GREEN}[$(ts)] dump 已保存: $dump_dir${NC}"
    echo "$dump_dir"
}

# ── 单次检查 ──────────────────────────────────────────────────────

do_check() {
    local state=$(load_state)
    local prev_rate=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['last_hit_rate'])")
    local prev_req=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['last_requests'])")
    local prev_hit=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['last_hit_tokens'])")
    local prev_miss=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['last_miss_tokens'])")
    local prev_pc=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['last_prefix_changes'])")
    local prev_502=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['last_502_count'])")
    local baseline=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['baseline_hit_rate'])")
    local dump_n=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['dump_count'])")

    local stats=$(get_stats)
    local cur_rate=$(echo "$stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hit_rate',0))" 2>/dev/null || echo 0)
    local cur_req=$(echo "$stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('requests',0))" 2>/dev/null || echo 0)
    local cur_hit=$(echo "$stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cache_hit_tokens',0))" 2>/dev/null || echo 0)
    local cur_miss=$(echo "$stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cache_miss_tokens',0))" 2>/dev/null || echo 0)
    local cur_pc=$(echo "$stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prefix_changes',0))" 2>/dev/null || echo 0)
    local cur_502=$(proxy_502_count)

    local triggered=""
    local reason=""

    # 检查1: 命中率骤降
    if [ "$(echo "$cur_rate < $HIT_RATE_DUMP" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        triggered=1
        reason="hit_rate=${cur_rate} < threshold=${HIT_RATE_DUMP}"
    fi

    # 检查2: 前缀变化 (compaction/resume 等)
    if [ "$cur_pc" -gt "$prev_pc" ] 2>/dev/null; then
        local pc_delta=$((cur_pc - prev_pc))
        if [ "$pc_delta" -ge "$PREFIX_CHANGE_DUMP" ]; then
            triggered=1
            [ -n "$reason" ] && reason="$reason; "
            reason="${reason}prefix_changes +${pc_delta} (${prev_pc}→${cur_pc})"
        fi
    fi

    # 检查3: token 消耗速率异常
    if [ "$cur_req" -gt "$prev_req" ] 2>/dev/null; then
        local new_miss=$((cur_miss - prev_miss))
        local new_hit=$((cur_hit - prev_hit))
        if [ "$new_hit" -gt 0 ] && [ "$new_miss" -gt 0 ]; then
            local miss_ratio=$(echo "scale=2; $new_miss / ($new_miss + $new_hit)" | bc 2>/dev/null || echo 0)
            if [ "$(echo "$miss_ratio > 0.5" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
                triggered=1
                [ -n "$reason" ] && reason="$reason; "
                reason="${reason}miss_ratio=${miss_ratio} (${new_miss}miss/${new_hit}hit)"
            fi
        fi
    fi

    # 检查4: proxy 502 新增
    local new_502=$((cur_502 - prev_502))
    if [ "$new_502" -gt 0 ] 2>/dev/null; then
        [ -n "$reason" ] && reason="$reason; "
        reason="${reason}502_errors +${new_502}"
        # 502 不单独触发 dump, 仅记录
    fi

    # 更新 baseline (用最近的稳定值)
    local new_baseline=$baseline
    if [ "$(echo "$cur_rate > 0.95" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        new_baseline=$cur_rate
    fi

    save_state "$cur_rate" "$cur_req" "$cur_hit" "$cur_miss" "$cur_pc" "$cur_502" "$new_baseline" "$dump_n"

    # 触发 dump
    if [ -n "$triggered" ]; then
        dump_n=$((dump_n + 1))
        save_state "$cur_rate" "$cur_req" "$cur_hit" "$cur_miss" "$cur_pc" "$cur_502" "$new_baseline" "$dump_n"
        local dump_dir=$(trigger_dump "$reason")
        echo "[$(ts)] CHECK: rate=${cur_rate} req=${cur_req} miss_r=${reason} → DUMP: $dump_dir" >> "$LOG_FILE"
    else
        local status_icon="✅"
        [ "$(echo "$cur_rate < $HIT_RATE_WARN" | bc -l 2>/dev/null || echo 0)" = "1" ] && status_icon="⚠️"
        echo "[$(ts)] $status_icon rate=${cur_rate} req=${cur_req} hit=${cur_hit} miss=${cur_miss} pc=${cur_pc}" >> "$LOG_FILE"
    fi

    # 输出
    echo "[$(ts)] rate=${cur_rate} req=${cur_req} pc=${cur_pc} 502=${cur_502} baseline=${new_baseline} ${triggered:+⚠️ DUMP: $reason}"
}

# ── 主入口 ────────────────────────────────────────────────────────

case "${1:-once}" in
    once)
        do_check
        ;;
    run)
        echo "缓存监控运行中 (间隔60s, 输出到 $LOG_FILE)"
        echo "阈值: hit_rate<${HIT_RATE_DUMP} 或 prefix_change≥${PREFIX_CHANGE_DUMP} 或 miss_ratio>0.5 → 触发dump"
        echo "Ctrl+C 停止"
        while true; do
            do_check
            sleep 60
        done
        ;;
    daemon)
        nohup bash "$0" run >> "$MONITOR_DIR/daemon.log" 2>&1 &
        echo "监控守护进程已启动 (PID $!)"
        echo "日志: $MONITOR_DIR/daemon.log"
        echo "停止: kill $!"
        ;;
    status)
        echo "=== 最近检查记录 ==="
        tail -5 "$LOG_FILE" 2>/dev/null || echo "(无记录)"
        echo ""
        echo "=== dump 历史 ==="
        ls -lt "$MONITOR_DIR"/dump-* 2>/dev/null | head -5 || echo "(无dump)"
        echo ""
        echo "=== 当前状态 ==="
        get_stats | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d:
    print('permafrost unreachable')
else:
    print(f'hit_rate: {d[\"hit_rate\"]}')
    print(f'requests: {d[\"requests\"]}')
    print(f'prefix_changes: {d[\"prefix_changes\"]}')
    print(f'saved: {d[\"saved_pct\"]}%')
" 2>/dev/null || echo "无法获取 permafrost 状态"
        ;;
    *)
        echo "Usage: $0 {once|run|daemon|status}"
        ;;
esac
