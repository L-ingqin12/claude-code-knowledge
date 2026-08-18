---
name: security-audit-search
description: Search security audit logs with access control enforcement
namespace: logs/queries
paths:
  - "**/audit/**"
  - "**/auth.log"
includes:
  - es-query-builder
  - auth-checker
---

# Security Audit Search

Searches security audit and authentication logs with RBAC enforcement. Uses es-query-builder for DSL construction and auth-checker to verify the requesting role has audit log permissions. Accepts event type (login, logout, permission change, access denied), user, source IP, and resource filters. Returns audit trail entries with timestamp, actor, action, target resource, result, and geo-location data. Redacts sensitive fields for non-Security roles.
