---
name: spike-detection
description: Detect and analyze traffic or error rate spikes using Elasticsearch aggregations
namespace: logs/alerts
paths:
  - "**/alerts/**"
  - "**/monitoring/**"
includes:
  - es-query-builder
  - result-formatter
---

# Spike Detection

Detects and analyzes sudden traffic or error rate spikes using Elasticsearch date histogram aggregations. Uses es-query-builder for base query construction and result-formatter for presenting spike analysis. Accepts metric type (requests, errors, latency), baseline period, spike threshold multiplier, and granularity. Returns spike timing, magnitude relative to baseline, affected endpoints or services, and a breakdown of HTTP status codes or error types during the spike window.
