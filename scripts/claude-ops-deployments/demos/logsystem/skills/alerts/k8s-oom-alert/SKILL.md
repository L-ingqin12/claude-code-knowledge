---
name: k8s-oom-alert
description: Respond to Kubernetes OOMKilled pod alerts with error and slow query analysis
namespace: logs/alerts
paths:
  - "**/alerts/**"
  - "**/k8s/**"
includes:
  - error-search
  - slow-query-search
---

# K8s OOM Alert Response

Responds to Kubernetes OOMKilled (Out Of Memory) alerts by orchestrating a multi-step investigation. Uses error-search to find crash-loop related errors and slow-query-search to check for memory-intensive database queries preceding the OOM. Accepts pod name, namespace, container name, and timestamp. Returns a summary of found error patterns, memory usage trends, recent restart count, and recommended resource limit adjustments with suggested CPU/memory values.
