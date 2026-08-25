"""Consecutive-duplicate folding (design doc §四.2 去重压缩).

Runs of consecutive events with identical
(source, pid, tid, tag, level, payload_hash)
collapse into ONE row carrying {count, first_ts, last_ts}.
Typical log repetition makes this an order-of-magnitude reduction.
"""
from __future__ import annotations

import hashlib


def payload_hash(payload: str) -> str:
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:16]


class Folder:
    """Streaming folder: feed events, collect folded rows via emit()/flush()."""

    def __init__(self) -> None:
        self._key = None
        self._acc: dict | None = None

    def add(self, ev: dict) -> dict | None:
        """Feed one raw event. Returns a folded row when the current run closes."""
        key = (
            ev["source"],
            ev.get("pid"),
            ev.get("tid"),
            ev.get("tag"),
            ev["level"],
            payload_hash(ev["payload"]),
        )
        closed = None
        if key != self._key:
            closed = self._close()
            self._key = key
            self._acc = {
                "source": ev["source"],
                "pid": ev.get("pid"),
                "tid": ev.get("tid"),
                "tag": ev.get("tag"),
                "level": ev["level"],
                "payload": ev["payload"],
                "phash": key[-1],
                "meta": ev.get("meta") or {},
                "count": 0,
            }
        self._acc["count"] += 1
        ts = ev["ts"]
        if "first_ts" not in self._acc:
            self._acc["first_ts"] = ts
            self._acc["raw_offset"] = ev.get("raw_offset")
        self._acc["last_ts"] = ts
        return closed

    def flush(self) -> dict | None:
        return self._close()

    def _close(self) -> dict | None:
        if self._acc is not None and self._acc["count"] > 0:
            row = self._acc
            self._acc = None
            return row
        return None
