---
name: sre-overview
description: SRE overview dashboard with optional metric queries and error rate alerts
namespace: logs/dashboards
paths:
  - "**/dashboards/**"
  - "**/grafana/**"
optional_includes:
  - metric-query
  - error-rate-alert
---

# SRE Overview Dashboard

Generates an SRE overview dashboard layout with key operational metrics. When metric-query is loaded, populates dashboard panels with live metric data including request rate, error rate, and latency percentiles. When error-rate-alert is loaded, adds alert status panels with current firing alerts and error budget burn rate. Accepts service name list, dashboard time range, and refresh interval. Returns a dashboard JSON definition compatible with Grafana, including panel layout, queries, and alert annotations.
