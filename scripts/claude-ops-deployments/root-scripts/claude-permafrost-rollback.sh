#!/bin/bash
# ============================================================================
# Permafrost 逃生通道 — 逐层回退
# ============================================================================
# 架构层级:
#   方案C: CC → permafrost(:8788) → proxy(:8787) → DeepSeek
#   方案B: CC → permafrost(:8788) → DeepSeek 直连
#   直连:  CC → DeepSeek 直连
#
# 逃生命令 (每次只退一层):
#   L1: bash $0            C→B   (permafrost 绕过proxy, 保留缓存优化)
#   L2: bash $0 full       B→直连 (绕过permafrost, 无缓存优化)
#   L3: bash $0 disable   禁用auto-deploy hook
#
# 恢复命令:
#   直连→B: deploy.sh start + 手动设 ANTHROPIC_BASE_URL=:8788
#   B→C:    deploy.sh start
# ============================================================================
set -e

CONFIG_FILE="$HOME/.claude/settings.local.json"
PERMAFROST_PORT=8788
PROXY_PORT=8787
PERMAFROST_HOME="${PERMAFROST_HOME:-$HOME/.permafrost}"
PERMAFROST_SCRIPT="$HOME/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_proxy.py"
PROXY_UPSTREAM="http://127.0.0.1:${PROXY_PORT}"
DIRECT_UPSTREAM="https://api.deepseek.com/anthropic"
HEALTH_URL="http://127.0.0.1:${PERMAFROST_PORT}/permafrost/health"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[rollback]${NC} $1"; }
warn() { echo -e "${YELLOW}[rollback]${NC} $1"; }
err()  { echo -e "${RED}[rollback]${NC} $1"; }

get_permafrost_upstream() {
    curl -s "$HEALTH_URL" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('upstream','down'))" 2>/dev/null || echo "down"
}

permafrost_running() {
    curl -s --connect-timeout 1 "$HEALTH_URL" >/dev/null 2>&1
}

get_cc_url() {
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('env',{}).get('ANTHROPIC_BASE_URL','?'))" 2>/dev/null || echo "?"
}

# ── 状态 ─────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  逃生通道 — 逐层回退"
    echo "════════════════════════════════════════════════════"

    local pf=$(get_permafrost_upstream)
    local cc=$(get_cc_url)

    # 判断当前方案
    if echo "$cc" | grep -q "8788"; then
        case "$pf" in
            "$PROXY_UPSTREAM")  echo -e "  当前: ${GREEN}方案C${NC} (CC → permafrost → proxy → DS)" ;;
            "$DIRECT_UPSTREAM") echo -e "  当前: ${YELLOW}方案B${NC} (CC → permafrost → DS)" ;;
            "down")             echo -e "  当前: ${RED}异常${NC} (permafrost DOWN)" ;;
            *)                 echo -e "  当前: ${YELLOW}方案B?${NC} (pf→$pf)" ;;
        esac
    elif echo "$cc" | grep -q "deepseek"; then
        echo -e "  当前: ${RED}直连${NC} (CC → DS, 无缓存优化)"
    else
        echo -e "  当前: ${RED}未知${NC} (CC→$cc)"
    fi

    echo "  permafrost: $(permafrost_running && echo 'UP' || echo 'DOWN')  proxy: $(curl -sI --connect-timeout 1 http://127.0.0.1:$PROXY_PORT/ >/dev/null 2>&1 && echo 'UP' || echo 'DOWN')"
    echo ""
    echo "  逐层回退:"
    echo "    L0m bash $0 model-off    关闭model路由"
    echo "    L0a bash $0 tools-off    tools重排→关 (保留currentDate)"
    echo "    L0b bash $0 patches-off  全部补丁→关 (原版permafrost)"
    echo "    L1  bash $0              C→B (保留缓存优化)"
    echo "    L2  bash $0 full         B→直连"
    echo "    L3  bash $0 disable      禁用auto-deploy"
    echo ""
}

# ── L0m: 关闭 model 路由 ──────────────────────────────────────────

do_model_router_off() {
    log "L0m: 关闭 model 路由，重启 permafrost"
    pkill -f permafrost_proxy.py 2>/dev/null || true
    for i in $(seq 1 10); do
        curl -s --connect-timeout 1 "$HEALTH_URL" >/dev/null 2>&1 || break; sleep 1
    done
    rm -rf "$(dirname "$PERMAFROST_SCRIPT")/__pycache__"
    local upstream=$(get_permafrost_upstream)
    [ "$upstream" = "down" ] && upstream="$PROXY_UPSTREAM"
    mkdir -p "$PERMAFROST_HOME"
    PERMAFROST_PORT=$PERMAFROST_PORT PERMAFROST_MODE=aggressive     PERMAFROST_UPSTREAM="$upstream" PERMAFROST_HOME="$PERMAFROST_HOME"     PERMAFROST_NORMALIZE_TOOLS=1 PERMAFROST_MODEL_ROUTING=0 PERMAFROST_AUTOSTART=1     nohup python3 "$PERMAFROST_SCRIPT" >>"$PERMAFROST_HOME/proxy.log" 2>&1 &
    for i in $(seq 1 10); do sleep 1; permafrost_running && break; done
    if permafrost_running; then log "L0m 完成 [model路由 ❌]"; fi
}

# ── L0a: 关闭 tools 重排 ─────────────────────────────────────────

do_tools_off() {
    log "L0a: 关闭 tools 重排补丁 (保留 currentDate)"

    pkill -f permafrost_proxy.py 2>/dev/null || true
    for i in $(seq 1 10); do
        curl -s --connect-timeout 1 "$HEALTH_URL" >/dev/null 2>&1 || break
        sleep 1
    done
    rm -rf "$(dirname "$PERMAFROST_SCRIPT")/__pycache__"
    local upstream=$(get_permafrost_upstream)
    [ "$upstream" = "down" ] && upstream="$PROXY_UPSTREAM"
    mkdir -p "$PERMAFROST_HOME"
    PERMAFROST_PORT=$PERMAFROST_PORT PERMAFROST_MODE=aggressive \
    PERMAFROST_UPSTREAM="$upstream" PERMAFROST_HOME="$PERMAFROST_HOME" \
    PERMAFROST_NORMALIZE_TOOLS=0 PERMAFROST_AUTOSTART=1 \
    nohup python3 "$PERMAFROST_SCRIPT" >>"$PERMAFROST_HOME/proxy.log" 2>&1 &
    for i in $(seq 1 10); do sleep 1; permafrost_running && break; done

    if permafrost_running; then
        log "L0a 完成 [currentDate ✅ + tools ❌]"
        warn "恢复tools: deploy.sh start (默认 PERMAFROST_NORMALIZE_TOOLS=1)"
    else
        err "L0a 失败"
    fi
}

do_patches_off() {
    log "L0b: 关闭全部补丁 (重启到原版 permafrost)"
    local src="$(dirname "$PERMAFROST_SCRIPT")/permafrost_align.py"
    if [ -f "${src}.orig" ]; then
        cp "${src}.orig" "$src"
        log "已还原 permafrost_align.py.orig"
    else
        warn "无 .orig 备份, 需手动: claude plugin install permafrost@permafrost"
    fi
    do_tools_off
}

# ── L1: 方案C → 方案B ────────────────────────────────────────────

do_c_to_b() {
    local current=$(get_permafrost_upstream)

    if [ "$current" = "$DIRECT_UPSTREAM" ]; then
        warn "当前已是方案B, 无需操作"
        return 0
    fi

    if [ "$current" = "down" ]; then
        err "permafrost 未运行, 请先启动: bash /root/claude-permafrost-deploy.sh start"
        return 1
    fi

    log "L1: 方案C → 方案B (permafrost 绕过 proxy)"

    # 使用 deploy.sh rollback (已含端口等待修复)
    bash /root/claude-permafrost-deploy.sh rollback 2>/dev/null && {
        log "L1 完成 [方案B]"
        return 0
    }

    # 兜底: 手动重启
    warn "deploy.sh 失败, 手动回退..."
    pkill -f permafrost_proxy.py 2>/dev/null || true
    for i in $(seq 1 10); do
        curl -s --connect-timeout 1 "$HEALTH_URL" >/dev/null 2>&1 || break
        sleep 1
    done
    rm -rf "$(dirname "$PERMAFROST_SCRIPT")/__pycache__"
    mkdir -p "$PERMAFROST_HOME" "$PERMAFROST_HOME/dumps"
    PERMAFROST_PORT=$PERMAFROST_PORT PERMAFROST_MODE=aggressive \
    PERMAFROST_UPSTREAM="$DIRECT_UPSTREAM" PERMAFROST_HOME="$PERMAFROST_HOME" \
    PERMAFROST_NORMALIZE_TOOLS=1 PERMAFROST_AUTOSTART=1 \
    nohup python3 "$PERMAFROST_SCRIPT" >>"$PERMAFROST_HOME/proxy.log" 2>&1 &
    for i in $(seq 1 10); do
        sleep 1
        permafrost_running && break
    done

    if permafrost_running && [ "$(get_permafrost_upstream)" = "$DIRECT_UPSTREAM" ]; then
        log "L1 完成 [方案B]"
    else
        err "L1 失败 → 自动执行 L2"
        do_full_rollback
    fi
}

# ── L2: 方案B → 直连 DeepSeek ────────────────────────────────────

do_full_rollback() {
    log "L2: CC → DeepSeek 直连"

    python3 -c "
import json
with open('$CONFIG_FILE') as f: d = json.load(f)
d['env']['ANTHROPIC_BASE_URL'] = '$DIRECT_UPSTREAM'
with open('$CONFIG_FILE', 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
print('ANTHROPIC_BASE_URL → $DIRECT_UPSTREAM')
"
    for rc in /root/.zshrc /root/.bashrc; do
        sed -i "s|export ANTHROPIC_BASE_URL=.*|export ANTHROPIC_BASE_URL=\"$DIRECT_UPSTREAM\"|" "$rc" 2>/dev/null || true
    done

    log "L2 完成 [直连] — 下个session生效"
    warn "恢复: 改 ANTHROPIC_BASE_URL=:8788 + deploy.sh start"
}

# ── L3: 禁用 auto-deploy ─────────────────────────────────────────

do_disable_auto() {
    log "L3: 禁用 auto-deploy hook"
    python3 -c "
import json
with open('$CONFIG_FILE') as f: d = json.load(f)
hooks = d.get('hooks',{}).get('SessionStart',[])
d['hooks']['SessionStart'] = [h for h in hooks if 'permafrost-deploy' not in str(h)]
if not d['hooks']['SessionStart']: del d['hooks']['SessionStart']
with open('$CONFIG_FILE', 'w') as f: json.dump(d, f, indent=2, ensure_ascii=False)
print('auto-deploy disabled')
"
    log "L3 完成"
}

# ── 主入口 ────────────────────────────────────────────────────────

case "${1:-l1}" in
    status)        show_status ;;
    model-off|l0m) do_model_router_off ;;
    tools-off|l0a) do_tools_off ;;
    patches-off|l0b) do_patches_off ;;
    l1)            do_c_to_b ;;
    full|l2)       do_full_rollback ;;
    disable|l3)    do_disable_auto ;;
    nuke|l4)       do_disable_auto; do_full_rollback
                   pkill -f permafrost_proxy.py 2>/dev/null || true
                   pkill -f claude-resilience-proxy.js 2>/dev/null || true
                   log "L4: 完全清零" ;;
    *) echo "Usage: $0 {model-off|tools-off|patches-off|l1|full|disable|nuke|status}"; exit 1 ;;
esac
