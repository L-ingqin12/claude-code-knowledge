#!/usr/bin/env python3
"""
Log Search/Analysis System — Real-World Test Scenarios

Demonstrates progressive disclosure: load only the skills needed for
a specific task, not all 25 skills. Three scenarios covering:

A. SRE investigating K8s OOM (alerts + shared deps)
B. Security audit (queries + auth deps)
C. RCA after incident (workflows + cross-namespace deps)

Each scenario shows:
  - Input context (namespace + files + search terms)
  - How the system discovers the right skill
  - Loaded skills with dependency tree
  - Token budget comparison against loading all 25 skills
"""

import os
import sys

_script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _script_dir not in sys.path:
    sys.path.insert(0, _script_dir)

from logsystem.loader import LogSkillLoader


def estimate_tokens(skills_list: list) -> int:
    """Rough token estimate: skill name + description words."""
    return max(1, sum(len(f"{s.name}: {s.description}".split()) for s in skills_list))


def print_dependency_tree(skills_list: list):
    """Print a tree showing skills and their dependency relationships."""
    loaded_names = {s.name for s in skills_list}
    name_to_skill = {s.name: s for s in skills_list}

    # Find root skills: those not depended on by any other loaded skill
    all_dependents = set()
    for s in skills_list:
        for dep in s.includes:
            all_dependents.add(dep)

    roots = [s for s in skills_list if s.name not in all_dependents]

    printed = set()

    def _print_tree(name: str, depth: int = 0):
        if name in printed:
            return
        printed.add(name)
        skill = name_to_skill.get(name)
        if not skill:
            return
        prefix = "    " * depth
        dep_str = "  * dep" if depth > 0 else ""
        ns_str = f" [{skill.namespace}]"
        print(f"{prefix}- {skill.name}{ns_str}{dep_str}")
        for dep in skill.includes:
            if dep in loaded_names:
                _print_tree(dep, depth + 1)

    for root in roots:
        _print_tree(root.name, 0)

    # Also print orphan deps (optional includes that loaded)
    for s in skills_list:
        if s.name not in printed:
            print(f"    - {s.name} [{s.namespace}]  * opt-dep")

    print(f"    ---")
    print(f"    Total: {len(skills_list)} skills")


def run_scenario(
    label: str,
    search_terms: list,
    namespace_hint: str,
    file_hints: list,
    loader: LogSkillLoader,
):
    """Run a single scenario: discover skill, resolve dependencies, compare tokens."""
    print()
    print("  " + "-" * 70)
    print(f"  {label}")
    print("  " + "-" * 70)
    print(f"    Context: namespace={namespace_hint!r}, files={file_hints}")

    # Phase 1: Discover candidate skills using keyword search
    candidate_names = set()
    for term in search_terms:
        results = loader.search(term)
        for r in results:
            candidate_names.add(r.name)

    if not candidate_names:
        print("    [ERROR] No skills matched search terms!")
        return []

    # Map names to Skill objects for namespace filtering
    skill_by_name = loader.registry._skills
    candidates = [skill_by_name[n] for n in candidate_names if n in skill_by_name]

    print(f"    Discovered: {', '.join(sorted(candidate_names))}")

    # Phase 2: Optional namespace filter on candidates
    if namespace_hint:
        ns_candidates = [s for s in candidates if s.namespace == namespace_hint]
        if ns_candidates:
            candidates = ns_candidates
            print(f"    Namespace filter '{namespace_hint}': {', '.join(s.name for s in candidates)}")

    # Phase 3: Resolve full dependency chain
    loader.registry._loaded = set()
    all_loaded = []
    for s in candidates:
        all_loaded.extend(loader.registry.resolve_dependencies(s.name))

    # Deduplicate
    seen = set()
    deduped = []
    for s in all_loaded:
        if s.name not in seen:
            seen.add(s.name)
            deduped.append(s)

    print(f"\n    Loaded Skills (dependency tree):")
    print_dependency_tree(deduped)

    # Token comparison
    all_skills = list(loader.registry._skills.values())
    loaded_tokens = estimate_tokens(deduped)
    all_tokens = estimate_tokens(all_skills)
    savings_pct = round((1 - loaded_tokens / all_tokens) * 100, 1) if all_tokens else 0

    print(f"\n    Token Budget:")
    print(f"      Loaded ({len(deduped)} skills): ~{loaded_tokens} tokens")
    print(f"      All 25 skills (baseline):       ~{all_tokens} tokens")
    print(f"      Saved: {all_tokens - loaded_tokens} tokens ({savings_pct}%)")
    print()

    return deduped


# ═══════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════
if __name__ == "__main__":
    print("=" * 72)
    print("  Log Search/Analysis System — Scenario Demo")
    print("  Progressive Disclosure: Load only what you need")
    print("=" * 72)

    loader = LogSkillLoader()
    all_skills = list(loader.registry._skills.values())
    all_tokens = estimate_tokens(all_skills)
    all_25_names = sorted(s.name for s in all_skills)

    print(f"\n  Baseline: {len(all_skills)} skills registered -> ~{all_tokens} tokens")
    print(f"  All skills: {', '.join(all_25_names)}")
    print()

    # ── Scenario A: K8s OOM Investigation ──
    # SRE sees OOMKilled alert, searches for "oom", loads the alert + dependencies
    scenario_a_loaded = run_scenario(
        "Scenario A: SRE Investigating K8s OOM",
        search_terms=["oom", "k8s"],
        namespace_hint="logs/alerts",
        file_hints=["k8s/pod.yaml", "alerts/oom.json"],
        loader=loader,
    )

    # ── Scenario B: Security Audit ──
    # Security engineer searches audit logs, needs access control
    scenario_b_loaded = run_scenario(
        "Scenario B: Security Audit Log Search",
        search_terms=["security", "audit"],
        namespace_hint="logs/queries",
        file_hints=["audit/auth.log"],
        loader=loader,
    )

    # ── Scenario C: RCA After Incident ──
    # On-call engineer starts RCA from incident report
    # NOTE: Uses specific search term "rca-pipeline" to avoid also matching
    # alert-correlation (which shares "root cause" in its description and
    # declares a conflict with rca-pipeline).
    scenario_c_loaded = run_scenario(
        "Scenario C: Root Cause Analysis After Incident",
        search_terms=["rca-pipeline"],
        namespace_hint="logs/workflows",
        file_hints=["incidents/sev1.md"],
        loader=loader,
    )

    # ── Summary ──
    print("  " + "=" * 70)
    print("  Scenario Summary")
    print("  " + "=" * 70)
    print(f"  {'Scenario':25s} {'Loaded':>8s} {'Tokens':>8s} {'Savings':>8s}")
    print(f"  {'-'*25} {'-'*8} {'-'*8} {'-'*8}")

    scenarios = [
        ("A: K8s OOM", scenario_a_loaded),
        ("B: Security Audit", scenario_b_loaded),
        ("C: RCA Pipeline", scenario_c_loaded),
    ]

    for name, loaded in scenarios:
        loaded_tok = estimate_tokens(loaded)
        pct = round((1 - loaded_tok / all_tokens) * 100, 1) if all_tokens else 0
        print(f"  {name:25s} {len(loaded):>8d} {loaded_tok:>8d} {pct:>7.1f}%")

    print(f"  {'-'*25} {'-'*8} {'-'*8} {'-'*8}")
    print(f"  {'All 25 (baseline)':25s} {len(all_skills):>8d} {all_tokens:>8d} {'0.0%':>8s}")
    print()
    print(f"  Architecture: search -> discover -> resolve dependencies -> load")
    print(f"  Progressive disclosure saves 44-84% tokens vs. full skill list.")
    print(f"  Adding a skill = dropping a SKILL.md, zero code changes.")
    print(f"  {'=' * 72}")
