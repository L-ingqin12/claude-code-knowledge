"""get_subgraph tests — reachability, window pruning, budget truncation."""
from __future__ import annotations

import unittest

from lognet_poc.query import query_logs
from lognet_poc.subgraph import get_subgraph

from .fixture import built
from .synth_gen import EXT4_TERM


def _watchdog_signal_id(db: str) -> int:
    r = query_logs(db, keyword="watchdog")
    for it in r["items"]:
        if it["kind"] == "signal":
            return it["id"]
    raise AssertionError("no watchdog signal node found")


class TestSubgraph(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fx = built()
        cls.db = cls.fx["db"]

    def test_fault_chain_reachable_within_depth_and_window(self):
        sid = _watchdog_signal_id(self.db)
        sg = get_subgraph(self.db, sid, depth=2, window_s=5.0, budget_tokens=8000)
        summaries = [n["summary"] for n in sg["nodes"]]
        self.assertTrue(any(EXT4_TERM in s for s in summaries))
        self.assertFalse(sg["truncated"])
        self.assertGreaterEqual(len(sg["nodes"]), 5)
        etypes = {e["etype"] for e in sg["edges"]}
        self.assertIn("causal_hint", etypes)

    def test_tiny_budget_truncates_immediately(self):
        sid = _watchdog_signal_id(self.db)
        sg = get_subgraph(self.db, sid, depth=2, window_s=5.0, budget_tokens=60)
        self.assertTrue(sg["truncated"])
        self.assertLessEqual(len(sg["nodes"]), 2)

    def test_narrow_window_prunes_causal_neighbors(self):
        sid = _watchdog_signal_id(self.db)
        sg = get_subgraph(self.db, sid, depth=3, window_s=0.05, budget_tokens=80000)
        summaries = [n["summary"] for n in sg["nodes"]]
        self.assertFalse(any(EXT4_TERM in s for s in summaries))

    def test_unknown_node_raises(self):
        with self.assertRaises(ValueError):
            get_subgraph(self.db, 999_999_999)


if __name__ == "__main__":
    unittest.main()
