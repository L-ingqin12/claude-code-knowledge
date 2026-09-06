#!/bin/bash
# ============================================================================
# Hermes 缓存命中率监控 — 基于 Permafrost + Model-Router 双重检测
# ============================================================================
# 用法:
#   bash /home/pi/hermes-cache-monitor.sh once      单次检查
#   bash /home/pi/hermes-cache-monitor.sh run       前台持续运行 (每60s)
#   bash /home/pi/hermes-cache-monitor.sh daemon    后台守护
#   bash /home/pi/hermes-cache-monitor.sh status    查看状态 + 历史
#
# 与 claude-cache-monitor.sh 的区别:
#   - 本脚本面向 Hermes (飞书助手) 的缓存健康度
#   - 同时监控 model-router (:18888) 状态
#   - Hermes 目前不经过 permafrost，但 permafrost stats 反映共享 DeepSeek
#     后端的整体缓存健康度
#   - 阈值更宽松 (Hermes L1/L2 用 doubao 不走 deepseek 缓存)
#
# 监控指标:
#   - permafrost 缓存命中率 (反映 DeepSeek 后端缓存状态)
#   - model-router 健康 + 分层统计
#   - 命中率 < 70% → 触发诊断 dump
# ============================================================================
set -e

PERMAFROST_URL="${PERMAFROST_URL:-http://127.0.0.1:8788}"
ROUTER_URL="${ROUTER_URL:-http://127.0.0.1:18888}"
MONITOR_DIR="${MONITOR_DIR:-$HOME/.hermes-cache/monitor}"
STATE_FILE="$MONITOR_DIR/state.json"
LOG_FILE="$MONITOR_DIR/monitor.log"

# 阈值 — Hermes 比 CC 宽松 (L1/L2 用 doubao, 不走 deepseek 缓存)
HIT_RATE_WARN=0.75      # 低于此值 → 告警
HIT_RATE_DUMP=0.60      # 低于此值 → 触发 dump (比 CC 的 0.70 更宽松)
PREFIX_CHANGE_DUMP=2    # 前缀变化 >= 此值 → 触发 dump

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

mkdir -p "$MONITOR_DIR"

# ── 工具函数 ──────────────────────────────────────────────────────

get_permafrost_stats() {
    curl -s --connect-timeout 5 "$PERMAFROST_URL/permafrost/stats" 2>/dev/null || echo '{"error":"permafrost_unreachable"}'
}

get_router_health() {
    curl -s --connect-timeout 5 "$ROUTER_URL/health" 2>/dev/null || echo '{"error":"router_unreachable"}'
}

get_router_stats() {
    curl -s --connect-timeout 5 "$ROUTER_URL/stats" 2>/dev/null || echo '{"error":"router_unreachable"}'
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
    'last_router_status': d.get('last_router_status', 'unknown'),
    'last_router_errors': d.get('last_router_errors', 0),
    'last_check': d.get('last_check', ''),
    'baseline_hit_rate': d.get('baseline_hit_rate', 1.0),
    'dump_count': d.get('dump_count', 0),
}))
" 2>/dev/null || echo '{"last_hit_rate":1.0,"last_requests":0,"last_hit_tokens":0,"last_miss_tokens":0,"last_prefix_changes":0,"last_router_status":"unknown","last_router_errors":0,"last_check":"","baseline_hit_rate":1.0,"dump_count":0}'
    else
        echo '{"last_hit_rate":1.0,"last_requests":0,"last_hit_tokens":0,"last_miss_tokens":0,"last_prefix_changes":0,"last_router_status":"unknown","last_router_errors":0,"last_check":"","baseline_hit_rate":1.0,"dump_count":0}'
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
        'last_router_status': '${6:-unknown}',
        'last_router_errors': ${7:-0},
        'last_check': '$(ts)',
        'baseline_hit_rate': ${8:-$1},
        'dump_count': $9,
    }, f, indent=2)
"
}

# ── 异常诊断 dump ─────────────────────────────────────────────────

trigger_dump() {
    local reason="$1"
    local dump_id="dump-$(date '+%Y%m%d-%H%M%S')"
    local dump_dir="$MONITOR_DIR/$dump_id"
    mkdir -p "$dump_dir"

    echo -e "${RED}[$(ts)] 触发 Hermes 缓存诊断 dump: $reason${NC}"
    echo "[$(ts)] TRIGGER: $reason" >> "$LOG_FILE"

    # 1. Permafrost 快照
    get_permafrost_stats > "$dump_dir/permafrost-stats.json" 2>/dev/null

    # 2. Model-Router 快照
    get_router_health > "$dump_dir/router-health.json" 2>/dev/null
    get_router_stats > "$dump_dir/router-stats.json" 2>/dev/null

    # 3. Hermes 进程信息
    {
        echo "=== Hermes 进程 ==="
        pgrep -f "hermes-gateway\|model.router\|permafrost" 2>/dev/null || echo "(无相关进程)"
        echo ""
        echo "=== 系统负载 ==="
        uptime
        echo ""
        echo "=== 内存 ==="
        free -h
    } > "$dump_dir/system-info.txt"

    # 4. 触发原因报告
    cat > "$dump_dir/trigger.txt" << EOF
触发时间: $(ts)
触发原因: $reason

Hermes 缓存链路:
  Hermes Agent → model-router (:18888) → ARK API (直连, 不经 permafrost)
  Permafrost (:8788) 仅服务于 Claude Code

注意事项:
  - Hermes L1/L2 使用 doubao 模型, 不走 DeepSeek 缓存
  - Permafrost 命中率下降仅影响 Claude Code
  - Model-Router 异常需要独立排查
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
    local prev_router_err=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['last_router_errors'])")
    local baseline=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['baseline_hit_rate'])")
    local dump_n=$(echo "$state" | python3 -c "import sys,json; print(json.load(sys.stdin)['dump_count'])")

    # 获取 permafrost 状态
    local pf_stats=$(get_permafrost_stats)
    local cur_rate=$(echo "$pf_stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hit_rate',0))" 2>/dev/null || echo 0)
    local cur_req=$(echo "$pf_stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('requests',0))" 2>/dev/null || echo 0)
    local cur_hit=$(echo "$pf_stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cache_hit_tokens',0))" 2>/dev/null || echo 0)
    local cur_miss=$(echo "$pf_stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cache_miss_tokens',0))" 2>/dev/null || echo 0)
    local cur_pc=$(echo "$pf_stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prefix_changes',0))" 2>/dev/null || echo 0)

    # 获取 router 状态
    local router_health=$(get_router_health)
    local router_status=$(echo "$router_health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
    local router_stats=$(get_router_stats)
    local router_err=$(echo "$router_stats" | python3 -c "import sys,json; print(json.load(sys.stdin).get('errors',0))" 2>/dev/null || echo 0)
    local router_tiers=$(echo "$router_stats" | python3 -c "
import sys,json
d=json.load(sys.stdin)
tiers=d.get('tiers',{})
total=sum(tiers.values())
print(f'total={total} ' + ' '.join(f'{k}={v}' for k,v in sorted(tiers.items())))
" 2>/dev/null || echo "unavailable")

    local triggered=""
    local reason=""

    # 检查1: Permafrost 缓存命中率骤降
    if [ "$(echo "$cur_rate < $HIT_RATE_DUMP" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        if [ "$cur_req" -gt 0 ] 2>/dev/null; then  # 有实际请求才告警
            triggered=1
            reason="permafrost_hit_rate=$(python3 -c "print(round($cur_rate*100,1))")% < threshold=$(python3 -c "print(round($HIT_RATE_DUMP*100))")%"
        fi
    fi

    # 检查2: Model-Router 不健康
    if [ "$router_status" != "ok" ]; then
        triggered=1
        [ -n "$reason" ] && reason="$reason; "
        reason="${reason}router_status=$router_status"
    fi

    # 检查3: Router 错误增加
    local new_router_err=$((router_err - prev_router_err))
    if [ "$new_router_err" -gt 5 ] 2>/dev/null; then
        triggered=1
        [ -n "$reason" ] && reason="$reason; "
        reason="${reason}router_errors +${new_router_err}"
    fi

    # 检查4: 前缀变化 (compaction 等)
    if [ "$cur_pc" -gt "$prev_pc" ] 2>/dev/null; then
        local pc_delta=$((cur_pc - prev_pc))
        if [ "$pc_delta" -ge "$PREFIX_CHANGE_DUMP" ]; then
            triggered=1
            [ -n "$reason" ] && reason="$reason; "
            reason="${reason}prefix_changes +${pc_delta}"
        fi
    fi

    # 更新 baseline
    local new_baseline=$baseline
    if [ "$(echo "$cur_rate > 0.95" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        new_baseline=$cur_rate
    fi

    save_state "$cur_rate" "$cur_req" "$cur_hit" "$cur_miss" "$cur_pc" "$router_status" "$router_err" "$new_baseline" "$dump_n"

    # 触发 dump
    if [ -n "$triggered" ]; then
        dump_n=$((dump_n + 1))
        save_state "$cur_rate" "$cur_req" "$cur_hit" "$cur_miss" "$cur_pc" "$router_status" "$router_err" "$new_baseline" "$dump_n"
        local dump_dir=$(trigger_dump "$reason")
        echo "[$(ts)] CHECK: pf_rate=$cur_rate router=$router_status $router_tiers → DUMP: $dump_dir" >> "$LOG_FILE"
    else
        local status_icon="✅"
        [ "$(echo "$cur_rate < $HIT_RATE_WARN" | bc -l 2>/dev/null || echo 0)" = "1" ] && status_icon="⚠️"
        echo "[$(ts)] $status_icon pf_rate=$cur_rate router=$router_status err=$router_err $router_tiers" >> "$LOG_FILE"
    fi

    # 输出
    local rate_pct=$(python3 -c "print(round($cur_rate*100,1))")
    echo "[$(ts)] pf=${rate_pct}% router=$router_status err=$router_err $router_tiers ${triggered:+⚠️ DUMP: $reason}"
}

# ── 主入口 ────────────────────────────────────────────────────────

case "${1:-once}" in
    once)
        do_check
        ;;
    run)
        echo "Hermes 缓存监控运行中 (间隔60s, 输出到 $LOG_FILE)"
        echo "阈值: permafrost_hit_rate<${HIT_RATE_DUMP} 或 router_unhealthy 或 router_errors+5 → 触发dump"
        echo "Ctrl+C 停止"
        while true; do
            do_check
            sleep 60
        done
        ;;
    daemon)
        nohup bash "$0" run >> "$MONITOR_DIR/daemon.log" 2>&1 &
        echo "Hermes 缓存监控守护已启动 (PID $!)"
        echo "日志: $MONITOR_DIR/daemon.log"
        echo "停止: kill $!"
        ;;
    status)
        echo "=== Hermes 缓存监控 — 最近检查 ==="
        tail -10 "$LOG_FILE" 2>/dev/null || echo "(无记录)"
        echo ""
        echo "=== dump 历史 ==="
        ls -lt "$MONITOR_DIR"/dump-* 2>/dev/null | head -5 || echo "(无dump)"
        echo ""
        echo "=== Permafrost 缓存状态 ==="
        get_permafrost_stats | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d:
    print(f'  permafrost: {d[\"error\"]}')
else:
    print(f'  命中率: {d.get(\"hit_rate\",0)*100:.1f}%')
    print(f'  总请求: {d.get(\"requests\",0)}')
    print(f'  缓存命中 tokens: {d.get(\"cache_hit_tokens\",0):,}')
    print(f'  缓存未命中 tokens: {d.get(\"cache_miss_tokens\",0):,}')
    print(f'  节省成本: \${d.get(\"saved_usd\",0):.4f} ({d.get(\"saved_pct\",0)}%)')
    print(f'  活跃 sessions: {len(d.get(\"sessions\",{}))}')
    print(f'  前缀变化: {d.get(\"prefix_changes\",0)}')
" 2>/dev/null || echo "  无法获取 permafrost 状态"
        echo ""
        echo "=== Model-Router 状态 ==="
        get_router_health | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f'  状态: {d.get(\"status\",\"unknown\")}')
print(f'  版本: {d.get(\"version\",\"unknown\")}')
print(f'  运行时间: {round(d.get(\"uptime\",0)/3600,1)} 小时')
" 2>/dev/null || echo "  无法获取 router 状态"
        echo ""
        get_router_stats | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d:
    print(f'  router stats: {d[\"error\"]}')
else:
    tiers=d.get('tiers',{})
    total=sum(tiers.values())
    print(f'  总请求: {total}')
    for k,v in sorted(tiers.items()):
        model=d.get('models',{}).get(k,'?')
        print(f'    {k}: {v} ({model})')
    print(f'  降级次数: {d.get(\"fallbacks\",{})}')
    print(f'  错误数: {d.get(\"errors\",0)}')
" 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {once|run|daemon|status}"
        exit 1
        ;;
esac
