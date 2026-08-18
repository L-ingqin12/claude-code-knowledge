---
name: container-log-search
description: Search container and pod logs using Loki LogQL with label-based filtering
namespace: logs/queries
paths:
  - "**/containers/**"
  - "**/pods/**"
includes:
  - loki-query-builder
---

# Container Log Search

Searches container stdout/stderr logs via Grafana Loki. Delegates LogQL construction to loki-query-builder. Accepts container name, pod name, namespace, and label selectors for stream filtering. Supports searching by log level, keyword, and time window. Returns log lines with container metadata, timestamp, and source stream (stdout/stderr). Handles Kubernetes pod lifecycle events and container restart detection for crash-loop investigation.
