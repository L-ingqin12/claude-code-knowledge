#!/usr/bin/env bash
#
# run_demo.sh — Skill Migration Demo Orchestrator
#
# Runs all 5 phases in sequence with auto-approve, printing banners
# and timing information between each phase.
#
# Usage:
#   bash run_demo.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ID="demo_$(date +%Y%m%d_%H%M%S)"
START_TS=$(date +%s)

# ── Helper ──────────────────────────────────────────────────────

banner() {
    local phase="$1"
    local desc="$2"
    local cols=58
    echo ""
    echo "  ╔$(printf '═%.0s' $(seq 1 $cols))╗"
    printf "  ║  %-52s  ║\n" "Phase $phase: $desc"
    echo "  ╚$(printf '═%.0s' $(seq 1 $cols))╝"
    echo ""
}

summary() {
    local phase="$1"
    local rc="$2"
    if [ "$rc" -eq 0 ]; then
        echo "  ✓ Phase $phase completed successfully"
    else
        echo "  ✗ Phase $phase FAILED with exit code $rc"
    fi
}

# ── Run all phases ─────────────────────────────────────────────

declare -a RESULTS

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║        Agent-Driven Skill Migration Demo                 ║"
echo "  ║        Session: ${SESSION_ID}                            ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Phase 1: Discovery ─────────────────────────────────────────
banner "1" "Discovery"
cd "$SCRIPT_DIR"
if python3 phase1_discover.py; then
    summary 1 0
    RESULTS+=("PASS: Phase 1")
else
    summary 1 $?
    RESULTS+=("FAIL: Phase 1")
    exit 1
fi

# ── Phase 2: Classification ────────────────────────────────────
banner "2" "Classification"
cd "$SCRIPT_DIR"
if python3 phase2_classify.py; then
    summary 2 0
    RESULTS+=("PASS: Phase 2")
else
    summary 2 $?
    RESULTS+=("FAIL: Phase 2")
    exit 1
fi

# ── Phase 3: Review (auto mode) ────────────────────────────────
banner "3" "Review"
cd "$SCRIPT_DIR"
if python3 phase3_review.py; then
    summary 3 0
    RESULTS+=("PASS: Phase 3")
else
    summary 3 $?
    RESULTS+=("FAIL: Phase 3")
    exit 1
fi

# ── Phase 4: Migration ─────────────────────────────────────────
banner "4" "Migration"
cd "$SCRIPT_DIR"
if python3 phase4_migrate.py --auto-approve; then
    summary 4 0
    RESULTS+=("PASS: Phase 4")
else
    summary 4 $?
    RESULTS+=("FAIL: Phase 4")
    exit 1
fi

# ── Phase 5: Verification ──────────────────────────────────────
banner "5" "Verification"
cd "$SCRIPT_DIR"
if python3 phase5_verify.py; then
    summary 5 0
    RESULTS+=("PASS: Phase 5")
else
    summary 5 $?
    RESULTS+=("FAIL: Phase 5")
    exit 1
fi

# ── Final summary ──────────────────────────────────────────────
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║           Migration Demo Complete 🎯                     ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
for r in "${RESULTS[@]}"; do
    echo "  • $r"
done
echo ""
echo "  Total time: ${ELAPSED}s"
echo ""

# ── Locate the audit trail ─────────────────────────────────────
# Find the most recent audit session dir
AUDIT_DIR=$(ls -1dt /tmp/skill-migration-* 2>/dev/null | head -1)
if [ -n "$AUDIT_DIR" ]; then
    echo "  Migration complete."
    echo "  Audit trail at: $AUDIT_DIR"
    echo ""
    echo "  Artifacts:"
    for f in "$AUDIT_DIR"/*; do
        echo "    • $f"
    done
else
    echo "  Migration complete (audit trail not found)."
fi
echo ""
