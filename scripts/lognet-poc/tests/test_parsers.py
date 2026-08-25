"""Parser unit tests — field extraction and malformed-line tolerance."""
from __future__ import annotations

import calendar
import unittest

from lognet_poc.parsers import hilog, kmsg


class TestHilog(unittest.TestCase):
    def test_valid_line(self):
        ev = hilog.parse_line("08-24 00:26:40.123  4321  5678 E Camsrv/Render: frame drop\n")
        self.assertIsNotNone(ev)
        self.assertEqual(ev["pid"], 4321)
        self.assertEqual(ev["tid"], 5678)
        self.assertEqual(ev["level"], "E")
        self.assertEqual(ev["tag"], "Camsrv")
        self.assertEqual(ev["meta"]["domain"], "Render")
        self.assertEqual(ev["payload"], "frame drop")
        # independent recomputation: 2025-08-24T00:26:40.123 UTC-naive
        expected = calendar.timegm((2025, 8, 24, 0, 26, 40, 0, 0, 0)) + 0.123
        self.assertAlmostEqual(ev["ts"], expected, places=3)

    def test_malformed_returns_none(self):
        self.assertIsNone(hilog.parse_line("this is not a hilog line\n"))
        self.assertIsNone(hilog.parse_line("\n"))
        self.assertIsNone(
            hilog.parse_line("08-24 00:26:40.123 abc def X BadTag: missing fields\n")
        )


class TestKmsg(unittest.TestCase):
    def test_valid_line(self):
        ev = kmsg.parse_line("<3>[   100.600000] BUG: watchdog timeout on cpu2\n")
        self.assertIsNotNone(ev)
        self.assertEqual(ev["pri"], 3)
        self.assertEqual(ev["level"], "E")
        self.assertAlmostEqual(ev["mono_secs"], 100.6, places=6)
        self.assertIn("watchdog", ev["payload"])

    def test_pri_level_mapping(self):
        self.assertEqual(kmsg.parse_line("<0>[ 1.0] x")["level"], "F")
        self.assertEqual(kmsg.parse_line("<6>[ 1.0] x")["level"], "I")
        self.assertEqual(kmsg.parse_line("<7>[ 1.0] x")["level"], "D")

    def test_malformed_returns_none(self):
        self.assertIsNone(kmsg.parse_line("[100.6] missing pri\n"))
        self.assertIsNone(kmsg.parse_line("plain text\n"))


if __name__ == "__main__":
    unittest.main()
