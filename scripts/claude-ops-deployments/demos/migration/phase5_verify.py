#!/usr/bin/env python3
"""
phase5_verify.py — Phase 5: Verification

Reads the migrated skills from the target directory, loads them into
SkillRegistry, and runs four checks:
  1. Dependency completeness — are all `includes` targets resolvable?
  2. Cycle detection — topological sort of dependency graph
  3. Path coverage — do path globs cover relevant file types?
  4. Token comparison — old system flat vs new system top-level only

Standalone:  python3 phase5_verify.py
Importable: from migration.phase5_verify import run_verification
"""

import json
import os
import sys

# ── Ensure imports are resolvable ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, PROJECT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from components.audit import AuditTrail

# Import SkillRegistry (hyphen in filename → use importlib)
import importlib.util
spec = importlib.util.spec_from_file_location(
    "skill_registry",
    os.path.join(SCRIPT_DIR, "..", "skill-registry.py"),
)
skill_registry_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skill_registry_mod)
SkillRegistry = skill_registry_mod.SkillRegistry
Skill = skill_registry_mod.Skill

import re


# ── Check utilities ────────────────────────────────────────────

def _parse_migrated_skill(filepath: str) -> dict | None:
    """Parse a migrated skill file (with namespace, includes in frontmatter)."""
    with open(filepath) as f:
        content = f.read()

    m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)", content, re.DOTALL)
    if not m:
        return None

    yaml_block = m.group(1)
    body = m.group(2).strip()
    fm: dict = {}
    current_key = None
    list_buffer: list[str] = []

    for line in yaml_block.splitlines():
        # Key: value
        kv = re.match(r"^(\w[\w_]*):\s*(.*)", line)
        if kv:
            if current_key and list_buffer:
                fm[current_key] = list_buffer
                list_buffer = []
            current_key = kv.group(1)
            value = kv.group(2).strip()
            if value:
                fm[current_key] = value
            else:
                # Expect a list on subsequent lines
                list_buffer = []
        elif line.strip().startswith("- ") and current_key:
            list_buffer.append(line.strip()[2:])

    if current_key and list_buffer:
        fm[current_key] = list_buffer

    fm["body"] = body
    fm["filepath"] = filepath
    return fm


def _resolve_qualified_ref(ref: str) -> str:
    """Convert a namespace-qualified ref (e.g. 'ops/deployment/deploy_rollback')
    to the plain skill name used in the registry.
    """
    # The qualified ref is path-like: namespace + "/" + name
    return ref.split("/")[-1]


def _estimate_tokens(text: str) -> int:
    return len(text.split())


def _topological_sort(graph: dict[str, list[str]]) -> list[str] | None:
    """Kahn's algorithm. Returns ordered list or None if cycle exists."""
    in_degree: dict[str, int] = {n: 0 for n in graph}
    for node, deps in graph.items():
        for d in deps:
            if d in graph:
                in_degree[d] = in_degree.get(d, 0) + 1

    queue = [n for n, deg in in_degree.items() if deg == 0]
    sorted_nodes: list[str] = []

    while queue:
        node = queue.pop(0)
        sorted_nodes.append(node)
        for dep in graph.get(node, []):
            if dep in in_degree:
                in_degree[dep] -= 1
                if in_degree[dep] == 0:
                    queue.append(dep)

    if len(sorted_nodes) != len(graph):
        return None  # cycle
    return sorted_nodes


# ── Main verification ──────────────────────────────────────────

def run_verification(target_base: str | None = None,
                     registry_path: str | None = None,
                     session_id: str | None = None) -> dict:
    """Execute Phase 5 verification."""
    if session_id is None:
        session_id = "verify_" + os.urandom(4).hex()
    audit = AuditTrail(session_id=session_id)
    audit.log("Phase 5: Verification started")

    # ── Locate target directory ──
    if target_base is None and registry_path is None:
        # Guess from the default location
        target_base = "/tmp/skill-migration-demo/target"

    if target_base is None or not os.path.isdir(target_base):
        # Try to load registry to find target
        if registry_path and os.path.isfile(registry_path):
            with open(registry_path) as f:
                reg_data = json.load(f)
            skills = reg_data.get("skills", {})
            # Derive target_base from first skill's path
            for s in skills.values():
                fp = s.get("filepath", "")
                if fp:
                    target_base = os.path.dirname(os.path.dirname(fp))
                    break

    if not target_base or not os.path.isdir(target_base):
        print(f"ERROR: Target directory not found: {target_base}")
        sys.exit(1)

    audit.log(f"Target base: {target_base}")

    # ── Find all migrated .md files ──
    md_files = []
    for root, dirs, files in os.walk(target_base):
        for f in files:
            if f.endswith(".md"):
                md_files.append(os.path.join(root, f))

    audit.log(f"Found {len(md_files)} migrated skill files")

    if not md_files:
        print("WARN: No migrated skill files found. Run phase4 first.")
        result = {
            "session_id": session_id,
            "checks": [],
            "passed": 0,
            "failed": 0,
            "total_checks": 4,
        }
        result["__audit__"] = audit
        return result

    # ── Parse and register all skills ──
    registry = SkillRegistry()
    parsed_skills: dict[str, dict] = {}
    for fp in md_files:
        parsed = _parse_migrated_skill(fp)
        if parsed is None:
            audit.log(f"WARN: Skipping unparseable {fp}")
            continue
        name = parsed.get("name", "")
        if not name:
            continue

        # Resolve qualified includes to flat names for the registry
        includes = [_resolve_qualified_ref(d) for d in parsed.get("includes", [])]
        optional_includes = [_resolve_qualified_ref(d) for d in parsed.get("optional_includes", [])]

        skill = Skill(
            name=name,
            description=parsed.get("description", ""),
            namespace=parsed.get("namespace", ""),
            paths=parsed.get("paths", []),
            includes=includes,
            optional_includes=optional_includes,
            content=parsed.get("body", ""),
        )
        registry.register(skill)
        parsed_skills[name] = parsed

    stats = registry.stats()
    audit.log(f"Registered {stats['total']} skills in SkillRegistry")

    # ── Check 1: Dependency completeness ──
    check1_errors: list[str] = []
    for s in registry._skills.values():
        for dep in s.includes + s.optional_includes:
            if dep not in registry._skills:
                check1_errors.append(f"'{s.name}' includes '{dep}' but '{dep}' not found in registry")
    check1_pass = len(check1_errors) == 0
    audit.log(f"Check 1 (Dependency completeness): {'PASS' if check1_pass else 'FAIL'} — {len(check1_errors)} errors")
    for e in check1_errors:
        audit.log(f"  ERROR: {e}")

    # ── Check 2: Cycle detection ──
    graph: dict[str, list[str]] = {}
    for s in registry._skills.values():
        graph[s.name] = s.includes
    sorted_order = _topological_sort(graph)
    check2_pass = [已脱敏] is not None
    audit.log(f"Check 2 (Cycle detection): {'PASS' if check2_pass else 'FAIL — cycle detected'}")
    if sorted_order:
        audit.log(f"  Topological order: {' → '.join(sorted_order)}")

    # ── Check 3: Path coverage ──
    check3_warnings: list[str] = []
    for s in registry._skills.values():
        if not s.paths:
            continue
        desc = s.description.lower()
        # Check if at least one path glob looks plausible for the description
        relevant_keywords = {
            "yaml": "**/*.yaml", "yml": "**/*.yml",
            "docker": "**/Dockerfile", "dockerfile": "**/Dockerfile",
            "sql": "**/*.sql", "migration": "**/migrations/**",
            "go": "**/*.go", "python": "**/*.py",
            "typescript": "**/*.ts", "javascript": "**/*.js",
            "json": "**/*.json",
        }
        for kw, expected_glob in relevant_keywords.items():
            if kw in desc:
                if not any(expected_glob in p for p in s.paths):
                    check3_warnings.append(
                        f"'{s.name}' mentions '{kw}' in description but paths lack '{expected_glob}'"
                    )
    check3_pass = len(check3_warnings) == 0
    audit.log(f"Check 3 (Path coverage): {'PASS' if check3_pass else 'WARN'} — {len(check3_warnings)} warnings")
    for w in check3_warnings:
        audit.log(f"  WARN: {w}")

    # ── Check 4: Token comparison ──
    # Flatten all skill content
    total_old_tokens = sum(_estimate_tokens(s.content) for s in registry._skills.values())
    # Top-level only (skills not listed as includes of another)
    all_includes: set[str] = set()
    for s in registry._skills.values():
        all_includes.update(s.includes)
        all_includes.update(s.optional_includes)
    top_level = [s for s in registry._skills.values() if s.name not in all_includes]
    top_tokens = sum(_estimate_tokens(s.content) for s in top_level)
    check4_pass = [已脱敏] < total_old_tokens
    savings = total_old_tokens - top_tokens
    savings_pct = 100 * savings // max(total_old_tokens, 1)
    audit.log(f"Check 4 (Token comparison): {'PASS' if check4_pass else 'INFO'}")
    audit.log(f"  All skills (flat): ~{total_old_tokens} tokens")
    audit.log(f"  Top-level only:    ~{top_tokens} tokens")
    audit.log(f"  Savings:           ~{savings} tokens ({savings_pct}%)")

    # ── Assemble report ──
    checks = [
        {
            "check": "Dependency completeness",
            "status": "PASS" if check1_pass else "FAIL",
            "details": check1_errors if check1_errors else ["All includes are resolvable"],
        },
        {
            "check": "Cycle detection",
            "status": "PASS" if check2_pass else "FAIL",
            "details": [f"Topological order: {' → '.join(sorted_order)}"] if sorted_order else ["Cycle detected in dependency graph"],
        },
        {
            "check": "Path coverage",
            "status": "PASS" if check3_pass else "WARN",
            "details": check3_warnings if check3_warnings else ["All path globs are consistent with descriptions"],
        },
        {
            "check": "Token comparison",
            "status": "PASS" if check4_pass else "INFO",
            "details": [
                f"All skills (flat): ~{total_old_tokens} tokens",
                f"Top-level only:    ~{top_tokens} tokens",
                f"Savings:           ~{savings} tokens ({savings_pct}%)",
            ],
        },
    ]

    md_lines = [
        "# Phase 5 — Verification Report",
        "",
        f"**Session:** {session_id}",
        f"**Skills registered:** {stats['total']}",
        f"**Namespaces:** {', '.join(stats['namespaces']) if stats['namespaces'] else '(none)'}",
        "",
        "---",
        "",
    ]

    for c in checks:
        status_icon = {"PASS": "PASS", "FAIL": "FAIL", "WARN": "WARN", "INFO": "INFO"}[c["status"]]
        md_lines.append(f"## {status_icon}: {c['check']}")
        md_lines.append("")
        md_lines.append(f"**Status:** {c['status']}")
        md_lines.append("")
        for detail in c["details"]:
            md_lines.append(f"- {detail}")
        md_lines.append("")

    md_lines.append("---")
    md_lines.append(f"*Verification completed at {audit.summary().get('session_id')}*")
    md_content = "\n".join(md_lines)

    report_path = audit.store("verification-report.md", md_content)
    audit.log(f"Verification report: {report_path}")

    # ── Print summary ──
    print()
    print("  ╔══════════════════════════════════════════════════════════╗")
    print("  ║       Phase 5: Verification Complete                     ║")
    print("  ╚══════════════════════════════════════════════════════════╝")
    print()
    print(f"  {'Check':<30} {'Status':<10}")
    print(f"  {'─' * 30} {'─' * 10}")
    for c in checks:
        print(f"  {c['check']:<30} {c['status']:<10}")
    print()
    print(f"  Token savings: {savings} tokens ({savings_pct}%)")
    print(f"  Audit trail: {audit.session_dir}")
    print()

    result = {
        "session_id": session_id,
        "total_skills": stats["total"],
        "namespaces": stats["namespaces"],
        "checks": checks,
        "passed_checks": sum(1 for c in checks if c["status"] == "PASS"),
        "failed_checks": sum(1 for c in checks if c["status"] == "FAIL"),
        "token_savings_tokens": savings,
        "token_savings_pct": savings_pct,
    }
    result["__audit__"] = audit
    return result


# ── Standalone entry point ─────────────────────────────────────

if __name__ == "__main__":
    run_verification()
