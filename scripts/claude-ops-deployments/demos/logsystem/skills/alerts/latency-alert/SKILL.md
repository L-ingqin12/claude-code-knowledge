---
name: latency-alert
description: Evaluate latency threshold violations using metric time-series data
namespace: logs/alerts
paths:
  - "**/alerts/**"
includes:
  - metric-query
---

# Latency Alert

Evaluates latency threshold violations by querying request duration metrics. Uses metric-query to retrieve p50, p95, and p99 latency values for the alerting period. Accepts endpoint or service name, latency threshold in milliseconds, percentile target, and evaluation window. Returns current latency percentiles versus thresholds, a comparison with the previous period, slowest endpoints, and a初步 bottleneck analysis identifying whether the issue is database, upstream service, or application logic related.
