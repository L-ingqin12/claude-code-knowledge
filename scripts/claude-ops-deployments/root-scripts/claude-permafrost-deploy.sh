#!/bin/bash
# ============================================================================
# Permafrost 部署脚本 — 管理 permafrost + proxy 双层代理链路
# ============================================================================
# 架构:
#   方案 B: CC → permafrost (:8788) → DeepSeek 直连        (当前)
#   方案 C: CC → permafrost (:8788) → proxy (:8787) → DeepSeek (目标)
#
# 用法:
#   bash /root/claude-permafrost-deploy.sh start      部署方案 C
#   bash /root/claude-permafrost-deploy.sh rollback   逃生 C→B
#   bash /root/claude-permafrost-deploy.sh stop       停止所有
#   bash /root/claude-permafrost-deploy.sh status     查看链路
# ============================================================================
set -e

CONFIG_FILE="$HOME/.claude/settings.local.json"
PROXY_SCRIPT="/root/claude-resilience-proxy.js"
PROXY_PID_FILE="/root/.claude/proxy.pid"
PROXY_LOG="/root/.claude/proxy.log"
PROXY_PORT=8787

PERMAFROST_PORT=8788
PERMAFROST_HOME="${PERMAFROST_HOME:-$HOME/.permafrost}"
PERMAFROST_SCRIPT="$HOME/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_proxy.py"

PROXY_UPSTREAM="http://[IP已脱敏]:${PROXY_PORT}"
DIRECT_UPSTREAM="https://api.deepseek.com/anthropic"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[deploy]${NC} $1"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $1"; }
err()  { echo -e "${RED}[deploy]${NC} $1"; }

# ── 工具函数 ──────────────────────────────────────────────────────

proxy_running() {
    [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat $PROXY_PID_FILE)" 2>/dev/null
}

permafrost_running() {
    curl -s "http://[IP已脱敏]:${PERMAFROST_PORT}/permafrost/health" >/dev/null 2>&1
}

get_permafrost_upstream() {
    curl -s "http://[IP已脱敏]:${PERMAFROST_PORT}/permafrost/health" 2>/dev/null | \
      python3 -c "import sys,json; print(json.load(sys.stdin).get('upstream','unknown'))" 2>/dev/null || echo "down"
}

# ── start_proxy ────────────────────────────────────────────────────

start_proxy() {
    if proxy_running; then
        log "proxy (:${PROXY_PORT}) 已在运行 (PID $(cat $PROXY_PID_FILE))"
        return 0
    fi
    log "启动 proxy (:${PROXY_PORT} → DeepSeek)..."
    node "$PROXY_SCRIPT" > "$PROXY_LOG" 2>&1 &
    local PID=$!
    echo "$PID" > "$PROXY_PID_FILE"
    sleep 2
    if kill -0 "$PID" 2>/dev/null; then
        log "proxy 已启动 (PID $PID)"
    else
        err "proxy 启动失败, 查看 $PROXY_LOG"
        return 1
    fi
}

# ── start_permafrost ───────────────────────────────────────────────

start_permafrost() {
    local upstream="${1:-$DIRECT_UPSTREAM}"
    local label="$2"

    # 停旧实例
    if permafrost_running; then
        local old_upstream=$(get_permafrost_upstream)
        if [ "$old_upstream" = "$upstream" ]; then
            log "permafrost (:${PERMAFROST_PORT}) 已在运行, upstream=$upstream [$label]"
            return 0
        fi
        log "切换 permafrost upstream: $old_upstream → $upstream"
        pkill -f permafrost_proxy.py 2>/dev/null || true
        # 等待端口释放
        for _ in $(seq 1 5); do
            curl -s --connect-timeout 1 "http://[IP已脱敏]:${PERMAFROST_PORT}/permafrost/health" >/dev/null 2>&1 || break
            sleep 1
        done
    else
        log "启动 permafrost (:${PERMAFROST_PORT} → $upstream) [$label]"
    fi

    mkdir -p "$PERMAFROST_HOME" "$PERMAFROST_HOME/dumps"
    PERMAFROST_PORT=$PERMAFROST_PORT \
    PERMAFROST_MODE=aggressive \
    PERMAFROST_UPSTREAM="$upstream" \
    PERMAFROST_HOME="$PERMAFROST_HOME" \
    PERMAFROST_DUMP_DIR="$PERMAFROST_HOME/dumps" \
    PERMAFROST_NORMALIZE_TOOLS=1 \
    PERMAFROST_MODEL_ROUTING=1 \
    nohup python3 "$PERMAFROST_SCRIPT" >>"$PERMAFROST_HOME/proxy.log" 2>&1 &

    sleep 2
    if permafrost_running; then
        local new_upstream=$(get_permafrost_upstream)
        log "permafrost 就绪, upstream=$new_upstream [$label]"
    else
        err "permafrost 启动失败!"
        return 1
    fi
}

# ── 端到端验证 ────────────────────────────────────────────────────

verify_chain() {
    log "端到端验证..."
    local result
    result=$(curl -s --connect-timeout 10 -X POST "http://[IP已脱敏]:${PERMAFROST_PORT}/v1/messages" \
      -H "Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "anthropic-version: 2023-06-01" \
      -d '{"model":"deepseek-v4-pro","max_tokens":5,"messages":[{"role":"user","content":"Say hi"}]}' \
      2>&1)

    if echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('model') else 1)" 2>/dev/null; then
        log "E2E 验证通过"
        return 0
    else
        err "E2E 验证失败!"
        err "响应: ${result:0:300}"
        return 1
    fi
}

# ── show_status ────────────────────────────────────────────────────

show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  Permafrost + Proxy 双层代理状态"
    echo "═══════════════════════════════════════════════════"

    # Layer 1: permafrost
    echo -n "  permafrost (:${PERMAFROST_PORT}): "
    if permafrost_running; then
        local up=$(get_permafrost_upstream)
        case "$up" in
            "$PROXY_UPSTREAM")   echo -e "${GREEN}→ proxy :${PROXY_PORT}${NC}  [方案 C]" ;;
            "$DIRECT_UPSTREAM")  echo -e "${YELLOW}→ DeepSeek 直连${NC}     [方案 B]" ;;
            *)                   echo -e "${YELLOW}→ $up${NC}" ;;
        esac
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    # Layer 2: proxy
    echo -n "  proxy    (:${PROXY_PORT}): "
    if proxy_running; then
        echo -e "${GREEN}→ DeepSeek${NC}"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    # Summary
    local pf_up=$(get_permafrost_upstream)
    if [ "$pf_up" = "$PROXY_UPSTREAM" ] && proxy_running; then
        echo ""
        echo -e "  当前方案: ${GREEN}C${NC} (permafrost → proxy → DeepSeek)"
    elif [ "$pf_up" = "$DIRECT_UPSTREAM" ]; then
        echo ""
        echo -e "  当前方案: ${YELLOW}B${NC} (permafrost → DeepSeek 直连)"
    else
        echo ""
        echo -e "  当前方案: ${RED}异常${NC} — 请检查"
    fi

    echo ""
    echo "  操作:"
    echo "    bash $0 force      强制重启方案 C"
    echo "    bash $0 start      部署方案 C(运行中保护)"
    echo "    bash $0 rollback   逃生 C→B"
    echo "    bash $0 restart    零中断重启proxy(备用端口)"
    echo "    bash $0 status     查看状态"
    echo ""
}

# ── 主命令 ─────────────────────────────────────────────────────────

case "${1:-status}" in
    force|start)
        
# 自检: 修正可能被意外改回的 ANTHROPIC_BASE_URL
python3 -c "
import json
cf=\"$HOME/.claude/settings.local.json\"
d=json.load(open(cf))
url=d.get('env',{}).get('ANTHROPIC_BASE_URL','')
if '8788' not in url and 'permafrost' not in url:
    d['env']['ANTHROPIC_BASE_URL']='http://[IP已脱敏]:8788'
    json.dump(d,open(cf,'w'),indent=2)
" 2>/dev/null || true


# 补丁强制恢复: 每次启动前清缓存 + 从repo恢复补丁
PATCH_SRC="$HOME/workspace/claude-code-knowledge/patches/permafrost_align.py"
PATCH_DST="$HOME/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_align.py"
PATCH_CACHE="$HOME/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/__pycache__"
if [ -f "$PATCH_SRC" ]; then
    rm -rf "$PATCH_CACHE"
    cp "$PATCH_SRC" "$PATCH_DST"
    python3 -c "
import sys; sys.path.insert(0, '$HOME/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy')
import permafrost_align as pa
ok = hasattr(pa, '_ON_DEMAND_KEYWORDS') and hasattr(pa, 'stabilize_current_date')
print('[deploy] 补丁状态:', 'OK' if ok else 'MISSING')
" 2>/dev/null || true
fi


    # 运行中保护: permafrost+proxy 已在运行且链路通 → 只更新代码不重启
    if curl -s --connect-timeout 2 "http://[IP已脱敏]:${PERMAFROST_PORT}/permafrost/health" >/dev/null 2>&1 &&        curl -sI --connect-timeout 2 "http://[IP已脱敏]:${PROXY_PORT}/" >/dev/null 2>&1; then
        if [ "${1:-start}" = "force" ]; then
        log "强制重启模式"
    else
        log "permafrost + proxy 已运行，跳过重启 (保护中)"
        # 仍然确保补丁是最新的
        PATCH_SRC="$HOME/workspace/claude-code-knowledge/patches/permafrost_align.py"
        PATCH_DST="$HOME/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_align.py"
        [ -f "$PATCH_SRC" ] && cp "$PATCH_SRC" "$PATCH_DST" 2>/dev/null || true
        show_status
        exit 0
    fi
    fi

log "=== 部署方案 C: permafrost → proxy → DeepSeek ==="
        start_proxy
        start_permafrost "$PROXY_UPSTREAM" "方案 C"
        verify_chain || {
            err "验证失败, 自动回滚到方案 B..."
            start_permafrost "$DIRECT_UPSTREAM" "方案 B (自动回滚)"
            exit 1
        }
        log "方案 C 部署完成"
        show_status
        ;;

    rollback)
        log "=== 逃生: 方案 C → 方案 B ==="
        start_permafrost "$DIRECT_UPSTREAM" "方案 B (逃生)"
        verify_chain || {
            err "逃生后验证失败! 请手动检查"
            exit 1
        }
        log "已回退到方案 B"
        show_status
        ;;

    restart)
        log "=== 零中断重启 proxy ==="
        # 找干净备用端口
        local backup=""
        for p in 8789 8790 8791 8792; do
            if ! curl -s --connect-timeout 1 "http://[IP已脱敏]:$p/" >/dev/null 2>&1; then
                backup=$p; break
            fi
        done
        [ -z "$backup" ] && { err "无可用备用端口"; exit 1; }
        log "备用端口: $backup"

        # 1. 新 proxy 在备用端口启动
        node "$PROXY_SCRIPT" > "$PROXY_LOG.$backup" 2>&1 &
        local NEW_PID=$!
        sleep 2
        if ! kill -0 $NEW_PID 2>/dev/null; then
            err "新 proxy 启动失败"; exit 1
        fi
        log "新 proxy 就绪 (PID $NEW_PID → :$backup)"

        # 2. 切换 permafrost upstream → 新端口
        local old_up=$(get_permafrost_upstream)
        start_permafrost "http://[IP已脱敏]:$backup" "restart-临时"
        verify_chain || { err "切换验证失败, 回退"; start_permafrost "$old_up" "回退"; kill $NEW_PID 2>/dev/null; exit 1; }

        # 3. kill 旧 proxy
        pkill -f "claude-resilience-proxy.js" 2>/dev/null || true
        sleep 1
        rm -f "$PROXY_PID_FILE"
        log "旧 proxy 已停止"

        # 4. 新 proxy 在主端口重新启动
        start_proxy

        # 5. 切回主端口
        start_permafrost "$PROXY_UPSTREAM" "方案 C"
        verify_chain || { err "切回验证失败!"; exit 1; }

        # 6. 清理备用
        kill $NEW_PID 2>/dev/null || true
        log "零中断重启完成 ✅"
        show_status
        ;;

    stop)
        log "停止 permafrost..."
        local pf_pid=$(lsof -ti:${PERMAFROST_PORT} 2>/dev/null || true)
        [ -n "$pf_pid" ] && kill $pf_pid 2>/dev/null
        log "停止 proxy..."
        if [ -f "$PROXY_PID_FILE" ]; then
            kill "$(cat $PROXY_PID_FILE)" 2>/dev/null || true
            rm -f "$PROXY_PID_FILE"
        fi
        pkill -f "claude-resilience-proxy.js" 2>/dev/null || true
        log "已停止所有组件"
        ;;

    status)
        show_status
        ;;

    repair-hook)
        log "恢复 auto-deploy hook..."
        python3 -c "
import json
with open('$CONFIG_FILE') as f:
    d = json.load(f)

hooks = d.setdefault('hooks', {})
session_hooks = hooks.setdefault('SessionStart', [])

# 检查是否已存在
exists = False
for h in session_hooks:
    for cmd in h.get('hooks', []):
        if 'permafrost-deploy' in cmd.get('command', ''):
            exists = True
if exists:
    print('auto-deploy hook 已存在, 无需修复')
else:
    session_hooks.insert(0, {
        'matcher': '',
        'hooks': [{
            'type': 'command',
            'command': 'bash /root/claude-permafrost-deploy.sh start 2>/dev/null || true'
        }]
    })
    with open('$CONFIG_FILE', 'w') as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print('OK: auto-deploy hook 已恢复')
"
        ;;

    *)
        echo "Usage: $0 {start|rollback|stop|status|repair-hook}"
        exit 1
        ;;
esac
