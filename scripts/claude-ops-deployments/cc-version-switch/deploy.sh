#!/bin/bash
# ============================================================================
# CC 版本切换 — 部署脚本 (185→179)
# 原理: CC 179 无 cancelRetry(), 不会在 60-88s 主动断连
# 逃生: bash rollback.sh (秒级恢复)
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_LINK="/root/.local/bin/claude"
VERSIONS_DIR="/root/.local/share/claude/versions"
TARGET_VERSION="2.1.179"
TARGET_BIN="$VERSIONS_DIR/$TARGET_VERSION"
CURRENT=$(readlink -f "$CLAUDE_LINK" 2>/dev/null || echo "unknown")
DEPLOY_LOG="/root/workspace/claude-code-knowledge/deployments/deployment-log.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[cc-switch]${NC} $1"; }
warn() { echo -e "${YELLOW}[cc-switch]${NC} $1"; }
err()  { echo -e "${RED}[cc-switch]${NC} $1"; }

echo ""
log "=== CC 版本切换 部署 ==="

# ── 预检 ──────────────────────────────────────────────────────────

log "当前版本: $CURRENT"

if [ ! -f "$TARGET_BIN" ]; then
    err "目标版本不存在: $TARGET_BIN"
    err "可用版本: $(ls $VERSIONS_DIR/)"
    exit 1
fi

if [ "$(readlink -f "$CLAUDE_LINK")" = "$TARGET_BIN" ]; then
    warn "已经是 $TARGET_VERSION, 无需切换"
    exit 0
fi

# 验证目标版本可执行
if ! "$TARGET_BIN" --version >/dev/null 2>&1; then
    err "目标版本无法执行: $TARGET_BIN"
    exit 1
fi
log "预检通过: $TARGET_VERSION 可用"

# ── 执行切换 ──────────────────────────────────────────────────────

log "切换: $CURRENT → $TARGET_BIN"
ln -sf "$TARGET_BIN" "$CLAUDE_LINK"

new=$(readlink -f "$CLAUDE_LINK")
if [ "$new" != "$TARGET_BIN" ]; then
    err "切换失败!"
    exit 1
fi
log "已切换到: $TARGET_VERSION"

# ── 审计日志 ──────────────────────────────────────────────────────

cat >> "$DEPLOY_LOG" << EOF

### cc-version-switch (部署)
- **时间**: $(date -Iminutes)
- **操作**: CC 185 → 179
- **原理**: 179 无 cancelRetry()
- **逃生**: \`bash deployments/cc-version-switch/rollback.sh\`
EOF

log "============================================"
log "  切换完成: CC $TARGET_VERSION"
log "  逃生: bash $SCRIPT_DIR/rollback.sh"
log "  注意: 仅影响新 session, 已运行的 session 不变"
log "============================================"
