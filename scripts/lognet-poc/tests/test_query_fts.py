"""query_logs tool tests — FTS hits, structured filters, folded totals."""
from __future__ import annotations

import unittest

from lognet_poc.query import query_logs

from .fixture import built
from .synth_gen import BOOT_OFFSET_EPOCH, BURST_N, BURST_PID, BURST_TAG, EXT4_TERM


class TestQueryFts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fx = built()
        cls.db = cls.fx["db"]

    def test_keyword_hits_planted_rows_with_refs(self):
        r = query_logs(self.db, keyword=EXT4_TERM)
        self.assertGreaterEqual(r["total"], 5)
        self.assertTrue(all(EXT4_TERM in it["snippet"] for it in r["items"]))
        self.assertEqual(len(r["refs"]), len(r["items"]))
        self.assertTrue(all(ref[1] == "kmsg" and ref[2] is not None for ref in r["refs"]))

    def test_keyword_finds_signal_nodes(self):
        r = query_logs(self.db, keyword="watchdog")
        self.assertGreaterEqual(r["total"], 1)
        kinds = {it["kind"] for it in r["items"]}
        self.assertIn("signal", kinds)

    def test_ts_window_excludes_fault_chain(self):
        r = query_logs(
            self.db,
            keyword=None,
            ts_from=BOOT_OFFSET_EPOCH + 101.0,
            ts_to=BOOT_OFFSET_EPOCH + 103.0,
        )
        self.assertGreater(r["total"], 0)
        self.assertFalse(any(EXT4_TERM in it["snippet"] for it in r["items"]))

    def test_structured_filters_pid_tag_level(self):
        r = query_logs(self.db, pid=BURST_PID, tag=BURST_TAG, level="E")
        self.assertEqual(r["total"], BURST_N)

    def test_total_reflects_folded_counts_vs_limit(self):
        r = query_logs(self.db, keyword="heartbeat", limit=5)
        self.assertGreater(r["total"], 5)          # folded rows exceed page
        self.assertLessEqual(len(r["items"]), 5)   # limit respected

    def test_combined_keyword_and_filter(self):
        r = query_logs(self.db, keyword=EXT4_TERM, level="E")
        self.assertEqual(r["total"], 5)


if __name__ == "__main__":
    unittest.main()
