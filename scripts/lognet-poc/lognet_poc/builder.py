"""LogNet SQLite builder (design doc §四 图模型 / §四.2 存储选型).

One log package -> one <pkg>/lognet.db single-file database:
nodes/edges/entities tables + FTS5 inverted index + b-tree ts index.
WAL mode; batched executemany; explicit ids assigned in Python so edge
construction is deterministic without round-trips.
"""
from __future__ import annotations

import json
import os
import sqlite3

from . import graph
from .dedup import Folder
from .registry import get_parser, identify

BATCH = 10_000

SCHEMA = """
CREATE TABLE IF NOT EXISTS nodes(
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,            -- event | entity-anchor | signal (entity rows live in `entities`)
  ts REAL,
  source TEXT,
  pid INTEGER,
  tid INTEGER,
  tag TEXT,
  level TEXT,
  payload TEXT,
  payload_hash TEXT,
  raw_offset INTEGER,
  count INTEGER DEFAULT 1,
  first_ts REAL, last_ts REAL
);
CREATE TABLE IF NOT EXISTS entities(
  id INTEGER PRIMARY KEY,
  name TEXT UNIQUE,
  etype TEXT                     -- process | module | driver
);
CREATE TABLE IF NOT EXISTS node_entities(
  node_id INTEGER, entity_id INTEGER, PRIMARY KEY(node_id, entity_id)
);
CREATE TABLE IF NOT EXISTS edges(
  src INTEGER, dst INTEGER, etype TEXT, weight REAL
);
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
"""


def verify_fts5(conn: sqlite3.Connection) -> None:
    try:
        conn.execute("CREATE VIRTUAL TABLE temp.fts5_probe USING fts5(x)")
        conn.execute("DROP TABLE temp.fts5_probe")
    except sqlite3.Error as exc:  # pragma: no cover - environment guard
        raise RuntimeError(
            "sqlite3 build lacks FTS5 - required for LogNet PoC"
        ) from exc


class LogNetBuilder:
    def __init__(self, db_path: str) -> None:
        self.db_path = db_path
        os.makedirs(os.path.dirname(os.path.abspath(db_path)) or ".", exist_ok=True)
        self.conn = sqlite3.connect(db_path)
        self.conn.execute("PRAGMA journal_mode=WAL")
        # Derived, rebuildable artifact: relax durability for bulk-load throughput
        # (escape hatch: delete lognet.db and rebuild from raw logs anytime).
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.executescript(SCHEMA)
        verify_fts5(self.conn)
        self.conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(payload, tag, source)"
        )
        self._next_id = 1
        self._node_buf: list[tuple] = []
        self._fts_buf: list[tuple] = []
        self.stats = {"files": {}, "skipped_lines": 0, "unknown_files": []}

    # ---- ingestion -----------------------------------------------------
    def ingest_package(self, pkg_dir: str) -> dict:
        """Stream-parse every recognized file in pkg_dir (read-only)."""
        manifest = {}
        mf = os.path.join(pkg_dir, "manifest.json")
        if os.path.exists(mf):
            with open(mf, "r", encoding="utf-8") as fh:
                manifest = json.load(fh)
        boot_offset = float(manifest.get("boot_offset_epoch", 0.0))
        year = int(manifest.get("log_year", 2025))
        self.conn.executemany(
            "INSERT INTO meta(k,v) VALUES(?,?)",
            [("boot_offset_epoch", str(boot_offset)), ("pkg_dir", pkg_dir)],
        )
        for fname in sorted(os.listdir(pkg_dir)):
            path = os.path.join(pkg_dir, fname)
            if not os.path.isfile(path) or fname == "manifest.json":
                continue
            key = identify(fname)
            if key is None:
                self.stats["unknown_files"].append(fname)
                continue
            n_ev, n_folded = self._ingest_file(path, key, boot_offset=boot_offset, year=year)
            self.stats["files"][fname] = {"parser": key, "events": n_ev, "folded_rows": n_folded}
        return self.stats

    def _ingest_file(self, path: str, key: str, *, boot_offset: float, year: int) -> tuple[int, int]:
        parser = get_parser(key)
        folder = Folder()
        n_ev = n_rows_file = 0

        def flush_row(row: dict) -> None:
            nonlocal n_rows_file
            self._add_row(row)
            n_rows_file += 1

        with open(path, "rb") as fh:
            offset = 0
            for raw in fh:
                line = raw.decode("utf-8", errors="replace")
                ev = parser(line, year) if key == "hilog" else parser(line)
                if ev is None:
                    if line.strip():
                        self.stats["skipped_lines"] += 1
                    offset += len(raw)
                    continue
                if key == "kmsg":
                    from . import clocksync

                    ev["ts"] = clocksync.kmsg_to_epoch(ev["mono_secs"], boot_offset)
                ev["raw_offset"] = offset
                closed = folder.add(ev)
                if closed:
                    flush_row(closed)
                offset += len(raw)
                n_ev += 1
        last = folder.flush()
        if last:
            flush_row(last)
        return n_ev, n_rows_file

    def _add_row(self, row: dict) -> None:
        nid = self._next_id
        self._next_id += 1
        self._node_buf.append(
            (
                nid,
                "event",
                row["first_ts"],
                row["source"],
                row["pid"],
                row["tid"],
                row["tag"],
                row["level"],
                row["payload"],
                row["phash"],
                row.get("raw_offset"),
                row["count"],
                row["first_ts"],
                row["last_ts"],
            )
        )
        self._fts_buf.append((nid, row["payload"] or "", row["tag"] or "", row["source"]))
        if len(self._node_buf) >= BATCH:
            self._flush_buffers()

    def _flush_buffers(self) -> None:
        if self._node_buf:
            self.conn.executemany(
                "INSERT INTO nodes(id,kind,ts,source,pid,tid,tag,level,payload,"
                "payload_hash,raw_offset,count,first_ts,last_ts) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                self._node_buf,
            )
            self.conn.executemany(
                "INSERT INTO events_fts(rowid,payload,tag,source) VALUES(?,?,?,?)",
                self._fts_buf,
            )
            self._node_buf.clear()
            self._fts_buf.clear()

    # ---- finalize ------------------------------------------------------
    def finish(self) -> sqlite3.Connection:
        self._flush_buffers()
        graph.build_all(self.conn)
        self.conn.executescript(
            """
            CREATE INDEX IF NOT EXISTS idx_nodes_ts ON nodes(ts);
            CREATE INDEX IF NOT EXISTS idx_nodes_src_pid ON nodes(source,pid,tid);
            CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src);
            CREATE INDEX IF NOT EXISTS idx_edges_dst_etype ON edges(dst,etype);
            CREATE INDEX IF NOT EXISTS idx_node_ent_ent ON node_entities(entity_id);
            """
        )
        self.conn.commit()
        return self.conn


def build_package(pkg_dir: str, db_path: str) -> tuple[LogNetBuilder, sqlite3.Connection]:
    b = LogNetBuilder(db_path)
    b.ingest_package(pkg_dir)
    conn = b.finish()
    return b, conn
