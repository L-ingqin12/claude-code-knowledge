#!/usr/bin/env python3
"""
phase2_classify.py — Phase 2: Classification

Reads discovery-report.json, classifies each skill using the rule-based
SkillClassifier, detects conflicts, and outputs classification-report.json.

Standalone:  python3 phase2_classify.py
Importable: from migration.phase2_classify import run_classification
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
from components.classifier import SkillClassifier


def run_classification(discovery_report: dict | None = None,
                       report_path: str | None = None) -> dict:
    """Execute Phase 2 classification.

    Provide either a parsed discovery_report dict, or a path to one.
    """
    # ── Load input ──
    if discovery_report is None:
        if report_path is None:
            # Guess the latest session from /tmp
            import glob
            sessions = sorted(glob.glob("/tmp/skill-migration-*/discovery-report.json"))
            if not sessions:
                print("ERROR: No discovery-report.json found. Run phase1 first.")
                sys.exit(1)
            report_path = sessions[-1]
            print(f"Using latest discovery report: {report_path}")
        with open(report_path) as f:
            discovery_report = json.load(f)

    # ── Reuse or create audit trail ──
    session_id = discovery_report.get("session_id", "unknown")
    audit = AuditTrail(session_id=session_id)
    audit.log("Phase 2: Classification started")

    skills_data: dict = discovery_report.get("skills", {})
    cross_refs: dict = discovery_report.get("cross_references", {})

    audit.log(f"Loaded {len(skills_data)} skills, {len(cross_refs)} cross-reference entries")

    # ── Classify ──
    classifier = SkillClassifier(cross_references=cross_refs)
    classification = classifier.classify_all(skills_data)

    audit.log(f"Classification complete: {len(classification)} skills")

    # ── Build report ──
    report = {
        "session_id": session_id,
        "discovery_source": discovery_report.get("old_system_dir", ""),
        "total_classified": len(classification),
        "classifications": classification,
    }

    report_path = audit.store("classification-report.json", report)
    audit.log(f"Classification report written: {report_path}")

    # ── Print summary ──
    _print_summary(classification)
    print(f"  Audit trail: {audit.session_dir}")
    print()

    report["__audit__"] = audit
    return report


def _print_summary(classifications: dict) -> None:
    """Print a confidence-level summary table."""
    print()
    print("  ╔══════════════════════════════════════════════════════════╗")
    print("  ║        Phase 2: Classification Complete                  ║")
    print("  ╚══════════════════════════════════════════════════════════╝")
    print()

    # Group by confidence
    groups: dict[str, list[tuple[str, dict]]] = {"HIGH": [], "MEDIUM": [], "LOW": []}
    for name, cls in classifications.items():
        groups.setdefault(cls.get("confidence", "LOW"), []).append((name, cls))

    header = f"  {'Skill Name':<28} {'Namespace':<24} {'Confidence':<12} {'Deps':<8}"
    print(header)
    print(f"  {'─' * 28} {'─' * 24} {'─' * 12} {'─' * 8}")

    for level in ("HIGH", "MEDIUM", "LOW"):
        for name, cls in sorted(groups[level]):
            ns = cls.get("inferred_namespace", "?")
            conf = cls.get("confidence", "?")
            deps = len(cls.get("includes", [])) + len(cls.get("optional_includes", []))
            print(f"  {name:<28} {ns:<24} {conf:<12} {deps:<8}")

    print()
    for level in ("HIGH", "MEDIUM", "LOW"):
        count = len(groups[level])
        print(f"  {level}: {count} skill{'s' if count != 1 else ''}")

    total = sum(len(v) for v in groups.values())
    print(f"  Total: {total} skills classified")
    print()


# ── Standalone entry point ─────────────────────────────────────

if __name__ == "__main__":
    run_classification()
