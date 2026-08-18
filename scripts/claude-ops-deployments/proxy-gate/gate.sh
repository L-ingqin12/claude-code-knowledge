#!/bin/bash
# ============================================================================
# 代理变更管控门禁 — Phase 1
# 检测生产环境 proxy.js 是否被外部修改 (非 deploy.sh 工作流)
#
# 子命令:
#   init  — 记录生产 proxy.js 的 md5 到 Manifest
#   check — 比对当前 md5 与 Manifest, 不匹配则告警
#   sync  — 备份当前生产版本, 用工作区版本覆盖, 更新 Manifest
#   guard — 静默检查 (用于 SessionStart), 仅在不匹配时输出
#
# Manifest: /root/.claude/proxy.manifest (单行: md5sum /path/to/proxy.js)
# 备份:     deployments/proxy-gate/backups/proxy.js.YYYYMMDD-HHMMSS
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
MANIFEST="/root/.claude/proxy.manifest"
PRODUCTION="/root/claude-resilience-proxy.js"
WORKSPACE="/root/workspace/agent-knowledge-base/claude-resilience-proxy.js"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[gate]${NC} $1"; }
warn() { echo -e "${YELLOW}[gate]${NC} $1"; }
err()  { echo -e "${RED}[gate]${NC} $1"; }

# ── 辅助函数 ──────────────────────────────────────────────────────────

current_md5() {
  md5sum "$PRODUCTION" 2>/dev/null | awk '{print $1}'
}

manifest_md5() {
  head -1 "$MANIFEST" 2>/dev/null | awk '{print $1}'
}

# ── init ──────────────────────────────────────────────────────────────

do_init() {
  if [ ! -f "$PRODUCTION" ]; then
    err "生产文件不存在: $PRODUCTION"
    exit 1
  fi
  mkdir -p "$(dirname "$MANIFEST")"
  md5sum "$PRODUCTION" > "$MANIFEST"
  log "Manifest 已记录: $(cat "$MANIFEST")"
}

# ── check ─────────────────────────────────────────────────────────────

do_check() {
  if [ ! -f "$MANIFEST" ]; then
    warn "Manifest 不存在, 请先运行: bash $0 init"
    exit 0
  fi
  if [ ! -f "$PRODUCTION" ]; then
    err "生产文件不存在: $PRODUCTION"
    exit 1
  fi

  cur=$(current_md5)
  man=$(manifest_md5)

  if [ "$cur" = "$man" ]; then
    log "一致: $PRODUCTION (md5: $cur)"
    exit 0
  else
    err "不一致!"
    err "  Manifest: $man"
    err "  当前:     $cur"
    err "  运行 'bash $0 sync' 以同步工作区版本"
    exit 1
  fi
}

# ── sync ──────────────────────────────────────────────────────────────

do_sync() {
  if [ ! -f "$WORKSPACE" ]; then
    err "工作区文件不存在: $WORKSPACE"
    exit 1
  fi
  if [ ! -f "$PRODUCTION" ]; then
    err "生产文件不存在: $PRODUCTION"
    exit 1
  fi

  # 备份当前生产版本
  mkdir -p "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/proxy.js.$(date +%Y%m%d-%H%M%S)"
  cp "$PRODUCTION" "$backup_file"
  log "已备份: $backup_file"

  # 用工作区版本覆盖生产版本
  cp "$WORKSPACE" "$PRODUCTION"
  log "已同步: $WORKSPACE → $PRODUCTION"

  # 更新 Manifest
  md5sum "$PRODUCTION" > "$MANIFEST"
  log "Manifest 已更新: $(cat "$MANIFEST")"
}

# ── guard (静默检查, 仅在不匹配时输出) ────────────────────────────────

do_guard() {
  if [ ! -f "$MANIFEST" ] || [ ! -f "$PRODUCTION" ]; then
    exit 0
  fi

  cur=$(current_md5)
  man=$(manifest_md5)

  if [ "$cur" != "$man" ]; then
    warn "proxy.js 已被外部修改! 运行 'bash $SCRIPT_DIR/gate.sh sync' 以同步"
    exit 1
  fi
  exit 0
}

# ── 主入口 ────────────────────────────────────────────────────────────

case "${1:-}" in
  init)  do_init  ;;
  check) do_check ;;
  sync)  do_sync  ;;
  guard) do_guard ;;
  *)
    echo "用法: bash $0 {init|check|sync|guard}"
    echo ""
    echo "  init  记录生产 proxy.js 的 md5 到 Manifest"
    echo "  check 比对当前 md5 与 Manifest"
    echo "  sync  备份生产版本, 用工作区版本覆盖, 更新 Manifest"
    echo "  guard 静默检查 (SessionStart), 仅在不匹配时输出"
    exit 1
    ;;
esac
