#!/bin/bash
# ────────────────────────────────────────────────────────
# Claude Code 完全回滚 — 恢复直连 DeepSeek, 停止所有代理
# 用法: bash /root/claude-rollback.sh
#
# 与 claude-permafrost-rollback.sh 的关系:
#   本脚本 = L4 完全清零 (等同于 claude-permafrost-rollback.sh nuke)
#   permafrost-rollback.sh L1 = 仅绕过 proxy, 保留 permafrost 缓存优化
# ────────────────────────────────────────────────────────
set -e

ORIGINAL_URL="https://api.deepseek.com/anthropic"
CONFIG_FILE="$HOME/.claude/settings.local.json"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${YELLOW}=== Complete Rollback — 恢复直连 DeepSeek ===${NC}"

# 1. 停止所有代理 (Node.js + Python permafrost)
echo -e "${GREEN}[1/4] Stopping all proxies...${NC}"
pkill -f "claude-resilience-proxy.js" 2>/dev/null || true

pkill -f "permafrost_proxy.py" 2>/dev/null || true
rm -f /root/.claude/proxy.pid
echo "  All proxy processes killed"

# 2. 恢复 settings.local.json
echo -e "${GREEN}[2/4] Restoring settings.local.json...${NC}"
if [ -f "$CONFIG_FILE" ]; then
    python3 -c "
import json
with open('$CONFIG_FILE') as f:
    d = json.load(f)
# 恢复 ANTHROPIC_BASE_URL 为直连
if 'env' in d:
    d['env']['ANTHROPIC_BASE_URL'] = '$ORIGINAL_URL'
# 移除 permafrost auto-deploy hook
hooks = d.get('hooks',{}).get('SessionStart',[])
new_hooks = []
for h in hooks:
    cmds = h.get('hooks',[])
    kept = [c for c in cmds if 'permafrost-deploy' not in c.get('command','')]
    if kept:
        h['hooks'] = kept
        new_hooks.append(h)
if new_hooks:
    d['hooks']['SessionStart'] = new_hooks
else:
    d['hooks'].pop('SessionStart', None)
    if not d['hooks']:
        d.pop('hooks', None)
with open('$CONFIG_FILE', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print('  settings.local.json → $ORIGINAL_URL, auto-deploy disabled')
" 2>/dev/null || echo "  settings.local.json update skipped (file not found or parse error)"
fi

# 3. 恢复 .zshrc
echo -e "${GREEN}[3/4] Restoring .zshrc...${NC}"
sed -i 's|export ANTHROPIC_BASE_URL=.*|export ANTHROPIC_BASE_URL="'"$ORIGINAL_URL"'"|' /root/.zshrc 2>/dev/null || true
echo "  .zshrc → $ORIGINAL_URL"

# 4. 恢复 .bashrc
echo -e "${GREEN}[4/4] Restoring .bashrc...${NC}"
sed -i 's|export ANTHROPIC_BASE_URL=.*|export ANTHROPIC_BASE_URL="'"$ORIGINAL_URL"'"|' /root/.bashrc 2>/dev/null || true
echo "  .bashrc → $ORIGINAL_URL"

echo ""
echo -e "${GREEN}=== Rollback complete ===${NC}"
echo "  当前会话立即生效:"
echo "    export ANTHROPIC_BASE_URL=\"$ORIGINAL_URL\""
echo ""
echo "  重新启用缓存优化:"
echo "    bash /root/claude-permafrost-deploy.sh start"
