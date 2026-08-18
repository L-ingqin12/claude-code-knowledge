---
name: result-formatter
description: Format log query results as tables, JSON, or CSV with configurable output
namespace: logs/shared
paths: []
---

# Result Formatter

Formats structured query results into human-readable or machine-parseable output. Accepts a list of result records with field definitions. Supports three output modes: table (aligned columns with headers), JSON (pretty-printed with configurable indentation), and CSV (RFC 4180 compliant with header row). Can truncate long fields, highlight matching terms, and aggregate repeated values. Default output is table format with auto-sized columns.
