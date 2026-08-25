"""query_logs — bounded structured retrieval tool (design doc §七 工具面).

Returns hit counts + TopN summaries + reference pointers (db,source,raw_offset)
so the agent layer NEVER needs bulk raw log text in context.
"""
from __future__ import annotations

import sqlite3

_COLS = (
    "n.id,n.kind,n.ts,n.source,n.pid,n.tid,n.tag,n.level,n.count,"
    "n.raw_offset,substr(n.payload,1,160)"
)


def _fts_phrase(keyword: str) -> str:
    """Escape user keyword into a single quoted FTS5 phrase."""
    return '"%s"' % keyword.replace('"', '""')


def _filters(
    ts_from: float | None,
    ts_to: float | None,
    pid: int | None,
    tid: int | None,
    tag: str | None,
    level: str | None,
) -> tuple[str, list]:
    clauses: list[str] = []
    params: list = []
    if ts_from is not None:
        clauses.append("n.ts >= ?")
        params.append(float(ts_from))
    if ts_to is not None:
        clauses.append("n.ts <= ?")
        params.append(float(ts_to))
    for col, val in (("pid", pid), ("tid", tid)):
        if val is not None:
            clauses.append(f"n.{col} = ?")
            params.append(int(val))
    if tag:
        clauses.append("n.tag = ?")
        params.append(tag)
    if level:
        clauses.append("n.level = ?")
        params.append(level)
    return (" AND ".join(clauses), params)


def query_logs(
    db_path: str,
    keyword: str | None = None,
    *,
    ts_from: float | None = None,
    ts_to: float | None = None,
    pid: int | None = None,
    tid: int | None = None,
    tag: str | None = None,
    level: str | None = None,
    limit: int = 50,
) -> dict:
    conn = sqlite3.connect(db_path)
    try:
        cond, params = _filters(ts_from, ts_to, pid, tid, tag, level)
        if keyword:
            join = " JOIN events_fts f ON f.rowid = n.id"
            conds = ([cond] if cond else []) + ["events_fts MATCH ?"]
            where_sql = " WHERE " + " AND ".join(conds)
            qparams = params + [_fts_phrase(keyword)]
        else:
            join = ""
            where_sql = (" WHERE " + cond) if cond else ""
            qparams = list(params)

        base = f" FROM nodes n{join}{where_sql}"
        total = conn.execute("SELECT COUNT(*)" + base, qparams).fetchone()[0]
        rows = conn.execute(
            "SELECT " + _COLS + base + " ORDER BY n.ts LIMIT ?",
            qparams + [int(limit)],
        ).fetchall()
    finally:
        conn.close()

    items = [
        {
            "id": r[0],
            "kind": r[1],
            "ts": r[2],
            "source": r[3],
            "pid": r[4],
            "tid": r[5],
            "tag": r[6],
            "level": r[7],
            "count": r[8],
            "raw_offset": r[9],
            "snippet": r[10],
        }
        for r in rows
    ]
    return {
        "total": total,
        "items": items,
        "refs": [(it["id"], it["source"], it["raw_offset"]) for it in items],
    }
