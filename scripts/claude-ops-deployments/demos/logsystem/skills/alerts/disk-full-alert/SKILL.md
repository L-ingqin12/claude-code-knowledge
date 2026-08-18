---
name: disk-full-alert
description: Respond to disk full alerts by analyzing container logs for space consumption
namespace: logs/alerts
paths:
  - "**/alerts/**"
includes:
  - container-log-search
---

# Disk Full Alert Response

Responds to disk space exhaustion alerts by investigating container log output for space-related errors. Uses container-log-search to find log entries from affected hosts about disk write failures, log rotation messages, or cleanup operations. Accepts hostname, mount point, filesystem type, and disk usage percentage. Returns log evidence of space-filling processes, log rotation status, recent cleanup operations, and recommended recovery steps including temporary log truncation or partition expansion.
