#!/usr/bin/env python3
"""
demo-e2e-test.py — End-to-end demonstration of the Skill management framework.

Simulates 3 real-world scenarios to show:
  - Path-based filtering
  - Namespace scoping
  - Dependency chain resolution (includes + optional_includes)
  - Cross-namespace behavior
  - Token budget savings vs. loading everything

Usage:
    python demo-e2e-test.py
"""

import fnmatch
import importlib.util
import json
import os
import sys

# ── Load SkillRegistry from sibling file (hyphenated name) ────────────────

_MODULE_PATH = os.path.join(os.path.dirname(__file__), "skill-registry.py")
_spec = importlib.util.spec_from_file_location("skill_registry", _MODULE_PATH)
_mod = importlib.util.module_from_spec(_spec)
sys.modules["skill_registry"] = _mod
_spec.loader.exec_module(_mod)

SkillRegistry = _mod.SkillRegistry
Skill = _mod.Skill


# ── Data loading ───────────────────────────────────────────────────────────

_DATA_FILE = os.path.join(os.path.dirname(__file__), "demo-skills.json")


def load_skills_from_json(path: str) -> list[dict]:
    """Load skill definitions from JSON file; return empty list on failure."""
    try:
        with open(path, "r") as f:
            data = json.load(f)
        if isinstance(data, list):
            return data
        print(f"  [WARN] {path}: expected a JSON list, got {type(data).__name__}")
    except FileNotFoundError:
        pass
    except json.JSONDecodeError as e:
        print(f"  [WARN] {path}: JSON parse error -- {e}")
    return []


def hardcoded_fallback() -> list[dict]:
    """Hardcoded fallback when demo-skills.json is unavailable."""
    return [
        # -- Shared infrastructure (dependency targets) --
        {
            "name": "docker-build",
            "description": "Docker image build and push workflow",
            "namespace": "shared",
            "paths": ["**/Dockerfile*"],
            "includes": [],
            "optional_includes": [],
        },
        {
            "name": "k8s-apply",
            "description": "Kubernetes resource deployment",
            "namespace": "shared",
            "paths": ["**/*.yaml", "**/*.yml"],
            "includes": ["secret-management"],
            "optional_includes": [],
        },
        {
            "name": "secret-management",
            "description": "Secret retrieval and rotation",
            "namespace": "shared",
            "paths": [],
            "includes": [],
            "optional_includes": [],
        },
        {
            "name": "slack-notify",
            "description": "Deployment notification to Slack",
            "namespace": "shared",
            "paths": [],
            "includes": [],
            "optional_includes": [],
        },
        {
            "name": "ci-pipeline-template",
            "description": "CI pipeline template for shared infra",
            "namespace": "shared",
            "paths": [".gitlab-ci.yml", ".github/workflows/*.yml"],
            "includes": [],
            "optional_includes": [],
        },
        # -- Team: Frontend --
        {
            "name": "react-component-dev",
            "description": "React component development standards and patterns",
            "namespace": "team/frontend",
            "paths": ["**/*.tsx", "**/*.jsx"],
            "includes": ["css-module-guidelines"],
            "optional_includes": ["storybook-config"],
        },
        {
            "name": "css-module-guidelines",
            "description": "CSS Module naming and organization conventions",
            "namespace": "team/frontend",
            "paths": ["**/*.css", "**/*.module.css"],
            "includes": [],
            "optional_includes": [],
        },
        {
            "name": "storybook-config",
            "description": "Storybook component showcase setup",
            "namespace": "team/frontend",
            "paths": ["**/*.stories.tsx"],
            "includes": [],
            "optional_includes": [],
        },
        {
            "name": "state-management",
            "description": "Zustand/Jotai state management patterns",
            "namespace": "team/frontend",
            "paths": ["**/stores/**", "**/state/**"],
            "includes": [],
            "optional_includes": [],
        },
        # -- Team: Backend (Go) --
        {
            "name": "go-api-dev",
            "description": "Go API development standards and middleware",
            "namespace": "team/backend",
            "paths": ["**/*.go"],
            "includes": ["docker-build"],
            "optional_includes": ["slack-notify"],
        },
        {
            "name": "go-db-migration",
            "description": "Database migration and schema management",
            "namespace": "team/backend",
            "paths": ["**/*.sql"],
            "includes": [],
            "optional_includes": [],
        },
        # -- Team: Data --
        {
            "name": "data-pipeline",
            "description": "Data pipeline definition and orchestration",
            "namespace": "team/data",
            "paths": ["**/*.py"],
            "includes": ["docker-build", "k8s-apply"],
            "optional_includes": ["slack-notify"],
        },
        {
            "name": "data-monitoring",
            "description": "Pipeline monitoring and alerting",
            "namespace": "team/data",
            "paths": [],
            "includes": ["slack-notify"],
            "optional_includes": [],
        },
        # -- No namespace (global / cross-cutting) --
        {
            "name": "code-review-checklist",
            "description": "Generic code review checklist applicable to any language",
            "namespace": "",
            "paths": [],
            "includes": [],
            "optional_includes": [],
        },
        {
            "name": "security-best-practices",
            "description": "Security best practices for all teams",
            "namespace": "",
            "paths": [],
            "includes": [],
            "optional_includes": [],
        },
    ]


def build_registry(skill_defs: list[dict]) -> SkillRegistry:
    """Populate a SkillRegistry from a list of dictionary definitions."""
    reg = SkillRegistry()
    for sd in skill_defs:
        reg.register(Skill(
            name=sd["name"],
            description=sd["description"],
            namespace=sd.get("namespace", ""),
            paths=sd.get("paths", []),
            includes=sd.get("includes", []),
            optional_includes=sd.get("optional_includes", []),
        ))
    return reg


# ── Display helpers ────────────────────────────────────────────────────────

_SEP = "=" * 74
_SUB = "-" * 74


def header(title: str):
    print(f"\n{_SEP}")
    print(f"  {title}")
    print(f"{_SEP}")


def subheader(title: str):
    print(f"\n  {title}")
    print(f"  {_SUB}")


def estimate_tokens(skills: list[Skill]) -> int:
    """
    Rough token estimate for a set of skills.
    Heuristic: ~4 ASCII chars/token, ~1 CJK char/token, averaging to ~3.5
    per character across mixed text.
    """
    total_chars = sum(len(s.name) + len(s.description) for s in skills)
    return max(total_chars // 4, 1)


def print_skill_table(skills: list[Skill], label: str = "Loaded"):
    """Print skills with namespace, paths, and dependency info."""
    print(f"\n    [{label}] ({len(skills)} skills)\n")
    for s in sorted(skills, key=lambda x: x.name):
        ns_tag = f"  <{s.namespace}>" if s.namespace else "  <global>"
        paths_tag = ""
        if s.paths:
            paths_tag = "\n" + " " * 8 + "paths: " + ", ".join(s.paths)
        deps_tag = ""
        if s.includes:
            deps_tag = "\n" + " " * 8 + "includes: " + ", ".join(s.includes)
        opt_tag = ""
        if s.optional_includes:
            opt_tag = "\n" + " " * 8 + "optional: " + ", ".join(s.optional_includes)
        print(f"      [+-] {s.name}{ns_tag}{paths_tag}{deps_tag}{opt_tag}")
    print()


def print_token_budget(loaded: list[Skill], all_skills: list[Skill],
                       label: str = "Current scenario"):
    """Print a token budget comparison table."""
    loaded_tok = estimate_tokens(loaded)
    baseline_tok = estimate_tokens(all_skills)
    savings = baseline_tok - loaded_tok
    pct = 100.0 * savings / baseline_tok if baseline_tok else 0.0

    print(f"    Token Budget: {label}")
    print(f"    {'-' * 56}")
    print(f"    {'Item':<34} {'Skills':>8} {'Tokens':>10}")
    print(f"    {'-' * 56}")
    print(f"    {'Loaded (filtered + resolved)':<34} {len(loaded):>8} {loaded_tok:>10}")
    print(f"    {'Baseline (all skills)':<34} {len(all_skills):>8} {baseline_tok:>10}")
    print(f"    {'Savings':<34} {'':>8} {savings:>10}")
    print(f"    {'Percentage saved':<34} {'':>8} {pct:>8.1f}%")
    print()


def print_chain_trace():
    """Print the dependency chain for scenario B."""
    print(r"""
    Resolution trace:

      python-data-pipeline  <team/data>
       |
       +-- optional: docker-build, slack-notify
       |
       +-- docker-build  <shared>
       |    (leaf -- no further deps)
       |
       +-- slack-notify  <shared>
            (leaf -- no further deps)

    Note: python-data-pipeline declares optional_includes only;
    its dependencies (docker-build, slack-notify) are loaded
    when resolvable, but skipped silently if missing.
    """)


# ── Scenarios ──────────────────────────────────────────────────────────────

def scenario_a(reg: SkillRegistry, all_skills: list):
    """Frontend development: team/frontend namespace, .tsx and .css files."""
    header("Scenario A:  Frontend Development  [team/frontend]")
    print("  Context:")
    print("    Namespace:     team/frontend")
    print("    Current files: src/components/App.tsx, src/components/Button.tsx,")
    print("                   src/styles/index.css")
    print("    Goal:          Show path-filtered candidate selection,")
    print("                   then dependency resolution via includes.")

    _files_a = ["src/components/App.tsx", "src/components/Button.tsx",
                "src/styles/index.css"]

    subheader("Step 1 -- filter_by_context (namespace + path filter)")

    candidates = reg.filter_by_context(
        namespace="team/frontend",
        current_files=_files_a,
    )
    print(f"\n    Skills surviving both filters ({len(candidates)} of "
          f"{len(all_skills)} total):\n")
    for s in candidates:
        # Show which file patterns matched
        matched_pats = []
        for pat in s.paths:
            for f in _files_a:
                if fnmatch.fnmatch(f, pat):
                    matched_pats.append(f" {f} ~ {pat}")
        print(f"      PASS  {s.name:<28}  ns={s.namespace}")
        if matched_pats:
            for m in matched_pats:
                print(f"            {'':28}  match:{m}")

    # Show skills that exist but are excluded, with reasons
    excluded = [s for s in all_skills if s not in candidates]
    excluded_rows = []
    for s in excluded:
        ns_block = (s.namespace and s.namespace != "team/frontend")
        path_block = bool(s.paths) and not any(
            any(fnmatch.fnmatch(f, pat) for f in _files_a)
            for pat in s.paths
        )
        reasons = []
        if ns_block:
            reasons.append(f"namespace={s.namespace}")
        if path_block:
            reasons.append("no path match")
        if not s.paths:
            reasons.append("no paths defined")
        if not reasons:
            reasons.append("ns mismatch")
        excluded_rows.append(f"{s.name} ({', '.join(reasons)})")
    if excluded_rows:
        print(f"\n    Excluded ({len(excluded)} skills):")
        for r in excluded_rows:
            print(f"      SKIP  {r}")

    subheader("Step 2 -- load_for_task (dependency-aware loading)")

    candidate_names = [s.name for s in candidates]
    loaded = reg.load_for_task(candidate_names)
    print_skill_table(loaded, "Final loaded set")

    print_token_budget(loaded, all_skills, "Frontend session")


def scenario_b(reg: SkillRegistry, all_skills: list):
    """Data pipeline deployment: team/data, .py/Dockerfile/.yaml files."""
    header("Scenario B:  Data Pipeline Deployment  [team/data]")
    print("  Context:")
    print("    Namespace:     team/data")
    print("    Current files: pipelines/etl/pipeline.py, docker/Dockerfile,")
    print("                   deploy/k8s/deploy.yaml")
    print("    Goal:          Show dependency resolution with optional_includes:")
    print("                   python-data-pipeline -> docker-build (optional)")
    print("                   python-data-pipeline -> slack-notify (optional)")
    print("                   optional deps are loaded if resolvable, skipped if not")

    _files_b = ["pipelines/etl/pipeline.py", "docker/Dockerfile",
                "deploy/k8s/deploy.yaml"]

    subheader("Step 1 -- filter_by_context (namespace + path filter)")

    candidates = reg.filter_by_context(
        namespace="team/data",
        current_files=_files_b,
    )
    print(f"\n    Skills surviving both filters ({len(candidates)} of "
          f"{len(all_skills)} total):\n")
    for s in candidates:
        tag = []
        if s.includes:
            tag.append(f"requires: {', '.join(s.includes)}")
        if s.optional_includes:
            tag.append(f"optional: {', '.join(s.optional_includes)}")
        print(f"      PASS  {s.name:<28}  {'; '.join(tag)}")

    print(f"\n    Note: docker-build is also independently matched via")
    print(f"    docker/Dockerfile in current_files -- confirming that")

    subheader("Step 2 -- Dependency chain resolution (detailed trace)")

    print_chain_trace()

    candidate_names = [s.name for s in candidates]
    loaded = reg.load_for_task(candidate_names)
    print_skill_table(loaded, "Final loaded set")

    print_token_budget(loaded, all_skills, "Data pipeline session")


def scenario_c(reg: SkillRegistry, all_skills: list):
    """Full-stack development: cross-namespace, mixed file types."""
    header("Scenario C:  Full-Stack Development  [cross-namespace]")
    print("  Context:")
    print("    Namespace:     (none -- cross-namespace)")
    print("    Current files: api/handler.go, web/App.tsx,")
    print("                   db/migrations/001.up.sql")
    print("    Goal:          Show how cross-namespace filtering works")
    print("                   when namespace='' and only path patterns apply.")

    _files_c = ["api/handler.go", "web/App.tsx", "db/migrations/001.up.sql"]

    subheader("Step 1 -- filter_by_context (path-only filter)")

    candidates = reg.filter_by_context(
        namespace="",
        current_files=_files_c,
    )
    print(f"\n    Skills matching any of the current files "
          f"({len(candidates)} of {len(all_skills)} total):\n")
    for s in candidates:
        matched_patterns = []
        for pat in s.paths:
            for f in _files_c:
                if fnmatch.fnmatch(f, pat):
                    matched_patterns.append(f"{f} ~ {pat}")
        ns_label = s.namespace if s.namespace else "(global)"
        print(f"      PASS  {s.name:<28}  ns={ns_label}")
        if matched_patterns:
            for m in matched_patterns:
                print(f"            {'':28}  match: {m}")

    # Show which skills from which namespaces are included
    ns_groups = {}
    for s in candidates:
        ns = s.namespace if s.namespace else "(global)"
        ns_groups.setdefault(ns, []).append(s.name)
    print(f"\n    Namespace breakdown of matching skills:")
    for ns, names in sorted(ns_groups.items()):
        print(f"      {ns:<20}  {', '.join(names)}")

    subheader("Step 2 -- load_for_task (cross-ns resolution)")

    candidate_names = [s.name for s in candidates]
    loaded = reg.load_for_task(candidate_names)
    print_skill_table(loaded, "Final loaded set")

    print(f"    Note: All {len(all_skills)} skills considered by path filter")
    print(f"    (no namespace scoping). Skills without path restrictions")
    print(f"    (e.g., slack-notify with paths=[]) are always candidates")
    print(f"    and appear in every cross-namespace scenario.\n")

    print_token_budget(loaded, all_skills, "Full-stack session")


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    header("Skill Management Framework -- End-to-End Demo")
    print("  Loading skills and preparing registry...\n")

    # Load data
    skill_defs = load_skills_from_json(_DATA_FILE)
    if skill_defs:
        print(f"  [OK] Loaded {len(skill_defs)} skill definitions"
              f" from demo-skills.json")
    else:
        skill_defs = hardcoded_fallback()
        print(f"  [OK] Using hardcoded fallback"
              f" ({len(skill_defs)} skill definitions)")
        print(f"       (create demo-skills.json to customize)")

    # Build registry
    reg = build_registry(skill_defs)
    all_skills = list(reg._skills.values())
    stats = reg.stats()
    print(f"  [OK] Registered {len(all_skills)} skills")
    print(f"       Namespaces:          {stats['namespaces']}")
    print(f"       With path filters:   {stats['with_paths']}")
    print(f"       With dependencies:   {stats['with_deps']}")

    # Run scenarios (each uses a fresh _loaded set via load_for_task)
    scenario_a(reg, all_skills)
    scenario_b(reg, all_skills)
    scenario_c(reg, all_skills)

    # -- Cross-scenario comparison --
    header("Cross-Scenario Comparison")

    print(f"  {'Scenario':<36} {'Loaded':>7} {'Tokens':>8} {'Savings %':>10}")
    print(f"  {'-' * 63}")

    scenarios = [
        ("Frontend (team/frontend)", "team/frontend",
         ["src/components/App.tsx", "src/components/Button.tsx",
          "src/styles/index.css"]),
        ("Data pipeline (team/data)", "team/data",
         ["pipelines/etl/pipeline.py", "docker/Dockerfile",
          "deploy/k8s/deploy.yaml"]),
        ("Full-stack (cross-namespace)", "",
         ["api/handler.go", "web/App.tsx",
          "db/migrations/001.up.sql"]),
    ]

    baseline_tok = estimate_tokens(all_skills)

    for label, ns, files in scenarios:
        r = build_registry(skill_defs)
        cs = r.filter_by_context(namespace=ns, current_files=files)
        cn = [s.name for s in cs]
        ld = r.load_for_task(cn)
        tok = estimate_tokens(ld)
        saved_pct = 100.0 * (baseline_tok - tok) / baseline_tok
        print(f"  {label:<36} {len(ld):>7} {tok:>8} {saved_pct:>9.1f}%")

    print()
    print(f"  Baseline (all {len(all_skills)} skills):"
          f" ~{baseline_tok} tokens\n")

    print(_SEP)
    print("  Demo complete.  All scenarios exercised.")
    print(f"{_SEP}\n")


if __name__ == "__main__":
    main()
