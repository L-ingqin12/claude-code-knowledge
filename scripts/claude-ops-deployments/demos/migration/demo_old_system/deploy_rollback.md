---
name: deploy_rollback
description: Deployment rollback procedure
---

# Deployment Rollback Procedure

Use this when a deployment causes production issues.

1. Identify the previous stable revision: `kubectl rollout history deployment/<name>`
2. Rollback: `kubectl rollout undo deployment/<name> --to-revision=<N>`
3. Verify the rollback: `kubectl rollout status deployment/<name>`
4. If the rollback itself fails, re-apply the last known good manifest (consider using k8s_apply)
5. If the issue was a bad Docker image, rebuild with docker_build and push the fixed version
6. Send a post-mortem notification via slack_notify

Document the root cause and attach to the incident.
