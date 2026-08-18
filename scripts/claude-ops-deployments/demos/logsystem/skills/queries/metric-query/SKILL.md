---
name: metric-query
description: Query time-series metrics from ClickHouse with time range and formatting
namespace: logs/queries
paths:
  - "**/metrics/**"
includes:
  - time-range-parser
  - result-formatter
---

# Metric Query

Queries time-series metric data stored in ClickHouse. Uses time-range-parser to resolve the query time window and result-formatter for output presentation. Accepts metric name, aggregation function (avg, p50, p95, p99, max, count), group-by labels, and granularity. Returns time-series data points with timestamps and values. Supports downsampling, rate calculation, and percentile approximations using ClickHouse aggregate functions.
