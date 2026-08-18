#!/bin/bash
# ============================================================================
# CC 版本切换 — 逃生脚本 (179→185, 秒级恢复)
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_LINK="/root/.local/bin/claude"
VERSIONS_DIR="/root/.local/share/claude/versions"
RESTORE_VERSION="2.1.185"
RESTORE_BIN="$VERSIONS_DIR/$RESTORE_VERSION"
DEPLOY_LOG="/root/workspace/claude-code-knowledge/deployments/deployment-log.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${GREEN}[rollback]${NC} $1"; }
err()  { echo -e "${RED}[rollback]${NC} $1"; }

echo ""
log "=== CC 版本切换 逃生 ==="

if [ ! -f "$RESTORE_BIN" ]; then
    err "恢复版本不存在: $RESTORE_BIN"
    exit 1
fi

log "恢复: → $RESTORE_VERSION"
ln -sf "$RESTORE_BIN" "$CLAUDE_LINK"

new=$(readlink -f "$CLAUDE_LINK")
log "当前版本: $new"

cat >> "$DEPLOY_LOG" << EOF

### cc-version-switch (逃生)
- **时间**: $(date -Iminutes)
- **操作**: 逃生回滚
- **恢复**: CC 179 → 185
EOF

log "============================================"
log "  逃生完成 — CC 已恢复 $RESTORE_VERSION"
log "============================================"
