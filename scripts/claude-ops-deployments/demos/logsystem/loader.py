#!/usr/bin/env python3
"""
LogSkillLoader — Log Search/Analysis System Skill Management Demo

Scans skills/ directory for SKILL.md files (YAML frontmatter + body),
registers them with SkillRegistry, and provides namespace/scoped/file-based loading.

Design:
  - Each skill is a standalone SKILL.md file in a namespace subdirectory
  - Adding a new skill = dropping a new SKILL.md in the right directory
  - auto-discovers skills by scanning directories
  - Reuses SkillRegistry.resolve_dependencies() for dependency chain loading
  - Reuses fnmatch for path matching
"""

import os
import re
import fnmatch
import json
import textwrap

# ── Import SkillRegistry from parent scripts/ ──
# (handles dash in filename via importlib.util)
import importlib.util

_registry_path = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "skill-registry.py",
)
_spec = importlib.util.spec_from_file_location("skill_registry", _registry_path)
_reg_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_reg_mod)
SkillRegistry = _reg_mod.SkillRegistry
Skill = _reg_mod.Skill

# ── Attempt to import AuditTrail from components.audit ──
AuditTrail = None
_audit_path = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "components",
    "audit.py",
)
if os.path.exists(_audit_path):
    try:
        _spec2 = importlib.util.spec_from_file_location("audit_trail", _audit_path)
        _aud_mod = importlib.util.module_from_spec(_spec2)
        _spec2.loader.exec_module(_aud_mod)
        AuditTrail = _aud_mod.AuditTrail
    except Exception:
        AuditTrail = None  # standalone mode


def _parse_skill_md(filepath: str) -> dict:
    """Parse a SKILL.md file, extracting YAML frontmatter and markdown body."""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    # Extract frontmatter between --- markers
    fm_match = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
    if not fm_match:
        return None

    fm_text = fm_match.group(1)
    body = content[fm_match.end():].strip()

    # Parse simple YAML key-value pairs (no nested structures needed)
    result = {"body": body}
    current_key = None
    current_list = []

    for line in fm_text.split("\n"):
        # Check for list items under a key
        list_match = re.match(r"^\s+-\s+\"(.+?)\"", line)
        if list_match is None:
            list_match = re.match(r"^\s+-\s+(.+)$", line)

        if list_match:
            if current_key:
                current_list.append(list_match.group(1).strip('"'))
            continue

        # Check for key: value or key: []
        kv_match = re.match(r"^(\w[\w_-]*):\s*(.*)", line)
        if kv_match:
            # Save previous list if any
            if current_key and current_list:
                result[current_key] = current_list

            key = kv_match.group(1)
            val = kv_match.group(2).strip()

            # Handle empty list
            if val == "[]":
                current_key = key
                current_list = []
                continue

            # Handle quoted string
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]

            result[key] = val
            current_key = key
            current_list = []
            continue

    # Save final list
    if current_key and current_list:
        result[current_key] = current_list

    # Ensure list fields are lists
    for field in ("paths", "includes", "optional_includes", "conflicts"):
        if field not in result:
            result[field] = []
        elif isinstance(result[field], str):
            # Single value in YAML
            result[field] = [result[field]]

    return result


def _glob_match(filepath: str, pattern: str) -> bool:
    """Match a filepath against a glob pattern with full ** support.

    Python's fnmatch.fnmatch does NOT support ** as a recursive wildcard.
    This implementation converts the glob to a proper regex that handles
    **/ prefix, /** suffix, and /**/ middle patterns correctly.
    """
    if not pattern:
        return False

    parts = pattern.split("/")
    regex_parts = []
    for p in parts:
        if p == "**":
            regex_parts.append(".*")
        else:
            # Convert fnmatch wildcards, escape regex metacharacters
            regex_part = ""
            i = 0
            while i < len(p):
                c = p[i]
                if c == '*':
                    regex_part += "[^/]*"
                elif c == '?':
                    regex_part += "[^/]"
                elif c in '.+^${}()[]|\\':
                    regex_part += '\\' + c
                else:
                    regex_part += c
                i += 1
            regex_parts.append(regex_part)

    full_regex = "/".join(regex_parts)

    # If pattern starts with **/, also try matching without the leading **/
    if pattern.startswith("**/"):
        alt_regex = "/".join(regex_parts[1:])
        return bool(re.match(f"^{full_regex}$", filepath)) or bool(
            re.match(f"^{alt_regex}$", filepath)
        )

    return bool(re.match(f"^{full_regex}$", filepath))


class LogSkillLoader:
    """Scans, registers, and loads log system skills from SKILL.md files."""

    def __init__(self, skills_dir: str = None):
        self.registry = SkillRegistry()
        self._skills_dir = skills_dir or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "skills"
        )
        self._skill_namespace_map = {}  # skill_name -> namespace
        self._scan_and_register()

    # ── Discovery ──

    def _scan_and_register(self):
        """Walk skills/ directory and register every SKILL.md found."""
        if not os.path.isdir(self._skills_dir):
            print(f"[WARN] skills directory not found: {self._skills_dir}")
            return

        for root, dirs, files in os.walk(self._skills_dir):
            for fname in files:
                if fname != "SKILL.md":
                    continue
                filepath = os.path.join(root, fname)
                parsed = _parse_skill_md(filepath)
                if parsed is None:
                    print(f"[WARN] Could not parse {filepath}, skipping")
                    continue

                skill = Skill(
                    name=parsed.get("name", ""),
                    description=parsed.get("description", ""),
                    namespace=parsed.get("namespace", ""),
                    paths=parsed.get("paths", []),
                    includes=parsed.get("includes", []),
                    optional_includes=parsed.get("optional_includes", []),
                    content=parsed.get("body", ""),
                )

                if skill.name:
                    self.registry.register(skill)
                    self._skill_namespace_map[skill.name] = skill.namespace

    # ── Path A: Load by namespace ──

    def load_for_namespace(self, namespace: str) -> list:
        """Load all skills in a namespace + their transitive dependencies."""
        self.registry._loaded = set()
        ns_skills = self.registry.filter_by_context(namespace=namespace)
        all_loaded = []
        for s in ns_skills:
            all_loaded.extend(self.registry.resolve_dependencies(s.name))
        # Deduplicate by name while preserving order
        seen = set()
        deduped = []
        for s in all_loaded:
            if s.name not in seen:
                seen.add(s.name)
                deduped.append(s)
        return deduped

    # ── Path B: Load by file paths ──

    def load_for_files(self, file_paths: list) -> list:
        """Load skills whose path globs match the given files + dependencies.

        Uses _glob_match for proper ** pattern support (unlike fnmatch).
        """
        self.registry._loaded = set()
        matched = []
        for skill in self.registry._skills.values():
            if skill.paths and file_paths:
                if any(
                    _glob_match(f, pat) for f in file_paths for pat in skill.paths
                ):
                    matched.append(skill)
            elif not skill.paths:
                # Skills with empty paths are not matched by file context
                pass

        all_loaded = []
        for s in matched:
            all_loaded.extend(self.registry.resolve_dependencies(s.name))
        seen = set()
        deduped = []
        for s in all_loaded:
            if s.name not in seen:
                seen.add(s.name)
                deduped.append(s)
        return deduped

    # ── Path B2: Combined namespace + file loading ──

    def load_for_context(self, namespace: str = "", file_paths: list = None) -> list:
        """Load skills matching BOTH namespace AND file paths + dependencies.

        This is the primary entry point for real-world usage: user works in a
        context (namespace) with specific files visible.
        """
        if file_paths is None:
            file_paths = []

        self.registry._loaded = set()
        matched = []

        for skill in self.registry._skills.values():
            # Namespace filter
            if namespace and skill.namespace and skill.namespace != namespace:
                continue
            # File path filter (skip if skill has no paths)
            if file_paths and skill.paths:
                if not any(
                    _glob_match(f, pat) for f in file_paths for pat in skill.paths
                ):
                    continue
            elif file_paths and not skill.paths:
                # Skill has no paths defined - not activated by file context
                continue

            matched.append(skill)

        all_loaded = []
        for s in matched:
            all_loaded.extend(self.registry.resolve_dependencies(s.name))
        seen = set()
        deduped = []
        for s in all_loaded:
            if s.name not in seen:
                seen.add(s.name)
                deduped.append(s)
        return deduped

    # ── Path C: Search ──

    def search(self, query: str) -> list:
        """Keyword search across skill names and descriptions (stand-in for LLM search_skills)."""
        query_lower = query.lower()
        results = []
        for skill in self.registry._skills.values():
            if query_lower in skill.name.lower() or query_lower in skill.description.lower():
                results.append(skill)
        return results

    # ── Stats ──

    def stats(self) -> dict:
        """Return namespace breakdown, dependency counts, and token estimates."""
        all_skills = list(self.registry._skills.values())

        # Namespace breakdown
        ns_counts = {}
        for s in all_skills:
            ns = s.namespace or "ungrouped"
            ns_counts[ns] = ns_counts.get(ns, 0) + 1

        # Dependency counts (total edges)
        hard_dep_edges = sum(len(s.includes) for s in all_skills)
        opt_dep_edges = sum(len(s.optional_includes) for s in all_skills)

        # Skills with at least one dependency
        with_includes = sum(1 for s in all_skills if s.includes)
        with_optional = sum(1 for s in all_skills if s.optional_includes)
        with_paths = sum(1 for s in all_skills if s.paths)

        # Token estimates: rough calculation
        # Each skill in search index ~ 15-20 tokens (name + description)
        all_names_desc = " ".join(f"{s.name}: {s.description}" for s in all_skills)
        all_tokens_est = max(1, len(all_names_desc.split()))
        # Search-only listing (just names) ~2 tokens per skill
        search_tokens_est = max(1, len(all_skills) * 2)

        return {
            "total_skills": len(all_skills),
            "unique_namespaces": sorted(ns_counts.keys()),
            "namespace_counts": ns_counts,
            "hard_dependency_edges": hard_dep_edges,
            "optional_dependency_edges": opt_dep_edges,
            "skills_with_includes": with_includes,
            "skills_with_optional": with_optional,
            "skills_with_paths": with_paths,
            "estimated_tokens_all": all_tokens_est,
            "estimated_tokens_search_index": search_tokens_est,
            "estimated_savings_pct": round((1 - search_tokens_est / all_tokens_est) * 100, 1) if all_tokens_est > 0 else 0,
        }


# ═══════════════════════════════════════════════
# Standalone: Print full stats + token comparison
# ═══════════════════════════════════════════════
if __name__ == "__main__":
    print("=" * 72)
    print("  Log Search/Analysis System — Skill Registry Demo")
    print("=" * 72)

    loader = LogSkillLoader()
    stats = loader.stats()

    print(f"\n  Total Skills Registered: {stats['total_skills']}")
    print(f"  Namespaces: {stats['unique_namespaces']}")
    print(f"  Namespace Breakdown:")
    for ns, count in stats['namespace_counts'].items():
        print(f"    {ns}: {count} skills")
    print(f"\n  Dependency Graph:")
    print(f"    Hard dependency edges: {stats['hard_dependency_edges']}")
    print(f"    Optional dependency edges: {stats['optional_dependency_edges']}")
    print(f"    Skills with hard deps: {stats['skills_with_includes']}")
    print(f"    Skills with optional deps: {stats['skills_with_optional']}")
    print(f"    Skills with path associations: {stats['skills_with_paths']}")

    print(f"\n  ── Token Budget Comparison ──")
    print(f"  All skills (full listing):     ~{stats['estimated_tokens_all']} tokens")
    print(f"  Search index (names only):     ~{stats['estimated_tokens_search_index']} tokens")
    print(f"  Context window savings:         {stats['estimated_savings_pct']}%")
    print(f"  (Loading only what you need vs. dumping all skills into context)")

    # Per-namespace token breakdown
    print(f"\n  ── Per-Namespace Token Breakdown ──")
    for ns in stats['unique_namespaces']:
        ns_skills = [s for s in loader.registry._skills.values() if s.namespace == ns]
        ns_tokens = sum(len(f"{s.name}: {s.description}".split()) for s in ns_skills)
        print(f"    {ns}: {len(ns_skills)} skills, ~{ns_tokens} tokens")

    # All skills listing
    print(f"\n  ── Registered Skills ──")
    for skill in loader.registry._skills.values():
        ns_tag = f"[{skill.namespace}]" if skill.namespace else ""
        dep_info = ""
        if skill.includes:
            dep_info = f"  includes: {skill.includes}"
        if skill.optional_includes:
            dep_info += f"  optional: {skill.optional_includes}"
        print(f"    {skill.name} {ns_tag}: {skill.description}")
        if dep_info:
            print(f"      {dep_info.strip()}")

    print(f"\n  {'=' * 72}")
    print(f"  Demo complete. {stats['total_skills']} skills from {len(stats['unique_namespaces'])} namespaces.")
    print(f"  Architecture: plugin-style — add a skill = drop a SKILL.md")
    print(f"  {'=' * 72}")
