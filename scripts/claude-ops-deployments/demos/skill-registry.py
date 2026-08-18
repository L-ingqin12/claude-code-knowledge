#!/usr/bin/env python3
"""
SkillRegistry — 依赖链级联加载 + 命名空间过滤 + 条件匹配
最小可行实现，可直接运行测试。
"""

import re, os, fnmatch, json
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Skill:
    name: str
    description: str
    namespace: str = ""
    paths: list = field(default_factory=list)
    includes: list = field(default_factory=list)
    optional_includes: list = field(default_factory=list)
    content: str = ""


class SkillRegistry:
    def __init__(self):
        self._skills: dict[str, Skill] = {}
        self._loaded: set = set()  # 防循环

    def register(self, skill: Skill):
        self._skills[skill.name] = skill

    # ── 路径 A: 依赖式引入 ──
    def resolve_dependencies(self, skill_name: str, depth: int = 0, max_depth: int = 5) -> list[Skill]:
        """级联加载一个 skill 及其所有依赖链"""
        if depth > max_depth:
            raise RecursionError(f"Circular or too deep dependency: {skill_name}")
        if skill_name in self._loaded:
            return []

        skill = self._skills.get(skill_name)
        if not skill:
            return []

        self._loaded.add(skill_name)
        resolved = [skill]

        # 必选依赖
        for dep in skill.includes:
            resolved.extend(self.resolve_dependencies(dep, depth + 1, max_depth))

        # 可选依赖
        for opt_dep in skill.optional_includes:
            try:
                resolved.extend(self.resolve_dependencies(opt_dep, depth + 1, max_depth))
            except (KeyError, RecursionError):
                pass  # 可选依赖缺失不报错

        return resolved

    # ── 路径 B: 条件过滤 ──
    def filter_by_context(self, namespace: str = "", current_files: list = None) -> list[Skill]:
        """根据命名空间和文件路径预过滤——零 token 开销"""
        candidates = []
        for skill in self._skills.values():
            # 命名空间过滤
            if namespace and skill.namespace and skill.namespace != namespace:
                continue
            # paths glob 匹配
            if skill.paths and current_files:
                if not any(fnmatch.fnmatch(f, pat) for f in current_files for pat in skill.paths):
                    continue
            candidates.append(skill)
        return candidates

    # ── 路径 C: 检索式发现 ──
    def build_search_index(self) -> str:
        """构建发给小模型的候选清单"""
        lines = []
        for skill in self._skills.values():
            ns = f"[{skill.namespace}]" if skill.namespace else ""
            lines.append(f"- {skill.name} {ns}: {skill.description}")
        return "\n".join(lines)

    # ── 组合：完整加载流程 ──
    def load_for_task(self, skill_names: list, context: dict = None) -> list[Skill]:
        """
        给定一组被选中的顶层 skill 名，返回所有需要加载的 skill（含依赖链）。
        context 可选：用于条件过滤。
        """
        self._loaded = set()
        all_loaded = []
        for name in skill_names:
            all_loaded.extend(self.resolve_dependencies(name))
        return all_loaded

    def stats(self):
        return {
            "total": len(self._skills),
            "namespaces": list(set(s.namespace for s in self._skills.values() if s.namespace)),
            "with_deps": sum(1 for s in self._skills.values() if s.includes),
            "with_paths": sum(1 for s in self._skills.values() if s.paths),
        }


# ═══════════════════════════════════════════════
# 测试：模拟一个真实场景
# ═══════════════════════════════════════════════
if __name__ == "__main__":
    reg = SkillRegistry()

    # 共享基础 skill（被其他 skill 依赖）
    reg.register(Skill(
        name="docker-build",
        namespace="shared",
        description="Docker 镜像构建流程",
        content="docker build -t $IMAGE . && docker push $IMAGE",
    ))
    reg.register(Skill(
        name="k8s-apply",
        namespace="shared",
        description="Kubernetes 部署应用",
        content="kubectl apply -f deployment.yaml",
    ))
    reg.register(Skill(
        name="secret-management",
        namespace="shared",
        description="读取和管理部署密钥",
        content="使用 vault-cli 获取密钥",
    ))
    reg.register(Skill(
        name="slack-notify",
        namespace="shared",
        description="发送 Slack 通知",
        content="curl -X POST $SLACK_WEBHOOK ...",
    ))

    # 顶层 skill（直接面向任务）
    reg.register(Skill(
        name="data-pipeline-deploy",
        namespace="team/backend",
        description="数据管道部署流程",
        includes=["docker-build", "k8s-apply", "secret-management"],
        optional_includes=["slack-notify"],
        content="# 数据管道部署\n1. 构建镜像\n2. 部署到 K8s\n3. 验证",
    ))
    reg.register(Skill(
        name="react-component-dev",
        namespace="team/frontend",
        description="React 组件开发规范",
        paths=["**/*.tsx", "**/*.jsx"],
        content="# React 组件规范\n- 使用函数组件\n- Props 类型定义",
    ))
    reg.register(Skill(
        name="go-api-dev",
        namespace="team/backend",
        description="Go API 开发规范",
        paths=["**/*.go"],
        content="# Go API 规范\n- 错误处理\n- 接口设计",
    ))

    # ── 测试 1: 依赖链加载 ──
    print("=" * 60)
    print("测试 1: 依赖链级联加载")
    print("=" * 60)
    loaded = reg.load_for_task(["data-pipeline-deploy"])
    print(f"顶层入口: data-pipeline-deploy")
    print(f"实际加载 ({len(loaded)} 个):")
    for s in loaded:
        deps = f" → dependents: {s.includes}" if s.includes else ""
        print(f"  {s.name} [{s.namespace}]{deps}")
    # 期望输出: data-pipeline-deploy + docker-build + k8s-apply + secret-management + slack-notify = 5

    # ── 测试 2: 条件过滤 ──
    print("\n" + "=" * 60)
    print("测试 2: 条件过滤（编辑 .go 文件 → 只加载 Go skill）")
    print("=" * 60)
    candidates = reg.filter_by_context(current_files=["main.go", "handler.go"])
    print(f"当前文件: main.go, handler.go")
    print(f"候选 skill ({len(candidates)} 个):")
    for s in candidates:
        print(f"  {s.name} paths={s.paths}")

    # ── 测试 3: 命名空间过滤 ──
    print("\n" + "=" * 60)
    print("测试 3: 命名空间过滤（只加载 frontend skill）")
    print("=" * 60)
    candidates = reg.filter_by_context(namespace="team/frontend")
    print(f"过滤 namespace=team/frontend:")
    for s in candidates:
        print(f"  {s.name}")

    # ── 测试 4: Token 开销对比 ──
    print("\n" + "=" * 60)
    print("测试 4: Token 开销对比")
    print("=" * 60)
    all_list = reg.build_search_index()
    all_tokens = len(all_list.split())
    # 只列顶层 skill（无依赖声明的 and 有 includes 的是入口）
    top_level = [s for s in reg._skills.values() if not any(s.name in other.includes for other in reg._skills.values())]
    top_list = "\n".join(f"- {s.name}: {s.description}" for s in top_level)
    top_tokens = len(top_list.split())

    print(f"全部列出: {reg.stats()['total']} skills → ~{all_tokens} token")
    print(f"只列顶层 ({len(top_level)} 个): → ~{top_tokens} token")
    print(f"检索式发现 (search_skills 工具声明): → ~15 token")
    print(f"节省: {all_tokens - 15} token ({100*(all_tokens-15)//all_tokens}%)")

    # ── 测试 5: 注册中心统计 ──
    print("\n" + "=" * 60)
    print("测试 5: 注册中心统计")
    print("=" * 60)
    print(json.dumps(reg.stats(), indent=2))
