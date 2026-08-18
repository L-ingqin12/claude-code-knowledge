---
name: alert-correlation
description: Correlate multiple alerts to identify common root causes and alert storms
namespace: logs/workflows
paths:
  - "**/alerts/**"
  - "**/correlation/**"
includes:
  - spike-detection
  - k8s-oom-alert
conflicts:
  - rca-pipeline
---

# Alert Correlation

Correlates multiple simultaneous or near-simultaneous alerts to identify common root causes and alert storms. Uses spike-detection to find temporal clustering and k8s-oom-alert to evaluate pod-level issues. Accepts a list of alert IDs, time window for correlation, and minimum correlation threshold. Returns correlation groups with parent-child relationships, the most probable common cause, a timeline of alert propagation, and recommendations for alert deduplication or aggregation rules. Conflicting with rca-pipeline prevents duplicate analysis.
