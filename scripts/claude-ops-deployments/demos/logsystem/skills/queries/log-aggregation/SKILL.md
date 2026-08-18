---
name: log-aggregation
description: Aggregate and group log entries using Elasticsearch bucket aggregations
namespace: logs/queries
paths:
  - "**/aggregations/**"
includes:
  - es-query-builder
  - result-formatter
---

# Log Aggregation

Aggregates and groups log entries using Elasticsearch bucket and metric aggregations. Uses es-query-builder for base query construction and result-formatter for presenting aggregation results. Accepts aggregation field, bucket size, metric type (count, cardinality, percentiles), and optional sub-aggregation. Returns grouped results with bucket keys, document counts, and computed metrics. Supports date histogram, terms, range, and nested aggregation types for multi-dimensional log analysis.
