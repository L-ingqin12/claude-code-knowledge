"""
SkillClassifier — rule-based namespace and dependency inference.

No LLM calls.  Uses naming conventions, cross-reference scanning, and
keyword heuristics to infer:
  - Namespace (e.g. 'ops/deployment', 'monitoring/alerts')
  - Explicit includes (required dependencies)
  - Optional includes
  - File path globs relevant to the skill
  - Confidence level per inference
"""

import re
from typing import Any


# ── Namespace inference rules ──────────────────────────────────

# Priority-ordered list of (pattern, namespace, confidence) tuples.
# Earlier matches win for namespace inference.
NAMESPACE_RULES: list[tuple[re.Pattern, str, str]] = [
    (re.compile(r"^alert_"),        "monitoring/alerts",    "HIGH"),
    (re.compile(r"^deploy_"),       "ops/deployment",       "HIGH"),
    (re.compile(r"^db_"),           "ops/database",         "HIGH"),
    (re.compile(r"^error_budget_"), "observability/slo",    "HIGH"),
    (re.compile(r"^incident_"),     "ops/incident",         "HIGH"),
    (re.compile(r"^monitor_"),      "observability",        "HIGH"),
    (re.compile(r"^secret_"),       "security",             "HIGH"),
    (re.compile(r"^slack_"),        "communication",        "HIGH"),
    (re.compile(r"^docker_"),       "ci/cd",                "HIGH"),
    (re.compile(r"^k8s_"),          "ops/kubernetes",       "HIGH"),
    (re.compile(r"^git_"),          "development",          "HIGH"),
    (re.compile(r"^code_review_"),  "development",          "HIGH"),
    # Fallback: try keyword matching in description
    (re.compile(r"(deploy|rollback|release)", re.I), "ops/deployment", "MEDIUM"),
    (re.compile(r"(monitor|alert|dashboard)", re.I), "observability",  "MEDIUM"),
    (re.compile(r"(secret|crypto|cert)", re.I),      "security",       "MEDIUM"),
    (re.compile(r"(docker|container|image)", re.I),  "ci/cd",          "MEDIUM"),
    (re.compile(r"(k8s|kubernetes|pod)", re.I),      "ops/kubernetes", "MEDIUM"),
    (re.compile(r"(git|commit|pr|review)", re.I),    "development",    "MEDIUM"),
    (re.compile(r"(slack|notify|webhook)", re.I),    "communication",  "MEDIUM"),
    (re.compile(r"(database|migration|sql)", re.I),  "ops/database",   "MEDIUM"),
]

# ── Path glob inference ────────────────────────────────────────

PATH_RULES: list[tuple[re.Pattern, list[str]]] = [
    (re.compile(r"(deploy|rollback|k8s|kubernetes)", re.I), ["**/*.yaml", "**/*.yml", "**/deployments/**"]),
    (re.compile(r"(docker|container|build)", re.I),         ["**/Dockerfile", "**/*.dockerfile", "**/docker-compose*.yml"]),
    (re.compile(r"(database|migration|sql|db)", re.I),      ["**/*.sql", "**/migrations/**", "**/schema/**"]),
    (re.compile(r"(monitor|dashboard|grafana|prom)", re.I), ["**/*.json", "**/dashboards/**", "**/alerts/**"]),
    (re.compile(r"(git|commit|pr|review)", re.I),           ["**/*.md", "**/docs/**"]),
    (re.compile(r"(secret|vault|cert)", re.I),              ["**/*.enc.*", "**/secrets/**"]),
]


class SkillClassifier:
    """Rule-based classifier that produces structured classification results."""

    def __init__(self, cross_references: dict[str, list[str]] | None = None):
        self.cross_references = cross_references or {}

    # ── Public API ──────────────────────────────────────────────

    def classify_all(self, skills_data: dict[str, dict]) -> dict[str, dict]:
        """Classify every skill in the input dict.

        ``skills_data`` maps skill name (stem) → {
            "name": str,
            "description": str,
            "body": str,
            "sha256": str,
        }

        Returns a dict keyed by skill name, each value containing:
            inferred_namespace, confidence, includes[], optional_includes[],
            suggested_paths[], conflicts[], reasoning
        """
        results: dict[str, dict] = {}

        for skill_name, data in skills_data.items():
            ns, ns_conf, ns_reason = self._infer_namespace(skill_name, data)
            deps, opt_deps = self._infer_dependencies(skill_name, data)
            paths = self._infer_paths(skill_name, data)
            conflicts = self._detect_conflicts(skill_name, ns, data, results)

            results[skill_name] = {
                "inferred_namespace": ns,
                "confidence": ns_conf,
                "includes": sorted(deps),
                "optional_includes": sorted(opt_deps),
                "suggested_paths": paths,
                "conflicts": conflicts,
                "reasoning": ns_reason,
            }

        return results

    # ── Internals ───────────────────────────────────────────────

    def _infer_namespace(self, name: str, data: dict) -> tuple[str, str, str]:
        """Return (namespace, confidence, reasoning)."""
        description = data.get("description", "")
        body = data.get("body", "")

        # 1. Name-based rules (highest confidence)
        for pattern, namespace, confidence in NAMESPACE_RULES:
            if pattern.search(name):
                reason = f"Name '{name}' matches pattern /{pattern.pattern}/ → namespace '{namespace}'"
                return namespace, confidence, reason

        # 2. Description-based fallback (MEDIUM)
        text = f"{description}\n{body}"
        for pattern, namespace, confidence in NAMESPACE_RULES:
            # Only use MEDIUM-level rules for description/body matching
            if confidence == "MEDIUM" and pattern.search(text):
                reason = f"Description/body matches keyword /{pattern.pattern}/ → namespace '{namespace}'"
                return namespace, "MEDIUM", reason

        # 3. Catch-all
        return "general/unclassified", "LOW", f"No specific pattern matched → default namespace"

    def _infer_dependencies(self, name: str, data: dict) -> tuple[list[str], list[str]]:
        """Return (required_deps, optional_deps) based on cross-reference index."""
        required: list[str] = []
        optional: list[str] = []

        refs = self.cross_references.get(name, [])
        for ref in refs:
            # Heuristic: if the reference appears in "see also" or parenthetical
            # context, treat as optional; otherwise required.
            if self._is_optional_reference(name, ref, data):
                optional.append(ref)
            else:
                required.append(ref)

        return required, optional

    def _is_optional_reference(self, skill_name: str, ref_name: str, data: dict) -> bool:
        """Determine if a cross-reference is optional vs required.

        Simple heuristic: if the reference is introduced with words like
        'optionally', 'may', 'consider', 'see also' → optional.
        Otherwise → required.
        """
        body = data.get("body", "")
        description = data.get("description", "")

        optional_patterns = [
            rf"(?:optionally|optional|may|consider|see also|you can).{{0,40}}{re.escape(ref_name)}",
            rf"{re.escape(ref_name)}.{{0,40}}(?:optionally|optional|may)",
        ]
        for pat in optional_patterns:
            if re.search(pat, body, re.IGNORECASE) or re.search(pat, description, re.IGNORECASE):
                return True

        return False

    def _infer_paths(self, name: str, data: dict) -> list[str]:
        """Suggest file globs based on the skill's domain."""
        description = data.get("description", "")
        body = data.get("body", "")
        text = f"{name} {description} {body}"

        matched: list[str] = []
        seen: set[str] = set()
        for pattern, globs in PATH_RULES:
            if pattern.search(text):
                for g in globs:
                    if g not in seen:
                        matched.append(g)
                        seen.add(g)
        return matched

    def _detect_conflicts(self, name: str, ns: str, data: dict,
                          existing: dict[str, dict]) -> list[str]:
        """Detect naming or namespace conflicts with already-classified skills."""
        conflicts: list[str] = []

        # Check if another skill with similar name but different namespace exists
        base = name.split("_")[0] if "_" in name else name
        for other_name, other_result in existing.items():
            if other_name == name:
                continue
            other_base = other_name.split("_")[0] if "_" in other_name else other_name
            if base == other_base and other_result.get("inferred_namespace") != ns:
                conflicts.append(
                    f"Name root '{base}' conflicts with '{other_name}' "
                    f"(namespace '{other_result.get('inferred_namespace')}' vs '{ns}')"
                )

        return conflicts
