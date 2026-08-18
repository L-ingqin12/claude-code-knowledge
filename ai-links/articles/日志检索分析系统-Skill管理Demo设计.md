---
title: "日志检索分析系统——Skill 管理框架应用 Demo 设计"
aliases: [日志系统Skill Demo, Skill管理Demo, 日志检索Skills]
tags: [ai/skills, ai/learning]
created: 2026-06-22
updated: 2026-08-17
status: review
source: "系统设计"
date: "2026-06-22"
fetched_at: "2026-06-22"
---

# 日志检索分析系统——Skill 管理框架应用 Demo 设计

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[Agent驱动Skill迁移设计]] | [[Skill规模化管理-从渐进式披露到检索式发现]] | [[Claude-Code记忆机制源码拆解]]

## 背景

将 Skill 规模化管理框架（命名空间 + 依赖声明 + 条件匹配 + 检索式发现）应用到一个具体的大型系统上，验证框架在真实场景下的可用性。

选定场景：**大型日志检索分析系统**——天然具备多数据源、多查询模式、多分析工作流的特征，skill 数量可以轻松从几十增长到上百。

## 场景定义

```
系统规模：
  - 数据源：Elasticsearch（应用日志）、Loki（容器日志）、ClickHouse（指标）、Kafka（实时流）
  - 日均日志量：~50TB
  - 用户角色：SRE（全权限）、Dev（只读应用日志）、Sec（只读审计日志）
  - 预置查询模板：~60 个
  - 告警响应流程：~15 条
  - 分析 Workflow：~20 个（异常检测 / 根因分析 / 容量预测 / 告警关联）
```

## 目标 Skill 架构

### 命名空间划分

```
logs/
├── shared/                         # namespace: logs/shared
│   ├── es-query-builder/           # ES DSL 构建器（30+ skill 依赖它）
│   ├── loki-query-builder/         # Loki LogQL 构建器
│   ├── time-range-parser/          # 时间范围解析（"最近一小时"→timestamp）
│   ├── result-formatter/           # 结果格式化（table/json/csv）
│   └── auth-checker/               # 权限校验（SRE/Dev/Sec 角色映射）
│
├── queries/                        # namespace: logs/queries
│   ├── error-search/               # 错误日志搜索 → es-query-builder, time-range-parser
│   ├── trace-search/               # 链路追踪搜索 → es-query-builder
│   ├── container-log-search/       # 容器日志搜索 → loki-query-builder
│   ├── slow-query-search/          # 慢查询检测 → es-query-builder, result-formatter
│   ├── security-audit-search/      # 安全审计搜索 → es-query-builder, auth-checker
│   ├── app-log-search/             # 应用日志全量搜索
│   ├── metric-query/               # ClickHouse 指标查询
│   └── log-aggregation/            # 日志聚合统计
│
├── alerts/                         # namespace: logs/alerts
│   ├── k8s-oom-alert/              # K8s OOM 告警响应 → error-search, slow-query-search
│   ├── disk-full-alert/            # 磁盘满告警 → container-log-search
│   ├── spike-detection/            # 流量突增检测 → es-query-builder, result-formatter
│   ├── error-rate-alert/           # 错误率告警
│   ├── latency-alert/              # 延迟告警
│   └── cert-expiry-alert/          # 证书过期告警
│
├── workflows/                      # namespace: logs/workflows
│   ├── rca-pipeline/               # 根因分析 → error-search + trace-search + spike-detection
│   ├── capacity-forecast/          # 容量预测 → slow-query-search + result-formatter
│   ├── alert-correlation/          # 告警关联分析 → spike-detection + k8s-oom-alert
│   └── incident-report/            # 事故报告生成 → 多查询 + result-formatter
│
└── dashboards/                     # namespace: logs/dashboards
    ├── sre-overview/               # SRE 总览看板
    ├── error-budget/               # 错误预算看板
    └── latency-heatmap/            # 延迟热力图
```

### Demo 规模

25 个代表性 skill 覆盖 5 个命名空间：

| 命名空间 | Skill 数 | 示例 |
|---------|----------|------|
| `logs/shared` | 5 | es-query-builder, loki-query-builder, time-range-parser, result-formatter, auth-checker |
| `logs/queries` | 8 | error-search, trace-search, container-log-search, slow-query-search, security-audit-search, app-log-search, metric-query, log-aggregation |
| `logs/alerts` | 6 | k8s-oom-alert, disk-full-alert, spike-detection, error-rate-alert, latency-alert, cert-expiry-alert |
| `logs/workflows` | 4 | rca-pipeline, capacity-forecast, alert-correlation, incident-report |
| `logs/dashboards` | 2 | sre-overview, error-budget |

### 依赖关系（15 条 includes）

共享层被依赖：
- `es-query-builder` ← error-search, trace-search, slow-query-search, security-audit-search, spike-detection, rca-pipeline
- `loki-query-builder` ← container-log-search
- `time-range-parser` ← error-search, slow-query-search, metric-query
- `result-formatter` ← slow-query-search, spike-detection, capacity-forecast, incident-report
- `auth-checker` ← security-audit-search

工作流层跨命名空间依赖：
- `rca-pipeline` ← error-search + trace-search + spike-detection
- `alert-correlation` ← spike-detection + k8s-oom-alert
- `capacity-forecast` ← slow-query-search + result-formatter

### Token 预算对比

| 方案 | System prompt 开销 | 节省 |
|------|-------------------|------|
| 全量列出（25 skill） | ~750 token | 基线 |
| 只列顶层入口 | ~200 token | 73% |
| 检索式发现（search_skills + 依赖级联） | ~30 token | 96% |

## Skill 示例：rca-pipeline 的完整声明

```yaml
---
name: rca-pipeline
description: 根因分析流水线——自动关联错误日志、调用链和异常指标，定位根因
namespace: logs/workflows
paths:
  - "**/incidents/**"
  - "**/postmortems/**"
includes:
  - error-search
  - trace-search
  - spike-detection
optional_includes:
  - incident-report
conflicts:
  - alert-correlation
---

# 根因分析流水线

## 触发条件
- 告警升级为 incident
- 手动触发 "/rca <incident-id>"

## 流程
1. 根据 incident 时间窗口，调用 error-search 提取异常日志
2. 对异常日志中的 trace_id，调用 trace-search 还原调用链
3. 调用 spike-detection 检查关联指标是否异常
4. 输出：根因定位报告（含置信度）

## 输出格式
table: timestamp | service | error_type | root_cause_candidate | confidence
```

## 与 Skill 管理框架的对应

| 框架组件 | 日志系统中的落点 |
|---------|----------------|
| 命名空间隔离 | `logs/shared` / `logs/queries` / `logs/alerts` / `logs/workflows` / `logs/dashboards` |
| 依赖链级联 | rca-pipeline → 自动加载 error-search + trace-search + spike-detection |
| paths 条件匹配 | `security-audit-search` 的 paths: `["**/audit/**", "**/auth.log"]` |
| conflicts 互斥 | `rca-pipeline` 和 `alert-correlation` 互斥（避免同时排查两条线索） |
| 检索式发现 | search_skills("K8s 集群 Pod 频繁重启") → [container-log-search, k8s-oom-alert, rca-pipeline] |
| Stale 管理 | ES 版本升级后 `es-query-builder` 标记 stale，提示 review |

## 权限维度的命名空间交叉

日志系统有一个通用 Skill 框架未覆盖的维度：**权限**。不同角色的用户能访问的 skill 不同：

| 角色 | 可访问的命名空间 | 限制 |
|------|---------------|------|
| SRE | 全部 | 无限制 |
| Dev | queries/（不含 security-audit-search） | auth-checker 拦截 |
| Sec | queries/security-audit-search | 仅审计相关 |

`auth-checker` 作为 shared 层 skill，在 queries/workflows/alerts 等 skill 的 `includes` 中被声明——每次数据访问前先过权限。

## Demo 文件结构

```
scripts/migration/demo-old-system/
├── shared/
│   ├── es-query-builder.md
│   ├── loki-query-builder.md
│   ├── time-range-parser.md
│   ├── result-formatter.md
│   └── auth-checker.md
├── queries/
│   ├── error-search.md
│   ├── trace-search.md
│   ├── container-log-search.md
│   ├── slow-query-search.md
│   ├── security-audit-search.md
│   ├── app-log-search.md
│   ├── metric-query.md
│   └── log-aggregation.md
├── alerts/
│   ├── k8s-oom-alert.md
│   ├── disk-full-alert.md
│   ├── spike-detection.md
│   ├── error-rate-alert.md
│   ├── latency-alert.md
│   └── cert-expiry-alert.md
├── workflows/
│   ├── rca-pipeline.md
│   ├── capacity-forecast.md
│   ├── alert-correlation.md
│   └── incident-report.md
├── dashboards/
│   ├── sre-overview.md
│   └── error-budget.md
└── registry.json    # Skill Registry 索引（MEMORY.md 风格）
```
