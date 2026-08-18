---
name: rca-pipeline
description: Multi-step root cause analysis combining error search, trace search, and spike detection
namespace: logs/workflows
paths:
  - "**/incidents/**"
  - "**/postmortems/**"
includes:
  - error-search
  - trace-search
  - spike-detection
optional_includes:
  - incident-report
conflicts:
  - alert-correlation
---

# Root Cause Analysis Pipeline

Orchestrates a comprehensive root cause analysis workflow combining multiple skill outputs. Runs error-search for recent failures, trace-search for distributed tracing context, and spike-detection for anomaly timing. Accepts incident ID, affected service, start time, and severity level. Produces a timeline of events, identifies the most likely root cause with supporting evidence, lists contributing factors, and provides a confidence score. Conflicting with alert-correlation ensures focused RCA rather than correlation analysis.
