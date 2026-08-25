"""Graph construction over loaded nodes (design doc §四.1 边类型 / §六 信号).

Edge kinds:
  temporal_next  consecutive folded rows within one source file
  same_entity    temporally adjacent members of one entity (pid/module/driver)
  causal_hint    signal -> nearest preceding warn/error events (R1)
  co_occurrence  hilog E/F burst anchor <-> kmsg signal within window (R2)

All rules deterministic and config-shaped (constants at top) so the agent
layer can later extend them without touching core code.
"""
from __future__ import annotations

import bisect
import math
import re
from collections import defaultdict

TEMPORAL_SQL = """
INSERT INTO edges(src,dst,etype,weight)
SELECT id, LEAD(id) OVER (PARTITION BY source ORDER BY id), 'temporal_next', 1.0
FROM nodes WHERE kind='event'
"""

SAME_ENTITY_MAX_GAP_S = 60.0

SIGNAL_RE = re.compile(r"(?i)(oops|panic|BUG:|call trace|watchdog)")
DRIVER_RE = re.compile(r"^([A-Za-z_][\w.\-]{1,31}):")

R1_BACKTRACK_S = 5.0
R1_MAX_PRECEDING = 3
R2_BURST_MIN = 5
R2_BURST_WINDOW_S = 2.0
R2_SIGNAL_WINDOW_S = 3.0
R2_WEIGHT = 0.5


def _ensure_entity(cur, cache: dict, name: str, etype: str) -> int:
    if name in cache:
        return cache[name]
    cur.execute("INSERT OR IGNORE INTO entities(name,etype) VALUES(?,?)", (name, etype))
    cur.execute("SELECT id FROM entities WHERE name=?", (name,))
    eid = cur.fetchone()[0]
    cache[name] = eid
    return eid


PAGE_SIZE = 50_000  # keyset-paging chunk to bound peak memory on huge packages


def _paged(cur, sql_base: str, params: tuple = ()):
    """Yield rows ordered by n.id in bounded pages (id-keyset pagination)."""
    last = 0
    while True:
        rows = cur.execute(
            sql_base + " AND n.id > ? ORDER BY n.id LIMIT ?",
            params + (last, PAGE_SIZE),
        ).fetchall()
        if not rows:
            return
        yield from rows
        last = rows[-1][0]


def _entities_and_same_entity(conn) -> None:
    rcur = conn.cursor()
    wcur = conn.cursor()
    ent_cache: dict[str, int] = {}
    member: dict[int, list[tuple[float, int]]] = defaultdict(list)
    sel = (
        "SELECT n.id,n.ts,n.source,n.pid,n.tid,n.tag,n.payload "
        "FROM nodes n WHERE n.kind='event'"
    )
    for nid, ts, source, pid, tid, tag, payload in _paged(rcur, sel):
        names: list[tuple[str, str]] = []
        if pid is not None:
            names.append((f"pid:{pid}", "process"))
        if source == "hilog" and tag:
            names.append((f"mod:{tag}", "module"))
        if source == "kmsg":
            m = DRIVER_RE.match(payload or "")
            if m:
                names.append((f"drv:{m.group(1)}", "driver"))
        for name, etype in names:
            eid = _ensure_entity(wcur, ent_cache, name, etype)
            wcur.execute(
                "INSERT OR IGNORE INTO node_entities(node_id,entity_id) VALUES(?,?)",
                (nid, eid),
            )
            member[eid].append((ts, nid))

    # same_entity edges: temporally adjacent members per entity (linear, not all-pairs)
    edge_rows: list[tuple[int, int, str, float]] = []
    for members in member.values():
        members.sort()
        for (t0, n0), (t1, n1) in zip(members, members[1:]):
            if t1 - t0 <= SAME_ENTITY_MAX_GAP_S:
                edge_rows.append((n0, n1, "same_entity", 1.0))
    wcur.executemany(
        "INSERT INTO edges(src,dst,etype,weight) VALUES(?,?,?,?)", edge_rows
    )


def _signals_r1(conn) -> list[tuple[float, int]]:
    """Crash-keyword signals + backward causal_hint edges. Returns [(ts, node_id)]."""
    rcur = conn.cursor()
    wcur = conn.cursor()

    # pass 1: warn/error kmsg events (light id/ts pairs, paged) for bisect backtracking
    err_rows: list[tuple[int, float]] = []
    for enid, ets in _paged(
        rcur,
        "SELECT n.id,n.ts FROM nodes n WHERE n.kind='event' AND n.source='kmsg' "
        "AND n.level IN ('W','E','F')",
    ):
        err_rows.append((enid, ets))
    err_rows.sort(key=lambda r: r[1])
    err_ts = [r[1] for r in err_rows]

    next_id = wcur.execute("SELECT COALESCE(MAX(id),0) FROM nodes").fetchone()[0]
    signals: list[tuple[float, int]] = []
    pending_nodes: list[tuple] = []
    pending_edges: list[tuple[int, int, str, float]] = []
    batch_signals: list[tuple[float, int]] = []

    def flush() -> None:
        if pending_nodes:
            wcur.executemany(
                "INSERT INTO nodes(id,kind,ts,source,pid,tid,tag,level,payload,"
                "payload_hash,raw_offset,count,first_ts,last_ts) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                pending_nodes,
            )
            # pair per-batch: global `signals` spans multiple flush windows
            wcur.executemany(
                "INSERT INTO events_fts(rowid,payload,tag,source) VALUES(?,?,?,?)",
                [(s[1], n[8], "", "kmsg") for s, n in zip(batch_signals, pending_nodes)],
            )
            pending_nodes.clear()
            batch_signals.clear()
        if pending_edges:
            wcur.executemany(
                "INSERT INTO edges(src,dst,etype,weight) VALUES(?,?,?,?)", pending_edges
            )
            pending_edges.clear()

    # pass 2: page through kmsg events, mint a signal per crash-keyword hit.
    # keyset filter is kind='event' so freshly minted signal rows are never re-read.
    sel = (
        "SELECT n.id,n.ts,n.payload FROM nodes n WHERE n.kind='event' "
        "AND n.source='kmsg'"
    )
    for nid, ts, payload in _paged(rcur, sel):
        if not SIGNAL_RE.search(payload or ""):
            continue
        next_id += 1
        sid = next_id
        pending_nodes.append(
            (
                sid,
                "signal",
                ts,
                "kmsg",
                None,
                None,
                None,
                "F",
                (payload or "")[:160],
                None,
                None,
                1,
                ts,
                ts,
            )
        )
        signals.append((ts, sid))
        batch_signals.append((ts, sid))
        lo = bisect.bisect_left(err_ts, ts - R1_BACKTRACK_S)
        hi = bisect.bisect_right(err_ts, ts)
        taken = 0
        # err_rows holds (id, ts) — mind the unpack order
        for enid, ets in reversed(err_rows[lo:hi]):
            if enid == nid or taken >= R1_MAX_PRECEDING:
                continue
            pending_edges.append(
                (
                    sid,
                    enid,
                    "causal_hint",
                    round(math.exp(-abs(ts - ets) / 2.0), 4),
                )
            )
            taken += 1
        if len(pending_nodes) >= PAGE_SIZE:
            flush()
    flush()
    return signals


def _bursts_r2(conn, kmsg_signals: list[tuple[float, int]]) -> None:
    """hilog E/F bursts (same pid, >=N events within window) <-> nearby signals."""
    rcur = conn.cursor()
    wcur = conn.cursor()
    by_pid: dict[object, list[tuple[float, int]]] = defaultdict(list)
    sel = (
        "SELECT n.id,n.ts,n.pid FROM nodes n WHERE n.kind='event' "
        "AND n.source='hilog' AND n.level IN ('E','F')"
    )
    for nid, ts, pid in _paged(rcur, sel):
        by_pid[pid].append((ts, nid))

    sig_by_ts: dict[float, int] = {ts: nid for ts, nid in kmsg_signals}
    sig_ts = sorted(sig_by_ts)

    edges: list[tuple[int, int, str, float]] = []
    for events in by_pid.values():
        i = 0
        anchored_any = False
        while i < len(events):
            j = i
            while j < len(events) and events[j][0] - events[i][0] <= R2_BURST_WINDOW_S:
                j += 1
            if j - i >= R2_BURST_MIN and not anchored_any:
                anchor_nid, anchor_ts = events[i][1], events[i][0]
                lo = bisect.bisect_left(sig_ts, anchor_ts - R2_SIGNAL_WINDOW_S)
                hi = bisect.bisect_right(sig_ts, anchor_ts + R2_SIGNAL_WINDOW_S)
                for st in sig_ts[lo:hi]:
                    edges.append(
                        (anchor_nid, sig_by_ts[st], "co_occurrence", R2_WEIGHT)
                    )
                anchored_any = True  # one anchor per pid run is enough for PoC
            i += 1
    if edges:
        wcur.executemany("INSERT INTO edges(src,dst,etype,weight) VALUES(?,?,?,?)", edges)


def build_all(conn) -> None:
    cur = conn.cursor()
    cur.execute(TEMPORAL_SQL)
    _entities_and_same_entity(conn)
    signals = _signals_r1(conn)
    _bursts_r2(conn, signals)
    conn.commit()
