---
name: incident-report
description: Generate structured incident reports with formatted timeline and action items
namespace: logs/workflows
paths:
  - "**/incidents/**"
includes:
  - result-formatter
optional_includes:
  - slack-notify
---

# Incident Report Generation

Generates structured incident reports from investigation results. Uses result-formatter to produce consistent output sections. Accepts incident metadata (ID, severity, service, duration), a timeline of events, root cause summary, action items with owners, and affected metrics. Produces a formatted report suitable for postmortem documentation, with optional Slack notification when slack-notify is available. Output supports Markdown and HTML formats with severity-coded sections and auto-generated executive summary.
