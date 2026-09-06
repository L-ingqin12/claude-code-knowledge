#!/bin/bash
# ============================================================================
# 诊断中继 逃生脚本
# 恢复: CC → permafrost :8788 → proxy :8787 (移除 relay 层)
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELAY_PID_FILE="$SCRIPT_DIR/relay.pid"
RELAY_PORT_FILE="$SCRIPT_DIR/relay.port"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${GREEN}[rollback]${NC} $1"; }
err()  { echo -e "${RED}[rollback]${NC} $1"; }

echo ""
log "=== 诊断中继 逃生 ==="

RELAY_PORT=$(cat "$RELAY_PORT_FILE" 2>/dev/null || echo "?")
log "中继端口: ${RELAY_PORT}"

# ── 1. 切换 permafrost 回直连 proxy ───────────────────────────────

log "切换 permafrost upstream → proxy (:8787) 直连..."
source /root/claude-permafrost-deploy.sh
start_permafrost "http://127.0.0.1:8787" "方案 C (逃生: 移除 relay)"

sleep 2

# ── 2. 停止 relay ─────────────────────────────────────────────────

if [ -f "$RELAY_PID_FILE" ]; then
    pid=$(cat "$RELAY_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        log "relay 已停止 (PID $pid, 端口 $RELAY_PORT)"
    else
        log "relay 已不在运行"
    fi
    rm -f "$RELAY_PID_FILE" "$RELAY_PORT_FILE"
else
    log "relay pid 文件不存在, 可能已停止"
fi

# ── 3. 清理残留 relay 进程 ────────────────────────────────────────

pkill -f "relay.js" 2>/dev/null && warn "已清理残留 relay 进程" || true

# ── 4. 验证恢复 ───────────────────────────────────────────────────

sleep 1
if curl -s --connect-timeout 3 "http://127.0.0.1:8788/permafrost/health" >/dev/null 2>&1; then
    log "逃生成功: permafrost (:8788) → proxy (:8787) 直连"
else
    err "逃生后 permafrost 无响应, 请手动检查"
    exit 1
fi

echo ""
log "============================================"
log "  逃生完成 — 已移除诊断中继"
log "  permafrost (:8788) → proxy (:8787)"
log "============================================"
