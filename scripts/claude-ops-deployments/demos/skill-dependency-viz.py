#!/usr/bin/env python3
"""
skill-dependency-viz.py — Skill dependency tree visualizer + token cost analyzer

Loads a skill registry from demo-skills.json and produces:

  1. ASCII dependency tree (box-drawing characters)
  2. Token cost comparison table (All Listed vs Top-Level Only vs search_skills)
  3. System prompt "before vs after" comparison
  4. Projection to 100/500/1000 skills at scale

Usage:
    python skill-dependency-viz.py
"""

import json
import os
import sys
from typing import Optional

# ── Import SkillRegistry from sibling file (hyphen in filename → use importlib) ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import importlib.util
spec = importlib.util.spec_from_file_location(
    "skill_registry",
    os.path.join(SCRIPT_DIR, "skill-registry.py"),
)
skill_registry_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skill_registry_mod)
SkillRegistry = skill_registry_mod.SkillRegistry
Skill = skill_registry_mod.Skill


# ═══════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════

def load_skills(path: str) -> SkillRegistry:
    """Load JSON array of skills into a SkillRegistry."""
    reg = SkillRegistry()
    with open(path) as f:
        items = json.load(f)  # top-level JSON array
    for item in items:
        skill = Skill(
            name=item["name"],
            description=item.get("description", ""),
            namespace=item.get("namespace", ""),
            paths=item.get("paths", []),
            includes=item.get("includes", []),
            optional_includes=item.get("optional_includes", []),
            content=item.get("content", ""),
        )
        reg.register(skill)
    return reg


def estimate_tokens(text: str) -> int:
    """
    Rough token estimation via word count.

    Claude uses ~1.3 BPE tokens per English word on average, but for
    structured skill listings (names, code snippets) the ratio is closer
    to 1.0-1.1.  We use word count as a conservative lower-bound estimate.
    """
    return len(text.split())


def get_top_level_skills(reg: SkillRegistry) -> list[Skill]:
    """Return skills that are *never* listed as a dependency of another skill.

    These are the entry-point skills a user would explicitly invoke.
    Skills used only as dependencies (e.g. docker-build, k8s-apply) are excluded.
    """
    all_dep_names: set[str] = set()
    for s in reg._skills.values():
        all_dep_names.update(s.includes)
        all_dep_names.update(s.optional_includes)
    return [s for s in reg._skills.values() if s.name not in all_dep_names]


def get_all_dependency_names(reg: SkillRegistry, skill_name: str,
                              visited: Optional[set] = None) -> set[str]:
    """Recursively collect all dependency names for a given skill."""
    if visited is None:
        visited = set()
    if skill_name in visited:
        return set()
    visited.add(skill_name)

    skill = reg._skills.get(skill_name)
    if skill is None:
        return set()

    deps: set[str] = set()
    for dep in skill.includes:
        deps.add(dep)
        deps.update(get_all_dependency_names(reg, dep, visited))
    for dep in skill.optional_includes:
        if dep in reg._skills:
            deps.add(dep)
            deps.update(get_all_dependency_names(reg, dep, visited))
    return deps


def format_skill_entry(skill: Skill) -> str:
    """One-line representation of a skill for token counting."""
    ns = f" [{skill.namespace}]" if skill.namespace else ""
    return f"- {skill.name}{ns}: {skill.description}"


def box(title: str, width: int = 60) -> None:
    """Print a boxed section header."""
    print(f"  ╔{'═' * (width - 2)}╗")
    # Centre the title
    pad = width - 2 - len(title) - 2  # 2 spaces padding
    left = pad // 2
    right = pad - left
    print(f"  ║{' ' * left}{title}{' ' * right}║")
    print(f"  ╚{'═' * (width - 2)}╝")
    print()


# ═══════════════════════════════════════════════════════════════
#  1. VISUAL DEPENDENCY TREE
# ═══════════════════════════════════════════════════════════════

def _render_tree(reg: SkillRegistry, skill_name: str, prefix: str = "",
                 is_last: bool = True, visited: Optional[set] = None,
                 is_optional: bool = False) -> list[str]:
    """
    Recursively build a list of lines for the dependency tree,
    using box-drawing characters (├── └── │).

    Parameters
    ----------
    reg        : SkillRegistry to look up skills in
    skill_name : current node to render
    prefix     : indentation string for this node (│   or    )
    is_last    : whether this node is the last child of its parent
    visited    : set of already-visited skill names (cycle detection)
    is_optional: whether this edge is an optional dependency
    """
    if visited is None:
        visited = set()

    lines: list[str] = []

    # ── Connector ──
    connector = "└── " if is_last else "├── "

    # ── Cycle detection ──
    if skill_name in visited:
        lines.append(f"{prefix}{connector}{skill_name}  ┄ circular ┄")
        return lines

    skill = reg._skills.get(skill_name)
    if skill is None:
        lines.append(f"{prefix}{connector}{skill_name}  ✗ not found")
        return lines

    visited_for_children = visited | {skill_name}

    # ── Build node label ──
    ns = f" [{skill.namespace}]" if skill.namespace else ""
    optional_tag = " (optional)" if is_optional else ""
    has_deps = bool(skill.includes) or bool(
        d for d in skill.optional_includes if d in reg._skills
    )
    dep_marker = "  ⚡" if has_deps else ""
    label = f"{skill_name}{ns}{dep_marker}{optional_tag}"
    lines.append(f"{prefix}{connector}{label}")

    # ── Determine the prefix continuation for children ──
    child_prefix = prefix + ("    " if is_last else "│   ")

    # ── Collect children ──
    children: list[tuple[str, bool]] = []
    for dep in skill.includes:
        children.append((dep, False))
    for dep in skill.optional_includes:
        if dep in reg._skills:
            children.append((dep, True))

    for i, (child_name, opt) in enumerate(children):
        is_last_child = i == len(children) - 1
        child_lines = _render_tree(
            reg, child_name,
            prefix=child_prefix,
            is_last=is_last_child,
            visited=visited_for_children.copy(),
            is_optional=opt,
        )
        lines.extend(child_lines)

    return lines


def show_dependency_tree(reg: SkillRegistry) -> None:
    """Print the full dependency tree grouped by namespace."""
    box("Skill Dependency Tree")

    top_level = get_top_level_skills(reg)

    # Sort by namespace then name for clean grouping
    namespaces: dict[str, list[Skill]] = {}
    for s in top_level:
        ns = s.namespace or "(unscoped)"
        namespaces.setdefault(ns, []).append(s)

    total_lines = 0
    for ns_idx, (namespace, skills) in enumerate(sorted(namespaces.items())):
        # Namespace header
        ns_label = f"  {'── ' + namespace + ' Skills ' + '─' * 40}"
        print(ns_label[:58])
        print()

        for s_idx, skill in enumerate(sorted(skills, key=lambda x: x.name)):
            tree_lines = _render_tree(
                reg, skill.name,
                prefix="",
                is_last=True,
                visited=set(),
            )
            for line in tree_lines:
                print(line)
                total_lines += 1

            # Show path-based activation info if present
            if skill.paths:
                paths_str = ", ".join(skill.paths)
                print(f"      (path-activated: {paths_str})")
                total_lines += 1
            print()

    stats = reg.stats()
    print(f"  Summary: {stats['total']} total skills, "
          f"{len(top_level)} top-level, "
          f"{stats['with_deps']} with dependencies")
    print()


# ═══════════════════════════════════════════════════════════════
#  2. TOKEN COST COMPARISON TABLE
# ═══════════════════════════════════════════════════════════════

def show_token_comparison(reg: SkillRegistry) -> None:
    """Show a table comparing token costs of three loading strategies."""
    box("System Prompt Token Cost Comparison")

    # ── Strategy A: All skills listed directly ──
    all_entries = "\n".join(format_skill_entry(s) for s in reg._skills.values())
    all_tokens = estimate_tokens(all_entries)

    # ── Strategy B: Top-level only + dependency cascade ──
    top_skills = get_top_level_skills(reg)
    top_entries = "\n".join(format_skill_entry(s) for s in top_skills)
    top_tokens = estimate_tokens(top_entries)

    # Show the cost of the *resolved* dependency chain for a typical task
    # (pick the two skills with the most deps as a realistic example)
    typical_task_name = max(top_skills, key=lambda s: len(s.includes) + len(s.optional_includes)).name
    resolved = reg.load_for_task([typical_task_name])
    resolved_tokens = estimate_tokens(
        "\n".join(format_skill_entry(s) for s in resolved)
    )

    # ── Strategy C: search_skills tool declaration ──
    SEARCH_TOOL_DECLARATION = 15  # tokens for the tool definition

    # ── Build table ──
    header = (
        f"  {'Strategy':<40} {'Skills':>8} {'Tokens':>8} {'Savings':>10}\n"
        f"  {'─' * 40} {'─' * 8} {'─' * 8} {'─' * 10}"
    )
    print(header)

    def row(label: str, count: int, tokens: int,
            baseline: Optional[int] = None) -> str:
        if baseline is None:
            pct = "   —  "
        else:
            saved = baseline - tokens
            pct_str = f"-{abs(saved)}" if saved > 0 else f"+{abs(saved)}"
            pct = f"{pct_str:>7}"
        return (
            f"  {label:<40} {count:>8} {tokens:>8}"
            f" {pct:>10}"
        )

    print(row("A) All Listed (全部列出)",
              reg.stats()["total"], all_tokens))
    print(row("B) Top-Level Only (顶层只列)",
              len(top_skills), top_tokens, all_tokens))
    print(row(f"   └─ Resolved for '{typical_task_name}'",
              1, resolved_tokens, all_tokens))
    print(row("C) search_skills (检索式发现)",
              1, SEARCH_TOOL_DECLARATION, all_tokens))
    print()

    # ── Interpret ──
    print(f"  Explanation:")
    print(f"  A) All {reg.stats()['total']} skills listed verbatim in system prompt.")
    print(f"     → {all_tokens} tokens, every turn.")
    print(f"  B) Only {len(top_skills)} entry-point skills listed. Dependencies loaded")
    print(f"     on-demand when a task matches (resolve_dependencies).")
    print(f"     → {top_tokens} tokens per turn; average ~20 tokens per resolved dep chain.")
    print(f"  C) Single search_skills tool declaration, ~15 tokens.")
    print(f"     Skills discovered at runtime with no up-front cost.")
    print(f"     → 15 tokens, always.")
    print()


# ═══════════════════════════════════════════════════════════════
#  3. BEFORE vs AFTER: SYSTEM PROMPT Comparison
# ═══════════════════════════════════════════════════════════════

def show_before_after(reg: SkillRegistry) -> None:
    """Show the actual system prompt content before and after optimisation."""
    box("Before vs After — System Prompt Content")

    top_level = get_top_level_skills(reg)
    SEARCH_TOOL_DECLARATION = 15

    # ── BEFORE: all skills, fully listed ──
    print("  ┌─ BEFORE (Naive approach — all skills inline)")
    print("  │")
    before_lines = []
    for s in sorted(reg._skills.values(), key=lambda x: x.name):
        ns = f"[{s.namespace}]" if s.namespace else ""
        before_lines.append(f"  │   - {s.name} {ns}: {s.description}")

    # Show first few and last few to keep output readable
    shown = before_lines
    if len(before_lines) > 14:
        shown = before_lines[:7] + ["  │   ..."] + before_lines[-4:]
    for line in shown:
        print(line)
    before_total = estimate_tokens("\n".join(before_lines))
    print(f"  │")
    print(f"  └─ Token cost: ~{before_total} tokens")
    print()

    # ── AFTER: search_skills tool ──
    print("  ┌─ AFTER (Optimal — search_skills tool declaration)")
    print("  │")
    print("  │   Tool: search_skills")
    print("  │   Description: Search available skills by keyword or category")
    print("  │   Usage: Call with a query string → returns matching skill names")
    print("  │          and descriptions; then load_for_task() resolves their")
    print("  │          dependency chains at invocation time.")
    after_total = SEARCH_TOOL_DECLARATION
    print("  │")
    print(f"  └─ Token cost: ~{after_total} tokens")
    print()

    # ── Side-by-side summary ──
    saved = before_total - after_total
    pct = 100 * saved // before_total
    print(f"  {'':>5} {'Before':^20} {'After':^20} {'Savings':^16}")
    print(f"  {'':>5} {'─' * 20} {'─' * 20} {'─' * 16}")
    print(f"  {'Tokens':>5} {before_total:>20} {after_total:>20} {f'-{saved} ({pct}%)':>16}")
    print(f"  {'Skills':>5} {reg.stats()['total']:>20} {1:>20} {f'-{reg.stats()["total"]-1}':>16}")
    print()

    # ── Concrete example: what a typical turn actually sends ──
    print("  ── Concrete example: user edits a Go file ──")
    print()
    print("  BEFORE (every turn):")
    print(f"    All {reg.stats()['total']} skills + descriptions = ~{before_total} tokens always")
    print()
    print("  AFTER (on-demand):")
    print(f"    System prompt: search_skills (15 tokens)")
    print("    User: 'update the API handler'")
    print("    → search_skills('go api development')")
    print("    → matches go-api-dev, which resolves: go-api-dev + docker-build")
    print("      + code-review-checklist + slack-notify = 4 skills")
    resolved = reg.load_for_task(["go-api-dev"])
    resolved_tok = estimate_tokens("\n".join(format_skill_entry(s) for s in resolved))
    print(f"    → Additional token cost for this turn: ~{resolved_tok}")
    print(f"    → Total this turn: ~{SEARCH_TOOL_DECLARATION + resolved_tok} tokens")
    print(f"    → vs {before_total} tokens without optimisation")
    print()


# ═══════════════════════════════════════════════════════════════
#  4. AT SCALE: Projection to 100 / 500 / 1000 skills
# ═══════════════════════════════════════════════════════════════

def show_at_scale(reg: SkillRegistry) -> None:
    """Project token costs to realistic production-scale registries."""
    box("At Scale — Projected Token Costs")

    # Derive average tokens per skill and per top-level skill from our data
    all_tokens_per = estimate_tokens(
        "\n".join(format_skill_entry(s) for s in reg._skills.values())
    ) / max(reg.stats()["total"], 1)

    top_skills = get_top_level_skills(reg)
    top_tokens_per = (
        estimate_tokens("\n".join(format_skill_entry(s) for s in top_skills))
        / max(len(top_skills), 1)
    )

    # Typical ratio: top-level ≈ 30-60% of total
    top_ratio = len(top_skills) / max(reg.stats()["total"], 1)

    SEARCH_TOOL = 15
    # Max useful system prompt budget for a tool-calling turn
    # (Claude Sonnet context = 200K, but for latency/quality we target ~8K)
    PROMPT_BUDGET = 8_000

    targets = [100, 500, 1000]
    header = (
        f"  {'Total Skills':>14} {'All Listed':>14} {'Top-Only':>14}"
        f" {'search_skills':>14} {'Budget % (TO)':>14} {'Feasible?':>12}"
    )
    sep = f"  {'─' * 14} {'─' * 14} {'─' * 14} {'─' * 14} {'─' * 14} {'─' * 12}"
    print(header)
    print(sep)

    for n in targets:
        all_est = int(n * all_tokens_per)
        top_est = int(n * top_ratio * all_tokens_per)
        search_est = SEARCH_TOOL
        pct = 100 * top_est // PROMPT_BUDGET

        if pct < 5:
            feasible = "✔ Yes"
        elif pct < 25:
            feasible = "⚠ Manageable"
        elif pct < 60:
            feasible = "⚡ Tight"
        else:
            feasible = "✗ No"

        print(
            f"  {n:>14} {all_est:>14} {top_est:>14} {search_est:>14}"
            f" {pct:>13}% {feasible:>12}"
        )

    print()
    print(f"  Assumptions:")
    print(f"    - ~{all_tokens_per:.0f} tokens/skill (derived from {reg.stats()['total']} skills)")
    print(f"    - ~{top_ratio*100:.0f}% skills are top-level (derived: {len(top_skills)}/{reg.stats()['total']})")
    print(f"    - Reasonable system prompt budget: ~{PROMPT_BUDGET} tokens")
    SEARCH_TOOL_FIXED = 15
    print(f"    - search_skills tool declaration: ~{SEARCH_TOOL_FIXED} tokens (fixed, regardless of skill count)")
    print()


# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════

def main():
    json_path = os.path.join(SCRIPT_DIR, "demo-skills.json")
    if not os.path.exists(json_path):
        print(f"ERROR: {json_path} not found", file=sys.stderr)
        sys.exit(1)

    reg = load_skills(json_path)
    stats = reg.stats()
    print()
    print(f"  Loaded {stats['total']} skills from demo-skills.json")
    if stats["namespaces"]:
        print(f"  Namespaces: {', '.join(stats['namespaces'])}")
    print(f"  Skills with dependencies: {stats['with_deps']}")
    print()

    show_dependency_tree(reg)
    show_token_comparison(reg)
    show_before_after(reg)
    show_at_scale(reg)


if __name__ == "__main__":
    main()
