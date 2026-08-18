---
name: app-log-search
description: Full-text search across application logs with structured field filtering
namespace: logs/queries
paths:
  - "**/app/**"
includes:
  - es-query-builder
---

# Application Log Search

Performs full-text search across application log streams. Uses es-query-builder to construct DSL queries from natural language. Accepts free-text search terms, log level, service name, environment, and correlation ID. Returns matching log entries with timestamp, log level, logger name, thread, message, and structured context fields. Supports highlighting of matched terms, field-level filtering, and date histogram aggregation for trend visualization.
