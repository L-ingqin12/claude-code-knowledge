---
name: trace-search
description: Search distributed traces using Elasticsearch DSL with trace ID or service filters
namespace: logs/queries
paths:
  - "**/traces/**"
includes:
  - es-query-builder
---

# Trace Search

Searches distributed tracing data stored in Elasticsearch. Delegates DSL construction to es-query-builder for structured query generation. Accepts trace ID, service name, operation name, duration range, and status code filters. Returns a trace waterfall view with span details including parent-child relationships, duration, service name, and tags. Supports searching by specific error tags or annotation values for root cause investigation.
