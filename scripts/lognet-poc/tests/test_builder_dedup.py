"""Builder + dedup folding + storage-layer tests."""
from __future__ import annotations

import os
import sqlite3
import unittest

from .fixture import built
from .synth_gen import EXT4_TERM, HRUN_N, KRUN_N


class TestBuilderDedup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fx = built()

    def test_registry_coverage_and_unknown_bucket(self):
        st = self.fx["stats"]
        self.assertIn("kernel.log", st["files"])
        self.assertIn("hilog_app.log", st["files"])
        self.assertEqual(st["files"]["kernel.log"]["parser"], "kmsg")
        self.assertEqual(st["files"]["hilog_app.log"]["parser"], "hilog")
        self.assertEqual(st["unknown_files"], [])
        self.assertEqual(st["skipped_lines"], 0)

    def test_fts5_table_exists(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            names = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
        finally:
            conn.close()
        self.assertIn("events_fts", names)
        self.assertIn("nodes", names)
        self.assertIn("edges", names)
        self.assertIn("entities", names)

    def test_consecutive_kmsg_filler_folds_to_runs(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            n_rows, total = conn.execute(
                "SELECT COUNT(*), COALESCE(SUM(count),0) FROM nodes "
                "WHERE source='kmsg' AND payload LIKE 'usb_storage%'"
            ).fetchone()
        finally:
            conn.close()
        # 100k lines / 1000-line period -> 99 runs of KRUN_N identical lines
        self.assertEqual(n_rows, 99)
        self.assertEqual(total, 99 * KRUN_N)

    def test_consecutive_hilog_filler_folds_to_runs(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            n_rows, total = conn.execute(
                "SELECT COUNT(*), COALESCE(SUM(count),0) FROM nodes "
                "WHERE source='hilog' AND payload LIKE '%buffer fill ok'"
            ).fetchone()
        finally:
            conn.close()
        # 200k lines / 500-line period -> exactly 400 runs of HRUN_N identical
        self.assertEqual(n_rows, 400)
        self.assertEqual(total, 400 * HRUN_N)

    def test_hilog_package_overall_folding_ratio(self):
        st = self.fx["stats"]["files"]["hilog_app.log"]
        self.assertLess(
            st["folded_rows"], st["events"], "folding must reduce row count"
        )

    def test_planted_events_survive_distinct(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            n_ext4 = conn.execute(
                "SELECT COUNT(*) FROM nodes WHERE payload LIKE ?",
                ("%" + EXT4_TERM + "%",),
            ).fetchone()[0]
            n_bug = conn.execute(
                "SELECT COUNT(*) FROM nodes WHERE kind='event' "
                "AND payload LIKE '%BUG: watchdog%'"
            ).fetchone()[0]
            n_sig = conn.execute(
                "SELECT COUNT(*) FROM nodes WHERE kind='signal'"
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(n_ext4, 5)
        self.assertEqual(n_bug, 1)
        self.assertGreaterEqual(n_sig, 1)

    def test_temporal_next_edges_built(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            n = conn.execute(
                "SELECT COUNT(*) FROM edges WHERE etype='temporal_next'"
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertGreater(n, 10_000)

    def test_raw_offset_roundtrip_into_original_file(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            row = conn.execute(
                "SELECT raw_offset,payload FROM nodes "
                "WHERE payload LIKE ? LIMIT 1",
                ("%" + EXT4_TERM + "%",),
            ).fetchone()
        finally:
            conn.close()
        self.assertIsNotNone(row)
        offset, payload = row
        with open(os.path.join(self.fx["pkg"], "kernel.log"), "rb") as fh:
            fh.seek(offset)
            line = fh.readline().decode("utf-8")
        self.assertIn(payload.split(" ")[0], line)
        self.assertIn(payload, line)


if __name__ == "__main__":
    unittest.main()
