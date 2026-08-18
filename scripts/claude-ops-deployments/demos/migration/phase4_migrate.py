#!/usr/bin/env python3
"""
phase4_migrate.py — Phase 4: Migration

Reads phase-3-decisions.json, applies approvals (auto-approve HIGH,
prompt for MEDIUM/LOW or --auto-approve all), rewrites frontmatter,
updates cross-references, and generates a registry.json.

Standalone:  python3 phase4_migrate.py --auto-approve
Importable: from migration.phase4_migrate import run_migration
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile

# ── Ensure imports are resolvable ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))
sys.path.insert(0, PROJECT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from components.audit import AuditTrail


# ── Mapping: old flat names → new namespace-qualified references ──
# (derived from the classifier's namespace rules — kept in sync)
NAMESPACE_MAP: dict[str, str] = {
    "alert_k8s_oom":        "monitoring/alerts/alert_k8s_oom",
    "deploy_rollback":      "ops/deployment/deploy_rollback",
    "db_migration":         "ops/database/db_migration",
    "error_budget_check":   "observability/slo/error_budget_check",
    "incident_response":    "ops/incident/incident_response",
    "monitor_dashboard":    "observability/monitor_dashboard",
    "secret_rotation":      "security/secret_rotation",
    "slack_notify":         "communication/slack_notify",
    "docker_build":         "ci/cd/docker_build",
    "k8s_apply":            "ops/kubernetes/k8s_apply",
    "git_workflow":         "development/git_workflow",
    "code_review_checklist":"development/code_review_checklist",
}

# Reverse map: namespace-qualified → flat name
FLAT_BY_QUALIFIED = {v: k for k, v in NAMESPACE_MAP.items()}


def _resolve_decision(decision: dict, auto_approve: bool) -> bool:
    """Return True if a decision is approved."""
    confidence = decision.get("confidence", "LOW")
    if confidence == "HIGH":
        return True
    if auto_approve:
        return True
    # Interactive prompt
    prompt = (f"  Approve migration of '{decision['skill_name']}' "
              f"(confidence={confidence}, ns={decision['new_namespace']})? [Y/n]: ")
    try:
        answer = input(prompt).strip().lower()
    except (EOFError, KeyboardInterrupt):
        answer = "n"
    return answer in ("", "y", "yes")


def _make_new_frontmatter(decision: dict, old_frontmatter: tuple[str, str, str]) -> str:
    """Build new YAML frontmatter with namespace, includes, paths."""
    name = decision["skill_name"]
    # The old frontmatter values
    old_name, old_desc, old_body = old_frontmatter

    ns = decision.get("new_namespace", "general/unclassified")
    includes = decision.get("new_includes", [])
    optional_includes = decision.get("new_optional_includes", [])
    paths = decision.get("new_paths", [])

    # Qualify cross-references in the body
    body = _update_cross_references(old_body)

    lines = ["---"]
    lines.append(f"name: {name}")
    lines.append(f"description: {old_desc}")
    lines.append(f"namespace: {ns}")
    if paths:
        lines.append(f"paths:")
        for p in paths:
            lines.append(f"  - {p}")
    if includes:
        lines.append(f"includes:")
        for dep in includes:
            qualified = NAMESPACE_MAP.get(dep, dep)
            lines.append(f"  - {qualified}")
    if optional_includes:
        lines.append(f"optional_includes:")
        for dep in optional_includes:
            qualified = NAMESPACE_MAP.get(dep, dep)
            lines.append(f"  - {qualified}")
    lines.append("---")
    lines.append("")
    lines.append(body)
    return "\n".join(lines)


def _update_cross_references(body: str) -> str:
    """Replace old flat skill names in body with namespace-qualified references."""
    # Sort longest first so e.g. 'code_review_checklist' matches before 'code_review'
    for old_name in sorted(NAMESPACE_MAP, key=len, reverse=True):
        qualified = NAMESPACE_MAP[old_name]
        body = body.replace(old_name, f"`{qualified}`")
    return body


def _build_registry(migrated: list[dict], session_id: str, git_log: list[str]) -> dict:
    """Build a MEMORY.md-style registry.json."""
    registry = {
        "session_id": session_id,
        "total_migrated": len(migrated),
        "skills": {},
        "git_log": git_log,
    }

    for entry in migrated:
        ns = entry["namespace"]
        reg_entry = {
            "name": entry["name"],
            "namespace": ns,
            "description": entry["description"],
            "paths": entry["paths"],
            "includes": entry["includes"],
            "optional_includes": entry["optional_includes"],
            "filepath": entry["target_path"],
            "sha256": entry.get("sha256", ""),
        }
        registry["skills"][entry["name"]] = reg_entry

    return registry


def _count_tokens(text: str) -> int:
    """Rough token estimate (word count)."""
    return len(text.split())


def run_migration(decisions_data: dict | None = None,
                  decisions_path: str | None = None,
                  target_base: str | None = None,
                  auto_approve: bool = False) -> dict:
    """Execute Phase 4 migration."""
    # ── Load input ──
    if decisions_data is None:
        if decisions_path is None:
            pattern = "/tmp/skill-migration-*/phase-3-decisions.json"
            import glob
            files = sorted(glob.glob(pattern))
            if not files:
                print("ERROR: No phase-3-decisions.json found. Run phase3 first.")
                sys.exit(1)
            decisions_path = files[-1]
            print(f"Using latest decisions: {decisions_path}")
        with open(decisions_path) as f:
            decisions_data = json.load(f)

    session_id = decisions_data.get("session_id", "unknown")
    audit = AuditTrail(session_id=session_id)
    audit.log("Phase 4: Migration started")

    decisions: list[dict] = decisions_data.get("decisions", [])
    audit.log(f"Loaded {len(decisions)} decisions for processing")

    # ── Target directory ──
    if target_base is None:
        target_base = os.path.join(tempfile.gettempdir(), "skill-migration-demo", "target")
    os.makedirs(target_base, exist_ok=True)
    audit.log(f"Target directory: {target_base}")

    # ── Process each decision ──
    approved: list[dict] = []
    rejected: list[str] = []
    git_log: list[str] = []
    blocked: list[str] = []

    old_system_dir = os.path.join(SCRIPT_DIR, "demo_old_system")

    for decision in decisions:
        name = decision["skill_name"]
        approved_flag = _resolve_decision(decision, auto_approve)

        if approved_flag:
            approved.append(decision)
            decision["approval_status"] = "approved"
            audit.log(f"APPROVED: {name} → {decision['new_namespace']}")
        else:
            rejected.append(name)
            decision["approval_status"] = "rejected"
            audit.log(f"REJECTED: {name} — skipped")

    # ── Check for blocked skills (rejected dep of an approved skill) ──
    for entry in approved:
        for dep in entry.get("new_includes", []):
            if dep in rejected:
                blocked.append(entry["skill_name"])
                audit.log(f"BLOCKED: {entry['skill_name']} depends on rejected '{dep}'")

    # ── Perform file migrations ──
    old_skills = _load_old_skills(old_system_dir) if os.path.isdir(old_system_dir) else {}
    migrated_entries: list[dict] = []
    old_frontmatter_cache: dict[str, tuple[str, str, str]] = {}

    # Pre-cache old frontmatter
    for fname, data in old_skills.items():
        old_frontmatter_cache[fname] = (data.get("name", ""), data.get("description", ""), data.get("body", ""))

    for entry in approved:
        name = entry["skill_name"]
        if name in blocked:
            audit.log(f"SKIPPING (blocked): {name} — dependency was rejected")
            continue

        ns = entry.get("new_namespace", "general/unclassified")
        # Determine target subdirectory from namespace
        ns_path = ns.replace("general/unclassified", "general").replace("/", os.sep)
        target_dir = os.path.join(target_base, ns_path)
        os.makedirs(target_dir, exist_ok=True)

        # Load old content
        old_fm = old_frontmatter_cache.get(name, ("", "", ""))
        new_content = _make_new_frontmatter(entry, old_fm)

        target_file = os.path.join(target_dir, f"{name}.md")
        with open(target_file, "w") as f:
            f.write(new_content)

        migrated_entries.append({
            "name": name,
            "namespace": ns,
            "description": entry.get("new_namespace", ""),
            "paths": entry.get("new_paths", []),
            "includes": [NAMESPACE_MAP.get(d, d) for d in entry.get("new_includes", [])],
            "optional_includes": [NAMESPACE_MAP.get(d, d) for d in entry.get("new_optional_includes", [])],
            "target_path": target_file,
            "sha256": old_skills.get(name, {}).get("sha256", ""),
        })

        # Git-like commit log entry
        dep_str = ", ".join(entry.get("new_includes", [])) or "none"
        commit_msg = f"migrate({ns}): {name} — deps=[{dep_str}]"
        git_log.append(commit_msg)
        audit.log(f"  Wrote: {target_file}")

    # ── Generate registry.json ──
    registry = _build_registry(migrated_entries, session_id, git_log)
    registry_path = audit.store("registry.json", registry)
    audit.log(f"Registry: {registry_path}")

    # ── Git log artifact ──
    git_log_content = "\n".join(
        f"commit {hashlib.sha256(msg.encode()).hexdigest()[:12]}"
        f"\nAuthor: Skill Migration Agent"
        f"\nDate:   {audit.summary().get('session_id', '')}"
        f"\n\n    {msg}\n"
        for msg in git_log
    )
    git_log_path = audit.store("git-log.txt", git_log_content)
    audit.log(f"Git log: {git_log_path}")

    # ── Old vs new token comparison ──
    old_token_count = sum(_count_tokens(
        old_skills.get(n, {}).get("body", "")) for n in old_skills)
    top_only_tokens = sum(_count_tokens(
        migrated_entries[i].get("description", "")) for i in range(len(migrated_entries))
        if not any(migrated_entries[i]["name"] in d.get("new_includes", [])
                   for d in approved))
    audit.log(f"Token comparison: old={old_token_count} (flat), "
              f"new-top-level≈{top_only_tokens}")

    # ── Print summary ──
    print()
    print("  ╔══════════════════════════════════════════════════════════╗")
    print("  ║         Phase 4: Migration Complete                      ║")
    print("  ╚══════════════════════════════════════════════════════════╝")
    print()
    print(f"  {'Status':<14} {'Count':<8}")
    print(f"  {'─' * 14} {'─' * 8}")
    print(f"  {'Approved':<14} {len(approved):<8}")
    print(f"  {'Rejected':<14} {len(rejected):<8}")
    print(f"  {'Blocked':<14} {len(blocked):<8}")
    print(f"  {'Migrated':<14} {len(migrated_entries):<8}")
    print()
    print(f"  Target directory: {target_base}")
    print(f"  Audit trail: {audit.session_dir}")
    print()

    result = {
        "session_id": session_id,
        "target_base": target_base,
        "approved": len(approved),
        "rejected": rejected,
        "blocked": blocked,
        "migrated": len(migrated_entries),
        "git_log": git_log,
        "registry_path": registry_path,
    }
    result["__audit__"] = audit
    return result


def _load_old_skills(old_dir: str) -> dict[str, dict]:
    """Load old skill frontmatter and bodies from demo_old_system."""
    import re
    import hashlib
    skills = {}
    if not os.path.isdir(old_dir):
        return skills

    for fname in sorted(os.listdir(old_dir)):
        if not fname.endswith(".md"):
            continue
        fpath = os.path.join(old_dir, fname)
        with open(fpath) as f:
            content = f.read()

        m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)", content, re.DOTALL)
        if not m:
            continue

        yaml_block = m.group(1)
        body = m.group(2).strip()
        fm = {}
        for line in yaml_block.splitlines():
            kv = re.match(r"^(\w+):\s*(.*)", line)
            if kv:
                fm[kv.group(1).strip()] = kv.group(2).strip()

        name = fm.get("name", os.path.splitext(fname)[0])
        sha = hashlib.sha256()
        sha.update(content.encode())
        skills[name] = {
            "name": name,
            "description": fm.get("description", ""),
            "body": body,
            "sha256": sha.hexdigest(),
        }
    return skills


# ── Standalone entry point ─────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Phase 4: Skill Migration")
    parser.add_argument("--auto-approve", action="store_true",
                        help="Auto-approve all decisions (demo mode)")
    args = parser.parse_args()

    run_migration(auto_approve=args.auto_approve)
