#!/bin/bash
# ============================================================================
# 代理变更管控门禁 — 回滚脚本
# 从备份恢复生产 proxy.js
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
PRODUCTION="/root/claude-resilience-proxy.js"
MANIFEST="/root/.claude/proxy.manifest"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${GREEN}[rollback]${NC} $1"; }
err()  { echo -e "${RED}[rollback]${NC} $1"; }

# ── 无参数: 列出可用备份 ─────────────────────────────────────────────

if [ -z "${1:-}" ]; then
  if [ -d "$BACKUP_DIR" ]; then
    echo "可用备份:"
    ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r || echo "  (无备份)"
  else
    echo "备份目录不存在: $BACKUP_DIR"
  fi
  echo ""
  echo "用法: bash $0 <备份文件>"
  exit 0
fi

backup_file="$1"

# ── 检查备份文件 ──────────────────────────────────────────────────────

if [ ! -f "$backup_file" ] && [ ! -f "$BACKUP_DIR/$backup_file" ]; then
  err "备份文件不存在: $backup_file"
  err "请指定完整路径或在 backups/ 目录下的文件名"
  exit 1
fi

# 支持短名称: 仅传文件名则自动补全路径
[ ! -f "$backup_file" ] && backup_file="$BACKUP_DIR/$backup_file"

# ── 恢复 ──────────────────────────────────────────────────────────────

cp "$backup_file" "$PRODUCTION"
log "已恢复: $backup_file → $PRODUCTION"

# ── 验证 ──────────────────────────────────────────────────────────────

restored_md5=$(md5sum "$PRODUCTION" | awk '{print $1}')
backup_md5=$(md5sum "$backup_file" | awk '{print $1}')

if [ "$restored_md5" = "$backup_md5" ]; then
  log "校验通过: md5 = $restored_md5"
  # 更新 Manifest
  mkdir -p "$(dirname "$MANIFEST")"
  md5sum "$PRODUCTION" > "$MANIFEST"
  log "Manifest 已更新"
else
  err "校验失败: 恢复后 md5 不匹配"
  exit 1
fi

log "回滚完成"
