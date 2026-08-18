#!/bin/bash
# ============================================================================
# CC 版本升级检测 Hook — 自动分析并调整工具归一化策略
# ============================================================================
# 原理:
#   1. SessionStart 时检查 CC 版本是否变化
#   2. 如果版本变了 → 对比升级前后的 dump 数据
#   3. 检测到新工具/锚点变化 → 自动更新 _ANCHOR_TOOLS 排除列表
#   4. 更新 permafrost 补丁 → 下次重启生效
#
# 用法:
#   bash /root/claude-version-hook.sh check    检查版本变化
#   bash /root/claude-version-hook.sh analyze  分析dump差异
#   bash /root/claude-version-hook.sh update   自动更新补丁
# ============================================================================
set -e

STATE_FILE="$HOME/.claude/version-state.json"
DUMP_DIR="$HOME/.permafrost/dumps"
ALIGN_SRC="$HOME/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_align.py"
ALIGN_REPO="$HOME/workspace/agent-knowledge-base/patches/permafrost_align.py"
CC_VERSION=$(claude --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[hook]${NC} $1"; }
warn() { echo -e "${YELLOW}[hook]${NC} $1"; }

# ── 检测版本变化 ─────────────────────────────────────────────────

check_version() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "{\"version\":\"$CC_VERSION\",\"last_check\":\"$(date -Iseconds)\"}" > "$STATE_FILE"
        log "首次运行，记录版本: $CC_VERSION"
        return 0
    fi

    local prev=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('version',''))")
    if [ "$prev" != "$CC_VERSION" ]; then
        warn "版本变化: $prev → $CC_VERSION"
        # 更新状态
        python3 -c "
import json
d=json.load(open('$STATE_FILE'))
d['prev_version']=d.get('version','')
d['version']='$CC_VERSION'
d['upgrade_time']='$(date -Iseconds)'
json.dump(d, open('$STATE_FILE','w'), indent=2)
"
        return 1  # 返回值表示版本变了
    fi
    log "版本未变: $CC_VERSION"
    return 0
}

# ── 分析 dump 差异 ─────────────────────────────────────────────────

analyze_dump_changes() {
    log "分析升级前后的 dump 数据..."

    python3 << 'PYEOF'
import json, os, sys
from collections import Counter

DUMP = os.environ.get('DUMP_DIR', os.path.expanduser('~/.permafrost/dumps'))

# 收集最近 50 个请求的工具集
recent_tools = Counter()
older_tools = Counter()
all_files = sorted([f for f in os.listdir(DUMP) if f.endswith('.json')])

if len(all_files) < 10:
    print("dump 数据不足")
    sys.exit(0)

# 后半段 = 升级后, 前半段 = 升级前
mid = len(all_files) // 2
for fn in all_files[mid:]:
    try:
        with open(f'{DUMP}/{fn}') as f:
            body = json.load(f)
        tools = tuple(sorted(t['name'] for t in body.get('tools', [])))
        recent_tools[tools] += 1
    except: pass

for fn in all_files[:mid]:
    try:
        with open(f'{DUMP}/{fn}') as f:
            body = json.load(f)
        tools = tuple(sorted(t['name'] for t in body.get('tools', [])))
        older_tools[tools] += 1
    except: pass

# 找出新增的工具
old_all = set()
for tools, _ in older_tools.most_common():
    old_all.update(tools)
new_all = set()
for tools, _ in recent_tools.most_common():
    new_all.update(tools)

added = new_all - old_all
removed = old_all - new_all

# 找出最常见的工具集（升级前后）
print(f"升级前最常见: {older_tools.most_common(2)}")
print(f"升级后最常见: {recent_tools.most_common(2)}")
print(f"新增工具: {added if added else '无'}")
print(f"移除工具: {removed if removed else '无'}")

# 输出建议的排除列表
if added:
    print(f"EXCLUDE:{','.join(sorted(added))}")
PYEOF
}

# ── 自动更新补丁 ───────────────────────────────────────────────────

update_patch() {
    log "更新 permafrost 补丁..."

    # 运行分析
    local analysis=$(analyze_dump_changes)
    echo "$analysis"

    # 提取新增工具
    local exclude=$(echo "$analysis" | grep "^EXCLUDE:" | cut -d: -f2)
    if [ -z "$exclude" ]; then
        log "无新增工具，无需更新"
        return 0
    fi

    warn "检测到新工具: $exclude"
    warn "自动触发补丁强制恢复 + permafrost 重启..."
    # 更新补丁文件 + 清缓存 + 触发重启
    bash /root/claude-permafrost-deploy.sh force 2>/dev/null && \
        log "补丁已恢复，permafrost 已重启" || \
        warn "自动重启失败，请手动: bash /root/claude-permafrost-deploy.sh force"
}

# ── 主入口 ────────────────────────────────────────────────────────

case "${1:-check}" in
    check)
        check_version
        ;;
    full)
        if ! check_version; then
            log "版本已变，开始分析..."
            sleep 2  # 等 dump 积累
            update_patch
        fi
        ;;
    analyze)
        analyze_dump_changes
        ;;
    *)
        echo "Usage: $0 {check|full|analyze}"
        ;;
esac
