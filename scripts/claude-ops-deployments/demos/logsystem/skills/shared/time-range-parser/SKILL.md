---
name: time-range-parser
description: Parse relative time expressions like "last hour", "yesterday", "last 7 days" into absolute timestamps
namespace: logs/shared
paths: []
---

# Time Range Parser

Converts natural language time expressions into start/end timestamp pairs. Accepts expressions like "last 5 minutes", "yesterday", "this week", "last 30 days", "from 2024-01-01 to 2024-01-31". Supports relative offsets, calendar boundaries (start of day/week/month), and absolute date parsing. Returns ISO 8601 UTC timestamps and Unix epoch millisecond integers. Handles timezone-aware conversions when a timezone parameter is provided.
