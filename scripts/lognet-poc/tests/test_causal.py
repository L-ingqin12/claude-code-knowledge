"""Causal-rule tests — R1 causal_hint edges, R2 co_occurrence edges."""
from __future__ import annotations

import sqlite3
import unittest

from .fixture import built
from .synth_gen import BURST_PID


class TestCausal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fx = built()

    def test_r1_watchdog_signal_points_back_at_ext4_errors(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            n = conn.execute(
                """
                SELECT COUNT(*) FROM edges e
                JOIN nodes s ON s.id = e.src
                JOIN nodes d ON d.id = e.dst
                WHERE e.etype='causal_hint'
                  AND s.kind='signal' AND s.payload LIKE '%watchdog%'
                  AND d.payload LIKE '%ext4_io_error%'
                """
            ).fetchone()[0]
        finally:
            conn.close()
        # watchdog at t=100.6; ext4 errors within 5s backtrack -> linked
        self.assertGreaterEqual(n, 1)

    def test_r1_backtrack_respects_time_window(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            bad = conn.execute(
                """
                SELECT COUNT(*) FROM edges e
                JOIN nodes s ON s.id = e.src
                JOIN nodes d ON d.id = e.dst
                WHERE e.etype='causal_hint' AND ABS(s.ts - d.ts) > 5.0
                """
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(bad, 0)

    def test_r2_burst_anchor_co_occurs_with_signal(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            n = conn.execute(
                """
                SELECT COUNT(*) FROM edges e
                JOIN nodes d ON d.id = e.dst
                WHERE e.etype='co_occurrence'
                  AND e.weight = 0.5
                  AND e.src IN (SELECT id FROM nodes WHERE pid=?)
                  AND d.kind='signal'
                """,
                (BURST_PID,),
            ).fetchone()[0]
        finally:
            conn.close()
        self.assertGreaterEqual(n, 1)

    def test_same_entity_edges_exist_across_sources(self):
        conn = sqlite3.connect(self.fx["db"])
        try:
            n = conn.execute(
                "SELECT COUNT(*) FROM edges WHERE etype='same_entity'"
            ).fetchone()[0]
            m = conn.execute("SELECT COUNT(*) FROM entities").fetchone()[0]
        finally:
            conn.close()
        self.assertGreater(n, 100)
        self.assertGreater(m, 3)


if __name__ == "__main__":
    unittest.main()
