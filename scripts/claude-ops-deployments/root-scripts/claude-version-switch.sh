#!/bin/bash
# ============================================================================
# Claude Code 版本快速切换器
# ============================================================================
# 用法:
#   bash /root/claude-version-switch.sh                    # 列出可用版本
#   bash /root/claude-version-switch.sh 2.1.150            # 切换到指定版本
#   bash /root/claude-version-switch.sh install 2.1.150    # 安装新版本(不切换)
#   bash /root/claude-version-switch.sh latest             # 切换到最新版
#   bash /root/claude-version-switch.sh rollback           # 回退到上一个版本
#
# 原理: 维护 /root/.local/bin/claude → versions/N.N.NNN 软链接
#       版本安装到 /root/.local/share/claude/versions/
#       切换秒级完成, 无需重启进程
# ============================================================================
set -e

VERSIONS_DIR="/root/.local/share/claude/versions"
CLAUDE_BIN="/root/.local/bin/claude"
SWITCH_LOG="$HOME/.claude/version-switch.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[switch]${NC} $1"; echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SWITCH_LOG"; }
warn() { echo -e "${YELLOW}[switch]${NC} $1"; }

get_current_version() {
    if [ -L "$CLAUDE_BIN" ]; then
        local target=$(readlink "$CLAUDE_BIN")
        basename "$target"
    elif [ -f "$CLAUDE_BIN" ]; then
        "$CLAUDE_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1
    else
        echo "unknown"
    fi
}

get_installed_versions() {
    ls "$VERSIONS_DIR" 2>/dev/null | sort -V
}

# ── 安装版本 ─────────────────────────────────────────────────────

install_version() {
    local ver="$1"
    local dest="$VERSIONS_DIR/$ver"

    if [ -f "$dest" ]; then
        log "v$ver 已安装"
        return 0
    fi

    log "安装 v$ver (npm install @anthropic-ai/claude-code@$ver)..."
    local tmpdir=$(mktemp -d)

    if ! npm install "@anthropic-ai/claude-code@$ver" --prefix "$tmpdir" --no-save 2>&1 | tail -1; then
        warn "npm install 失败, 尝试从 registry 获取..."
        rm -rf "$tmpdir"
        return 1
    fi

    # 找到 glibc 二进制 (优先, PRoot 环境需要)
    # npm 可能安装 musl 和 glibc 两个变体, musl 在 PRoot 中不可用
    local src=""
    for candidate in \
        "$tmpdir/node_modules/@anthropic-ai/claude-code-linux-arm64/claude" \
        "$tmpdir/node_modules/@anthropic-ai/claude-code-linux-x64/claude" \
        "$tmpdir/node_modules/@anthropic-ai/claude-code-linux-arm64-musl/claude" \
        "$tmpdir/node_modules/@anthropic-ai/claude-code-linux-x64-musl/claude"; do
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then
            # 验证是 glibc 链接的 (非 musl)
            if file "$candidate" | grep -q "ld-linux"; then
                src="$candidate"
                break
            fi
        fi
    done

    if [ -z "$src" ]; then
        warn "未找到可执行文件"
        find "$tmpdir" -name "claude" -type f 2>/dev/null
        rm -rf "$tmpdir"
        return 1
    fi

    cp "$src" "$dest"
    chmod +x "$dest"
    rm -rf "$tmpdir"
    log "v$ver 已安装到 $dest ($(du -h "$dest" | cut -f1))"
}

# ── 切换版本 ─────────────────────────────────────────────────────

switch_to() {
    local ver="$1"
    local target="$VERSIONS_DIR/$ver"

    # 安装
    if [ ! -f "$target" ]; then
        install_version "$ver" || return 1
    fi

    local current=$(get_current_version)
    if [ "$current" = "$ver" ]; then
        log "当前已是 v$ver"
        return 0
    fi

    # 记录上一个版本 (用于 rollback)
    echo "$current" > "$VERSIONS_DIR/.previous"

    # 切换软链接
    ln -sf "$target" "$CLAUDE_BIN"
    log "切换: v$current → v$ver"

    # 验证
    sleep 0.5
    local new_ver=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
    if [ "$new_ver" = "$ver" ]; then
        log "验证通过: $("$CLAUDE_BIN" --version 2>/dev/null)"
    else
        warn "验证异常: 期望 v$ver, 实际 v$new_ver"
    fi
}

# ── 回滚 ─────────────────────────────────────────────────────────

do_rollback() {
    local prev=$(cat "$VERSIONS_DIR/.previous" 2>/dev/null || echo "")
    if [ -n "$prev" ] && [ -f "$VERSIONS_DIR/$prev" ]; then
        switch_to "$prev"
    else
        warn "无上一个版本记录, 无法回滚"
        list_versions
    fi
}

# ── 列出 ─────────────────────────────────────────────────────────

list_versions() {
    local current=$(get_current_version)
    echo ""
    echo "可用版本:"
    for v in $(get_installed_versions); do
        if [ "$v" = "$current" ]; then
            echo -e "  ${GREEN}▶ $v${NC} ← 当前"
        else
            echo "    $v"
        fi
    done
    echo ""
    echo "  切换:  bash $0 <版本号>"
    echo "  安装:  bash $0 install <版本号>"
    echo "  回滚:  bash $0 rollback"
    echo "  最新:  bash $0 latest"
    echo ""
}

# ── 主入口 ────────────────────────────────────────────────────────

case "${1:-list}" in
    list|"")
        list_versions
        ;;
    install)
        [ -z "$2" ] && { warn "用法: $0 install <版本号>"; exit 1; }
        install_version "$2"
        ;;
    latest)
        # 切换到已安装的最新版本
        local latest=$(get_installed_versions | tail -1)
        [ -z "$latest" ] && { warn "无已安装版本"; exit 1; }
        switch_to "$latest"
        ;;
    rollback)
        do_rollback
        ;;
    *)
        switch_to "$1"
        ;;
esac
