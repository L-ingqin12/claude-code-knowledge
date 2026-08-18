---
name: es-query-builder
description: Build Elasticsearch DSL queries from natural language descriptions
namespace: logs/shared
paths:
  - "**/elasticsearch/**"
  - "**/es/**"
optional_includes:
  - time-range-parser
---

# Elasticsearch Query Builder

Translates natural language query descriptions into Elasticsearch DSL JSON. Accepts a query string and optional time range, producing a structured query body with bool/filter/must clauses. Supports term, match, range, wildcard, and nested queries. When time-range-parser is loaded, automatically wraps queries with timestamp filters. Output format is a complete ES `_search` request body ready for execution against any ES 7.x+ cluster.
