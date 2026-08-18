---
name: slow-query-search
description: Detect and analyze slow database queries with performance metrics
namespace: logs/queries
paths:
  - "**/database/**"
  - "**/queries/**"
includes:
  - es-query-builder
  - result-formatter
---

# Slow Query Search

Detects and analyzes slow database queries from query log data. Uses es-query-builder for structured search construction and result-formatter for readable output. Accepts duration threshold, database type, user, and source host filters. Returns query text, execution duration, timestamp, rows examined, rows returned, and explain plan links. Groups repeated slow queries by normalized fingerprint to identify the most impactful optimization targets.
