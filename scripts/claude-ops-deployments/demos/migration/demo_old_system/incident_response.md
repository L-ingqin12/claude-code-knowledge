---
name: incident_response
description: Incident response workflow
---

# Incident Response Workflow

Follow this when a production incident is declared.

1. Acknowledge the alert — use slack_notify to announce that incident is being triaged
2. Assess severity (SEV1 = customer-facing outage, SEV2 = degraded experience)
3. For SEV1: immediately engage the on-call engineer and follow alert_k8s_oom if applicable
4. Attempt mitigation — if a recent deployment is the cause, execute deploy_rollback
5. Document the timeline and actions in the incident doc
6. After resolution, schedule a post-mortem within 48 hours

Remember: mitigate first, investigate second.
