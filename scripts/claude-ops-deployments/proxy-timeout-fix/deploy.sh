#!/bin/bash
# ============================================================================
# 代理超时修复 — 部署脚本
# 原理: 代理超时 180s→90s, 重试 3→1, 使代理在 CC cancelRetry(~60s)之前返回504
# 逃生: bash rollback.sh
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_JS="/root/claude-resilience-proxy.js"
BACKUP_DIR="$SCRIPT_DIR/backups"
BACKUP_FILE="$BACKUP_DIR/proxy.js.$(date +%Y%m%d-%H%M%S)"
PROXY_PID_FILE="/root/.claude/proxy.pid"
DEPLOY_LOG="/root/workspace/claude-code-knowledge/deployments/deployment-log.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[timeout-fix]${NC} $1"; }
warn() { echo -e "${YELLOW}[timeout-fix]${NC} $1"; }
err()  { echo -e "${RED}[timeout-fix]${NC} $1"; }

echo ""
log "=== 代理超时修复 部署 ==="

# ── 预检 ──────────────────────────────────────────────────────────

log "预检..."

# 检查 proxy.js 存在
if [ ! -f "$PROXY_JS" ]; then
    err "proxy.js 不存在: $PROXY_JS"
    exit 1
fi

# 检查 proxy 在运行
if [ ! -f "$PROXY_PID_FILE" ] || ! kill -0 "$(cat $PROXY_PID_FILE)" 2>/dev/null; then
    err "proxy 未运行"
    exit 1
fi

# 检查是否已经打过补丁
if grep -q 'PROXY_TIMEOUT_MS' "$PROXY_JS" 2>/dev/null; then
    warn "检测到 proxy.js 已包含补丁, 可能已部署过"
    warn "如需重新部署, 请先执行 rollback.sh 恢复原始版本"
    exit 0
fi

log "预检通过"

# ── 备份 ──────────────────────────────────────────────────────────

mkdir -p "$BACKUP_DIR"
cp "$PROXY_JS" "$BACKUP_FILE"
log "已备份: $BACKUP_FILE"

# ── 应用补丁 ──────────────────────────────────────────────────────

log "应用补丁..."

# 补丁内容: timeout 180s→90s, retries 3→1, backoff改为env var可配
# 使用 sed 进行精确替换

# 1. timeout: 180000 → 90000 (通过 env var PROXY_TIMEOUT_MS)
sed -i 's/timeout: 180000,/timeout: parseInt(process.env.PROXY_TIMEOUT_MS || "90000"),/' "$PROXY_JS"

# 2. RETRIES: 3 → 1 (通过 env var PROXY_RETRIES)
sed -i 's/const RETRIES = 3;/const RETRIES = parseInt(process.env.PROXY_RETRIES || "1");/' "$PROXY_JS"

# 3. BACKOFF 改为 env var
sed -i 's/const BACKOFF = \[1000, 3000, 8000\];/const BACKOFF = (process.env.PROXY_BACKOFF_MS || "1000").split(",").map(Number);/' "$PROXY_JS"

# 验证补丁应用成功
if grep -q 'PROXY_TIMEOUT_MS\|PROXY_RETRIES\|PROXY_BACKOFF_MS' "$PROXY_JS"; then
    log "补丁已应用 (3处修改)"
else
    err "补丁应用失败! 恢复备份..."
    cp "$BACKUP_FILE" "$PROXY_JS"
    exit 1
fi

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
    err "代理启动失败! 自动回滚..."
    cp "$BACKUP_FILE" "$PROXY_JS"
    nohup node "$PROXY_JS" >> /root/.claude/proxy.log 2>&1 &
    echo "$!" > "$PROXY_PID_FILE"
    exit 1
fi
log "代理已重启 (PID $new_pid)"

# ── E2E 验证 ──────────────────────────────────────────────────────

log "E2E 验证..."
sleep 2
if curl -s --connect-timeout 10 "http://127.0.0.1:8787/" >/dev/null 2>&1; then
    log "E2E 验证通过"
else
    err "E2E 验证失败! 自动回滚..."
    kill "$new_pid" 2>/dev/null
    cp "$BACKUP_FILE" "$PROXY_JS"
    nohup node "$PROXY_JS" >> /root/.claude/proxy.log 2>&1 &
    echo "$!" > "$PROXY_PID_FILE"
    exit 1
fi

# ── 审计日志 ──────────────────────────────────────────────────────

cat >> "$DEPLOY_LOG" << EOF

### proxy-timeout-fix (部署)
- **时间**: $(date -Iminutes)
- **操作**: 部署
- **变更**: timeout 180s→90s, retries 3→1, backoff env var化
- **备份**: $BACKUP_FILE
- **逃生**: \`bash deployments/proxy-timeout-fix/rollback.sh\`
EOF

log "============================================"
log "  部署完成"
log "  新参数: timeout=90s retries=1 backoff=1s"
log "  逃生: bash $SCRIPT_DIR/rollback.sh"
log "============================================"
