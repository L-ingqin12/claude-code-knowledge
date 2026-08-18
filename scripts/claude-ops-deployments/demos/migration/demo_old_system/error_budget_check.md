---
name: error_budget_check
description: Error budget validation
---

# Error Budget Validation

Quarterly error budget review for SLO compliance.

1. Query the monitoring system for the current burn rate
2. Compare against the monthly error budget (99.9% target = 0.1% error budget)
3. If burn rate exceeds 150% of budget, trigger incident_response
4. Update the monitor_dashboard with current SLO attainment
5. Send a summary report via slack_notify to the engineering channel
6. If budget is exhausted, freeze all deploys until review

Record the SLO attainment in the ops log.
