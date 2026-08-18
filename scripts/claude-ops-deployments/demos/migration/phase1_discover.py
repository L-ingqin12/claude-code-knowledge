#!/usr/bin/env python3
"""
phase1_discover.py — Phase 1: Discovery

Scans demo_old_system/ for .md files, parses frontmatter, computes
sha256 hashes, and builds a reverse index of cross-references.

Standalone:  python3 phase1_discover.py
Importable: from migration.phase1_discover import run_discovery
"""

import hashlib
import json
import os
import re
import sys
from typing import Any

# ── Ensure `components` and sibling modules are importable ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(os.path.dirname(SCRIPT_DIR))  # claude-code-knowledge/
sys.path.insert(0, PROJECT_DIR)
sys.path.insert(0, SCRIPT_DIR)

from components.audit import AuditTrail


# ── Public API ─────────────────────────────────────────────────

def parse_frontmatter(filepath: str) -> dict[str, Any] | None:
    """Extract YAML frontmatter and body from a .md file.

    Returns {"name": str, "description": str, "body": str, "filepath": str}
    or None if the file lacks valid frontmatter.
    """
    with open(filepath, "r") as f:
        content = f.read()

    # Match frontmatter between --- delimiters
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)", content, re.DOTALL)
    if not m:
        return None

    yaml_block = m.group(1)
    body = m.group(2).strip()

    # Minimal YAML parsing (supports only name: and description: keys)
    frontmatter: dict[str, Any] = {}
    for line in yaml_block.splitlines():
        kv = re.match(r"^(\w+):\s*(.*)", line)
        if kv:
            key = kv.group(1).strip()
            value = kv.group(2).strip()
            frontmatter[key] = value

    frontmatter["body"] = body
    frontmatter["filepath"] = filepath
    return frontmatter


def compute_sha256(filepath: str) -> str:
    """Return hex digest of file contents."""
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def build_cross_reference_index(skills: dict[str, dict]) -> dict[str, list[str]]:
    """Build reverse index: which skills mention which other skill names.

    Returns a dict mapping skill_name → [list of skill names referenced in body].
    Only includes references to known skills.
    """
    known_names = set(skills.keys())
    index: dict[str, list[str]] = {}

    for name, data in skills.items():
        body = data.get("body", "")
        description = data.get("description", "")
        text = f"{body} {description}"
        refs = []
        for other in known_names:
            if other == name:
                continue
            # Match whole-word (including underscores)
            if re.search(rf"(?<!\w){re.escape(other)}(?!\w)", text):
                refs.append(other)
        if refs:
            index[name] = refs

    return index


def run_discovery(old_system_dir: str | None = None) -> dict[str, Any]:
    """Execute Phase 1 discovery and return the report dict."""
    if old_system_dir is None:
        old_system_dir = os.path.join(SCRIPT_DIR, "demo_old_system")

    audit = AuditTrail()
    audit.log("Phase 1: Discovery started")
    audit.log(f"Scanning: {old_system_dir}")

    # ── Scan .md files ──
    md_files = [
        os.path.join(old_system_dir, f)
        for f in sorted(os.listdir(old_system_dir))
        if f.endswith(".md")
    ]
    audit.log(f"Found {len(md_files)} markdown files")

    skills: dict[str, dict] = {}
    for fp in md_files:
        parsed = parse_frontmatter(fp)
        if parsed is None:
            audit.log(f"WARN: Skipping {fp} — no valid frontmatter")
            continue
        name = parsed.get("name", os.path.splitext(os.path.basename(fp))[0])
        sha = compute_sha256(fp)
        skills[name] = {
            "name": name,
            "description": parsed.get("description", ""),
            "body": parsed.get("body", ""),
            "filepath": parsed.get("filepath", fp),
            "sha256": sha,
        }
        audit.log(f"  Parsed: {name} → sha256={sha[:12]}...")

    # ── Cross-reference index ──
    cross_refs = build_cross_reference_index(skills)
    audit.log(f"Cross-references detected: {sum(len(v) for v in cross_refs.values())} total")

    # ── Build report ──
    report = {
        "session_id": audit.session_id,
        "old_system_dir": old_system_dir,
        "total_skills": len(skills),
        "skills": skills,
        "cross_references": cross_refs,
        "dependency_graph": {s: cross_refs.get(s, []) for s in skills},
    }

    # ── Store artifact ──
    report_path = audit.store("discovery-report.json", report)
    audit.log(f"Discovery report written: {report_path}")

    # ── Print summary table ──
    print()
    print("  ╔══════════════════════════════════════════════════════════╗")
    print("  ║           Phase 1: Discovery Complete                    ║")
    print("  ╚══════════════════════════════════════════════════════════╝")
    print()
    print(f"  {'Skill Name':<30} {'SHA256 (abbrev)':<18} {'Cross-refs':<12}")
    print(f"  {'─' * 30} {'─' * 18} {'─' * 12}")
    for sname in sorted(skills.keys()):
        s = skills[sname]
        refs = ", ".join(cross_refs.get(sname, [])) or "—"
        print(f"  {sname:<30} {s['sha256'][:12]:<18} {refs:<12}")
    print()
    print(f"  Total skills: {len(skills)}")
    print(f"  Skills with cross-references: {len(cross_refs)}")
    print(f"  Audit trail: {audit.session_dir}")
    print()

    report["__audit__"] = audit  # carry for chaining
    return report


# ── Standalone entry point ─────────────────────────────────────

if __name__ == "__main__":
    run_discovery()
