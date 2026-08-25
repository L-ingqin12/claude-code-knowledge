"""hilog (application-domain log) line parser.

Expected shape (tolerant):
    MM-DD HH:MM:SS.mmm <pid> <tid> <L> <tag>/<domain>: <message>
Level L in {D,I,W,E,F}.
"""
from __future__ import annotations

import re

from .. import clocksync

HILOG_RE = re.compile(
    r"^(\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([DIWEF])\s+"
    r"([^/\s]+)/([^:\s]+):\s(.*)$"
)

DEFAULT_YEAR = 2025


def parse_line(line: str, year: int = DEFAULT_YEAR) -> dict | None:
    """Parse one hilog line -> event dict, or None when malformed."""
    m = HILOG_RE.match(line.rstrip("\r\n"))
    if not m:
        return None
    date_s, time_s, pid, tid, level, tag, domain, payload = m.groups()
    return {
        "source": "hilog",
        "ts": clocksync.hilog_to_epoch(date_s, time_s, year),
        "pid": int(pid),
        "tid": int(tid),
        "level": level,
        "tag": tag,
        "payload": payload,
        "meta": {"domain": domain},
    }
