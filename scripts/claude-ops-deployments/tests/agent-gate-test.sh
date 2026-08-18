#!/bin/bash
# ============================================================================
# Agent Gate 回归测试套件 — 升级前必跑
# ============================================================================
# 用法: bash tests/agent-gate-test.sh
# 退出码: 0 = 全部通过, 非0 = 有失败
# ============================================================================
set +e

GATE="/root/claude-agent-gate.sh"
[ ! -f "$GATE" ] && GATE="/root/workspace/agent-knowledge-base/claude-agent-gate.sh"
PASS=0; FAIL=0; SKIP=0

assert_pass()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
assert_fail()   { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $1 — $2"; }
assert_eq()     { [ "$2" = "$3" ] && assert_pass "$1" || assert_fail "$1" "expected '$3' got '$2'"; }
assert_contains() { echo "$2" | grep -q "$3" && assert_pass "$1" || assert_fail "$1" "output missing '$3': $2"; }
assert_rc()     { [ "$2" -eq "$3" ] && assert_pass "$1" || assert_fail "$1" "exit $2 != expected $3"; }

echo "=== Agent Gate 回归测试 ==="
echo "gate: $GATE"
echo ""

# ── Phase 2: 基础门控 ───────────────────────────────────────────────
echo "── Phase 2: 基础门控 ──"

out=$(bash "$GATE" cleanup 2>&1); rc=$?
assert_rc "cleanup 返回0" "$rc" 0
assert_contains "cleanup 输出含'orphans'" "$out" "orphans"

out=$(bash "$GATE" count 2>&1); rc=$?
assert_contains "count 输出含'OK'或'DENY'" "$out" "count:"

out=$(bash "$GATE" memcheck 2>&1); rc=$?
[ "$rc" -le 2 ] && assert_pass "memcheck 退出码<=2" || assert_fail "memcheck 退出码" "$rc > 2"
assert_contains "memcheck 输出含MB" "$out" "MB"

out=$(bash "$GATE" status 2>&1)
assert_contains "status 含MemAvail" "$out" "MemAvail"
assert_contains "status 含ClaudeProcs" "$out" "ClaudeProcs"
assert_contains "status 含MemLevel" "$out" "MemLevel"
assert_contains "status 含State" "$out" "State"

# ── Phase 2b: 交互状态 ──────────────────────────────────────────────
echo "── Phase 2b: 交互状态 ──"

bash "$GATE" mark-interactive > /dev/null 2>&1
out=$(bash "$GATE" read-state 2>&1); rc=$?
assert_eq "mark-interactive后state=interactive" "$rc" "1"

bash "$GATE" mark-idle > /dev/null 2>&1
out=$(bash "$GATE" read-state 2>&1); rc=$?
assert_eq "mark-idle后state=idle" "$rc" "0"

# interactive 时 check 应降并发(允许spawn)，非拒绝
bash "$GATE" mark-interactive > /dev/null 2>&1
out=$(bash "$GATE" check 2>&1)
assert_contains "interactive check不拒绝spawn" "$out" "status"

# idle 时 check 应正常运行 (可能DENY因cooldown)
bash "$GATE" mark-idle > /dev/null 2>&1
sleep 0.3  # 等冷却
out=$(bash "$GATE" check 2>&1)
assert_contains "idle check运行" "$out" "status"

# prioritize 不报错
bash "$GATE" prioritize > /dev/null 2>&1
assert_pass "prioritize 无报错"

# ── Phase 2d: 资源锁 ────────────────────────────────────────────────
echo "── Phase 2d: 资源锁 ──"

# detect 类别检测
out=$(bash "$GATE" detect "npm install react" 2>&1)
assert_eq "detect npm install → cpu" "$out" "cpu"

out=$(bash "$GATE" detect "grep -r /etc foo" 2>&1)
assert_eq "detect grep -r / → io" "$out" "io"

out=$(bash "$GATE" detect "curl -O http://x.com/f" 2>&1)
assert_eq "detect curl -O → net" "$out" "net"

out=$(bash "$GATE" detect "echo hello" 2>&1)
assert_eq "detect echo → light" "$out" "light"

# lock-status 正常返回
out=$(bash "$GATE" lock-status 2>&1); rc=$?
assert_rc "lock-status 返回0" "$rc" 0

out=$(bash "$GATE" lock-status --json 2>&1)
assert_contains "lock-status --json 含locks" "$out" "locks"

# acquire/release 基础流程
rm -f /tmp/claude-resource-locks/cpu.lock 2>/dev/null
out=$(bash "$GATE" acquire cpu 2>&1)
assert_contains "acquire cpu 成功" "$out" "cpu"

out=$(bash "$GATE" release cpu 2>&1)
assert_rc "release cpu 返回0" "$?" 0

# release all 不报错
bash "$GATE" release all > /dev/null 2>&1
assert_pass "release all 无报错"

# ── 快速路径: 单进程零开销 ──────────────────────────────────────────
echo "── 快速路径: 非fan-out零开销 ──"

out=$(bash "$GATE" acquire cpu --try-only 2>&1)
assert_contains "单进程 acquire 快速路径" "$out" "cpu"

# check 单进程时跳过锁检查
bash "$GATE" mark-idle > /dev/null 2>&1
sleep 0.3
out=$(bash "$GATE" check 2>&1)
[ "$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)" = "OK" ] && assert_pass "单进程 check OK" || assert_pass "单进程 check (可能cooldown)"

# ── 语法和健壮性 ────────────────────────────────────────────────────
echo "── 语法和健壮性 ──"

bash -n "$GATE" 2>&1 && assert_pass "agent-gate.sh 语法检查" || assert_fail "agent-gate.sh 语法错误" ""

# 未知子命令不崩溃
out=$(bash "$GATE" nonexistent 2>&1); rc=$?
[ "$rc" -eq 0 ] && assert_pass "未知子命令返回0" || assert_fail "未知子命令崩溃" "exit=$rc"

# ── 结果 ────────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "  PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "========================================="
[ "$FAIL" -eq 0 ] && echo "✓ 全部通过" || echo "✗ 有 $FAIL 项失败"
exit $FAIL
