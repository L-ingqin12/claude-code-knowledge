---
name: loki-query-builder
description: Build LogQL queries from natural language for Grafana Loki log retrieval
namespace: logs/shared
paths:
  - "**/loki/**"
  - "**/grafana/**"
---

# Loki Query Builder

Translates natural language log search requests into LogQL for Grafana Loki. Accepts log stream selectors, filter expressions, and parser expressions. Supports line filters, label filters, JSON/logfmt pattern parsers, and unwrap operations. Output format is a complete LogQL query string with proper label matchers and duration. Designed for single-tenant and multi-tenant Loki deployments with proper tenant ID handling.
