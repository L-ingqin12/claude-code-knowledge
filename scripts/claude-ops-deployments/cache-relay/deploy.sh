#!/bin/bash
# ============================================================================
# cache-relay 部署脚本（hook 启动形式，照 KB claude-permafrost-deploy.sh）
# ============================================================================
# 用法:
#   bash deploy.sh start            热启动中继（daemon，不重启 Claude Code）
#   bash deploy.sh install-hook     安装 SessionStart hook + 设 ANTHROPIC_BASE_URL（先备份）
#   bash deploy.sh rollback         软回滚：undeploy + 恢复 settings 备份
#   bash deploy.sh status           状态
#
# 依赖: bash + node（JSON 读改写，不打印任何密钥）
# 安全: install-hook 先把 settings.local.json 备份为 *.cache-relay.bak；rollback 一键恢复。
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELAY_SCRIPT="$SCRIPT_DIR/cache-relay.mjs"
RELAY_PORT="${RELAY_PORT:-8790}"
CONFIG_FILE="$HOME/.claude/settings.local.json"
BACKUP_FILE="$HOME/.claude/settings.local.json.cache-relay.bak"

case "${1:-status}" in
  start)
    node "$RELAY_SCRIPT" deploy
    ;;
  install-hook)
    if [ ! -f "$CONFIG_FILE" ]; then echo "✗ 未找到 $CONFIG_FILE"; exit 1; fi
    cp "$CONFIG_FILE" "$BACKUP_FILE" && echo "已备份 → $BACKUP_FILE"
    RELAY_SCRIPT="$RELAY_SCRIPT" RELAY_PORT="$RELAY_PORT" node --input-type=commonjs - <<'NODE'
const fs = require('fs')
const CF = process.env.HOME + '/.claude/settings.local.json'
const d = JSON.parse(fs.readFileSync(CF, 'utf8'))
d.env = d.env || {}
d.env.ANTHROPIC_BASE_URL = 'http://127.0.0.1:' + process.env.RELAY_PORT
const hooks = d.hooks || (d.hooks = {})
const sh = hooks.SessionStart || (hooks.SessionStart = [])
const exists = sh.some(h => (h.hooks || []).some(c => (c.command || '').includes('cache-relay')))
if (!exists) {
  sh.unshift({ matcher: '', hooks: [{ type: 'command', command: 'node "' + process.env.RELAY_SCRIPT + '" deploy 2>/dev/null || true' }] })
  fs.writeFileSync(CF, JSON.stringify(d, null, 2))
  console.log('OK: SessionStart hook 已安装 + ANTHROPIC_BASE_URL 指向 :' + process.env.RELAY_PORT)
} else {
  console.log('hook 已存在，跳过')
}
NODE
    ;;
  rollback)
    node "$RELAY_SCRIPT" undeploy
    if [ -f "$BACKUP_FILE" ]; then
      cp "$BACKUP_FILE" "$CONFIG_FILE" && rm -f "$BACKUP_FILE" && echo "已恢复 settings.local.json 备份"
    else
      echo "无备份文件，仅停用中继"
    fi
    ;;
  status)
    node "$RELAY_SCRIPT" status 2>/dev/null || true
    [ -f "$BACKUP_FILE" ] && echo "存在回滚备份: $BACKUP_FILE" || echo "无回滚备份"
    [ -f "$HOME/.cache-relay/.disabled" ] && echo "状态: 软回滚(.disabled)" || echo "状态: 可用"
    ;;
  *) echo "Usage: $0 {start|install-hook|rollback|status}" ;;
esac
