"""kmsg (kernel ring buffer) line parser.

Expected shape:
    <PRI>[   secs.micros] message      PRI 0..7, monotonic clock domain
PRI -> level mapping: 0-2 F, 3 E, 4-5 W, 6 I, 7 D.
"""
from __future__ import annotations

import re

KMSG_RE = re.compile(r"^<(\d+)>\[\s*(\d+\.\d+)\]\s(.*)$")

PRI_LEVEL = {0: "F", 1: "F", 2: "F", 3: "E", 4: "W", 5: "W", 6: "I", 7: "D"}


def parse_line(line: str) -> dict | None:
    """Parse one kmsg line -> event dict (epoch ts filled later by caller), or None."""
    m = KMSG_RE.match(line.rstrip("\r\n"))
    if not m:
        return None
    pri_s, secs_s, payload = m.groups()
    pri = int(pri_s)
    return {
        "source": "kmsg",
        "mono_secs": float(secs_s),
        "pri": pri,
        "level": PRI_LEVEL.get(pri, "D"),
        "pid": None,
        "tid": None,
        "tag": None,
        "payload": payload,
        "meta": {},
    }
