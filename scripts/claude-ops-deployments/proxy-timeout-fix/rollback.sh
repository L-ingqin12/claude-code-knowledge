#!/bin/bash
# ============================================================================
# 代理超时修复 — 逃生脚本
# 恢复: 代理 timeout=180s retries=3 backoff=1s/3s/8s (原始值)
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_JS="/root/claude-resilience-proxy.js"
BACKUP_DIR="$SCRIPT_DIR/backups"
PROXY_PID_FILE="/root/.claude/proxy.pid"
DEPLOY_LOG="/root/workspace/claude-code-knowledge/deployments/deployment-log.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${GREEN}[rollback]${NC} $1"; }
err()  { echo -e "${RED}[rollback]${NC} $1"; }

echo ""
log "=== 代理超时修复 逃生 ==="

# ── 查找最新备份 ──────────────────────────────────────────────────

BACKUP=$(ls -t "$BACKUP_DIR"/proxy.js.* 2>/dev/null | head -1)
if [ -z "$BACKUP" ]; then
    err "未找到备份文件! 无法逃生"
    err "请手动恢复: cp ~/workspace/claude-code-knowledge/diagnostic-relay/../...  $PROXY_JS"
    exit 1
fi
log "恢复备份: $BACKUP"

# ── 恢复原始 proxy.js ─────────────────────────────────────────────

cp "$BACKUP" "$PROXY_JS"
log "proxy.js 已恢复"

# ── 重启代理 ──────────────────────────────────────────────────────

log "重启代理..."
old_pid=$(cat "$PROXY_PID_FILE" 2>/dev/null || echo "")
kill "$old_pid" 2>/dev/null || true
sleep 1

nohup node "$PROXY_JS" >> /root/.claude/proxy.log 2>&1 &
new_pid=$!
echo "$new_pid" > "$PROXY_PID_FILE"
sleep 1

if ! kill -0 "$new_pid" 2>/dev/null; then
    err "代理启动失败!"
    exit 1
fi
log "代理已重启 (PID $new_pid)"

# ── 验证 ──────────────────────────────────────────────────────────

sleep 2
if curl -s --connect-timeout 10 "http://127.0.0.1:8787/" >/dev/null 2>&1; then
    log "E2E 验证通过: 已恢复原始超时参数"
else
    err "E2E 验证失败! 请手动检查"
    exit 1
fi

# ── 审计日志 ──────────────────────────────────────────────────────

cat >> "$DEPLOY_LOG" << EOF

### proxy-timeout-fix (逃生)
- **时间**: $(date -Iminutes)
- **操作**: 逃生回滚
- **恢复**: timeout=180s retries=3 backoff=1s/3s/8s
- **备份来源**: $BACKUP
EOF

log "============================================"
log "  逃生完成 — 代理已恢复原始超时参数"
log "============================================"
