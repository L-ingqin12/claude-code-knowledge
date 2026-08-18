#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# Log Search/Analysis System — Skill Management Demo Runner
# ─────────────────────────────────────────────────────────
# Phase 1: Skill registry stats (loader.py standalone)
# Phase 2: Scenario demonstrations (scenarios.py)
# Phase 3: Summary banner
# ─────────────────────────────────────────────────────────

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Log Search/Analysis System — Skill Management Demo       ║"
echo "║   Target State: Progressive Loading + Namespace Isolation   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Phase 1: Registry Stats ──────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 1: Skill Registry Population & Stats"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
python3 "$SCRIPT_DIR/loader.py"
echo ""
echo ""

# ── Phase 2: Scenario Demos ──────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase 2: Real-World Test Scenarios"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
python3 "$SCRIPT_DIR/scenarios.py"
echo ""
echo ""

# ── Phase 3: Summary ─────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Demo Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Files created:"
echo "    $(find "$SCRIPT_DIR/skills" -name 'SKILL.md' | wc -l) SKILL.md files (5 namespaces × skill dirs)"
echo "    $(wc -l < "$SCRIPT_DIR/registry.json") lines  — registry.json (index of all skills)"
echo "    loader.py           — LogSkillLoader (scans, registers, resolves)"
echo "    scenarios.py        — 3 real-world test scenarios"
echo "    run_demo.sh         — This runner"
echo ""
echo "  Key architecture properties:"
echo "    - Plugin-style: add a skill = drop a SKILL.md"
echo "    - No code changes needed for new skills"
echo "    - Namespace isolation for large skill catalogs"
echo "    - Dependency chain loading via resolve_dependencies()"
echo "    - Path-based context matching for file-scoped loading"
echo "    - Optional dependency support (graceful degradation)"
echo "    - Conflict declarations (mutually exclusive skills)"
echo ""
echo "  Progressive disclosure saves ~60-80% tokens vs full list."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
