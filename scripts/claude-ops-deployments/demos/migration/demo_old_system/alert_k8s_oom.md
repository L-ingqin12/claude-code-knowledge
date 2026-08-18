---
name: alert_k8s_oom
description: K8s OOM alert response runbook
---

# K8s OOM Alert Response

When a Kubernetes pod is terminated with OOMKilled:

1. Identify the offending pod: `kubectl get pods --field-selector=status.phase=Failed`
2. Check resource limits: `kubectl describe pod <name>` and look at resources.limits.memory
3. Determine if it's a code-level memory leak or simply insufficient limits
4. If limits are too low: update deployment YAML and apply with k8s_apply
5. Notify the team using slack_notify with the OOM details
6. For recurring OOMs, consider setting up monitor_dashboard alerts

Document all findings in the incident report.
