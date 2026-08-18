---
name: error-budget
description: Error budget dashboard tracking SLO compliance with metric queries and formatted output
namespace: logs/dashboards
paths:
  - "**/dashboards/**"
  - "**/slo/**"
includes:
  - metric-query
  - result-formatter
---

# Error Budget Dashboard

Generates an error budget tracking dashboard for SLO compliance monitoring. Uses metric-query to retrieve service-level indicator data and result-formatter to present budget status. Accepts SLO targets (e.g. 99.9% availability), service name, budget window (30/90 days), and burn rate alert thresholds. Returns a dashboard with current error budget remaining, burn rate (fast/slow), projected budget exhaustion date, and historical SLO attainment. Includes panel configurations for Grafana with time-series and gauge visualizations.
