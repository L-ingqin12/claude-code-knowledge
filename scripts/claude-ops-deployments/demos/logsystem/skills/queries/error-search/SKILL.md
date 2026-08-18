---
name: error-search
description: Search error logs using Elasticsearch DSL with optional time range filtering
namespace: logs/queries
paths:
  - "**/errors/**"
  - "**/logs/**"
includes:
  - es-query-builder
optional_includes:
  - time-range-parser
---

# Error Log Search

Searches for error-level and exception log entries across indexed log sources. Delegates DSL construction to es-query-builder and optionally applies time range via time-range-parser. Accepts error keywords, service name, environment, and minimum severity level. Returns matching log entries sorted by timestamp descending, with fields for message, service, host, and stack trace snippet. Supports pagination and field filtering for efficient large-result handling.
