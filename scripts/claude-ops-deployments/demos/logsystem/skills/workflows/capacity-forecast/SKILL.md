---
name: capacity-forecast
description: Forecast resource capacity needs based on slow query trends and usage metrics
namespace: logs/workflows
paths:
  - "**/capacity/**"
includes:
  - slow-query-search
  - result-formatter
---

# Capacity Forecast

Analyzes historical slow query and resource usage data to forecast future capacity needs. Uses slow-query-search to gather query performance trends and result-formatter to present the forecast. Accepts service or database name, forecast horizon (7/30/90 days), growth model (linear, exponential), and current resource allocation. Returns projected resource exhaustion date, recommended capacity increments, cost estimates for each upgrade option, and confidence intervals for the forecast.
