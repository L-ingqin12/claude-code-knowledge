---
name: error-rate-alert
description: Evaluate error rate threshold violations using error logs and metrics
namespace: logs/alerts
paths:
  - "**/alerts/**"
includes:
  - error-search
  - metric-query
---

# Error Rate Alert

Evaluates error rate threshold violations by combining error log analysis with metric data. Uses error-search to gather recent error occurrences and metric-query to compute the actual error rate against the threshold. Accepts endpoint or service name, error rate threshold percentage, evaluation window, and severity level. Returns current error rate versus threshold, top error types with counts, trend direction (increasing/stable/decreasing), and whether the alert warrants escalation.
