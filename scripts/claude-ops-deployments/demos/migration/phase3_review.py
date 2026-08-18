#!/usr/bin/env python3
"""
phase3_review.py — Phase 3: Human Review

Reads classification-report.json and generates:
  - review-report.md   (human-readable markdown with GREEN/YELLOW/RED sections)
  - phase-3-decisions.json  (machine-readable, all decisions with "pending" status)

Standalone:  python3 phase3_review.py
Importable: from migration.phase3_review import run_review
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


# ── Colour names (for markdown sections) ───────────────────────
CONFIDENCE_SECTION = {
    "HIGH":   ("GREEN",  "Auto-approved — no human review needed"),
    "MEDIUM": ("YELLOW", "Requires confirmation"),
    "LOW":    ("RED",    "MUST be confirmed by a human"),
}


def run_review(classification_report: dict | None = None,
               report_path: str | None = None) -> dict:
    """Execute Phase 3 review.

    Provide either a parsed classification_report dict, or a path to one.
    """
    # ── Load input ──
    if classification_report is None:
        if report_path is None:
            pattern = "/tmp/skill-migration-*/classification-report.json"
            import glob
            files = sorted(glob.glob(pattern))
            if not files:
                print("ERROR: No classification-report.json found. Run phase2 first.")
                sys.exit(1)
            report_path = files[-1]
            print(f"Using latest classification report: {report_path}")
        with open(report_path) as f:
            classification_report = json.load(f)

    session_id = classification_report.get("session_id", "unknown")
    audit = AuditTrail(session_id=session_id)
    audit.log("Phase 3: Review started")

    classifications: dict = classification_report.get("classifications", {})
    audit.log(f"Loaded {len(classifications)} classified skills for review")

    # ── Build decisions list ──
    decisions: list[dict] = []
    for name, cls in sorted(classifications.items()):
        colour, rationale = CONFIDENCE_SECTION.get(cls.get("confidence", "LOW"),
                                                   ("GREY", "Unknown confidence"))
        decisions.append({
            "skill_name": name,
            "confidence": cls.get("confidence", "LOW"),
            "section": colour,
            "old_namespace": "(flat — no namespace)",
            "new_namespace": cls.get("inferred_namespace", ""),
            "old_includes": [],
            "new_includes": cls.get("includes", []),
            "new_optional_includes": cls.get("optional_includes", []),
            "old_paths": [],
            "new_paths": cls.get("suggested_paths", []),
            "reasoning": cls.get("reasoning", ""),
            "conflicts": cls.get("conflicts", []),
            "approval_status": "pending",
            "approval_rationale": rationale,
        })

    # ── Generate review-report.md ──
    md_lines: list[str] = []
    md_lines.append("# Phase 3 — Migration Review Report\n")
    md_lines.append(f"**Session:** {session_id}  \n")
    md_lines.append(f"**Skills reviewed:** {len(decisions)}  \n")
    md_lines.append(f"**Date:** {audit.summary().get('session_id', 'unknown')}\n")
    md_lines.append("---\n")

    # Group by section
    sections: dict[str, list[dict]] = {}
    for d in decisions:
        sections.setdefault(d["section"], []).append(d)

    for colour in ("GREEN", "YELLOW", "RED"):
        items = sections.get(colour, [])
        emoji = {"GREEN": "🟢", "YELLOW": "🟡", "RED": "🔴"}[colour]
        md_lines.append(f"\n## {emoji} {colour} — {items[0]['approval_rationale'] if items else 'No items'}\n" if items else f"\n## {emoji} {colour} — No items\n")
        md_lines.append(f"**{len(items)} decision(s)**\n")

        for d in items:
            md_lines.append(f"### {d['skill_name']}\n")
            md_lines.append(f"- **Old namespace:** `{d['old_namespace']}`  \n")
            md_lines.append(f"- **Proposed namespace:** `{d['new_namespace']}`  \n")
            md_lines.append(f"- **Confidence:** `{d['confidence']}`  \n")
            md_lines.append(f"- **Includes:** `{', '.join(d['new_includes']) if d['new_includes'] else '(none)'}`  \n")
            md_lines.append(f"- **Optional includes:** `{', '.join(d['new_optional_includes']) if d['new_optional_includes'] else '(none)'}`  \n")
            md_lines.append(f"- **Suggested paths:** `{', '.join(d['new_paths']) if d['new_paths'] else '(none)'}`  \n")
            if d["conflicts"]:
                for c in d["conflicts"]:
                    md_lines.append(f"- **Conflict:** {c}  \n")
            md_lines.append(f"- **Agent's reasoning:** {d['reasoning']}  \n")
            md_lines.append(f"- **Approval:** `{d['approval_status']}` ({d['approval_rationale']})\n")
            md_lines.append("---\n")

    md_content = "\n".join(md_lines)
    review_md_path = audit.store("review-report.md", md_content)
    audit.log(f"Review report (markdown): {review_md_path}")

    # ── Generate phase-3-decisions.json ──
    decisions_payload = {
        "session_id": session_id,
        "total_decisions": len(decisions),
        "decisions": decisions,
    }
    decisions_path = audit.store("phase-3-decisions.json", decisions_payload)
    audit.log(f"Decisions file: {decisions_path}")

    # ── Print summary ──
    print()
    print("  ╔══════════════════════════════════════════════════════════╗")
    print("  ║         Phase 3: Review Report Generated                 ║")
    print("  ╚══════════════════════════════════════════════════════════╝")
    print()
    print(f"  {'Section':<12} {'Count':<8} {'Action':<40}")
    print(f"  {'─' * 12} {'─' * 8} {'─' * 40}")
    for colour in ("GREEN", "YELLOW", "RED"):
        count = len(sections.get(colour, []))
        action = {
            "GREEN": "Auto-approved",
            "YELLOW": "Manual confirmation requested",
            "RED": "MUST confirm before proceeding",
        }[colour]
        print(f"  {colour:<12} {count:<8} {action:<40}")
    print()
    print(f"  Total decisions: {len(decisions)}")
    print(f"  Audit trail: {audit.session_dir}")
    print()

    result = decisions_payload
    result["__audit__"] = audit
    result["__report_md_path__"] = review_md_path
    return result


# ── Standalone entry point ─────────────────────────────────────

if __name__ == "__main__":
    run_review()
