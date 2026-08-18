---
name: auth-checker
description: Role-based access control for log data with SRE, Developer, and Security role tiers
namespace: logs/shared
paths:
  - "**/auth/**"
---

# Auth Checker

Enforces role-based access control on log search operations. Defines three role tiers: SRE (full access to all logs, alerts, and infrastructure data), Developer (application logs and traces, limited infrastructure), and Security (audit logs, auth logs, security events only). Accepts a role identifier and resource path, returning a boolean allow/deny decision with the applicable permission scope. For denied requests, returns which specific permission is missing.
