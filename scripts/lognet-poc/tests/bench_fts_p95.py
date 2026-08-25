"""FTS keyword-query latency benchmark (PoC hypothesis-1 mechanism check).

Design-doc target: P95 < 100ms at ~5M rows (M0 acceptance, real-scale).
This bench validates the MECHANISM on the synthetic package (~tens of
thousands of folded rows); scale extrapolation is deliberately NOT claimed.
Hard CI guard: P95 < 500ms at this scale.

Usage:
  python tests/bench_fts_p95.py [--db path] [--pkg dir]
"""
from __future__ import annotations

import argparse
import os
import statistics
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lognet_poc.builder import build_package  # noqa: E402
from lognet_poc.query import query_logs  # noqa: E402

import synth_gen  # noqa: E402

TERMS = [
    "ext4_io_error",
    "watchdog",
    "status ok",
    "buffer fill",
    "frame drop",
    "heartbeat",
    "sched",
    "usb_storage",
]


def ensure_db(db_path: str | None, pkg_dir: str | None) -> tuple[str, str]:
    if db_path and os.path.exists(db_path):
        return db_path, pkg_dir or "(prebuilt)"
    root = tempfile.mkdtemp(prefix="lognet-bench-")
    pkg = pkg_dir or os.path.join(root, "pkg")
    db = db_path or os.path.join(root, "out", "lognet.db")
    if not os.path.isdir(pkg):
        synth_gen.generate_package(pkg)
    t0 = time.perf_counter()
    _b, conn = build_package(pkg, db)
    conn.close()
    build_s = time.perf_counter() - t0
    print(f"built db in {build_s:.2f}s -> {db}")
    return db, pkg


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db")
    ap.add_argument("--pkg")
    args = ap.parse_args()

    db, pkg = ensure_db(args.db, args.pkg)
    conn = __import__("sqlite3").connect(db)
    folded = conn.execute("SELECT COUNT(*) FROM nodes WHERE kind='event'").fetchone()[0]
    total_raw = conn.execute("SELECT COALESCE(SUM(count),0) FROM nodes").fetchone()[0]
    conn.close()
    print(f"package: {pkg}")
    print(f"folded event rows: {folded}  (raw lines represented: {total_raw})")

    lat_ms: list[float] = []
    for i in range(200):
        kw = TERMS[i % len(TERMS)]
        t0 = time.perf_counter()
        query_logs(db, keyword=kw, limit=50)
        lat_ms.append((time.perf_counter() - t0) * 1000.0)

    srt = sorted(lat_ms)

    def pct(p: float) -> float:
        k = max(0, min(len(srt) - 1, int(round(p / 100.0 * (len(srt) - 1)))))
        return srt[k]

    p50 = pct(50)
    p95 = pct(95)
    print(f"queries: {len(lat_ms)}")
    print(f"P50 = {p50:.3f} ms")
    print(f"P95 = {p95:.3f} ms   (design target 100ms @5M rows; "
          f"CI guard here: <500ms @ {folded} rows)")
    ok = p95 < 500.0
    print("bench:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
