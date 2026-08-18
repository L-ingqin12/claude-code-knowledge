---
name: monitor_dashboard
description: Dashboard setup guide
---

# Dashboard Setup Guide

Creating and configuring monitoring dashboards.

1. Access Grafana at https://grafana.internal.example.com
2. Create a new dashboard or duplicate an existing template
3. Add panels for: CPU, memory, request latency, error rate, throughput
4. Configure alert thresholds — consider reviewing alert_k8s_oom thresholds
5. Set up notification channels via slack_notify for critical alerts
6. Export dashboard JSON to version control following git_workflow conventions

Each service should have at least one dashboard with SLO burn-rate panel.
