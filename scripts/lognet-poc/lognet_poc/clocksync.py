"""Clock-domain unification (design doc §四.2 时间线化, simplified for M0).

PoC convention (documented deviation): wall-clock logs (hilog) are interpreted as
UTC-naive via timegm so results are deterministic on any machine; production would
read device timezone metadata from the package manifest. kmsg monotonic seconds are
anchored through manifest.json {"boot_offset_epoch": float}.
"""
from __future__ import annotations

import calendar


def hilog_to_epoch(date_mmdd: str, time_hms_mmm: str, year: int = 2025) -> float:
    """'08-24' + '00:26:40.123' -> epoch seconds (UTC-naive convention)."""
    mon, day = (int(x) for x in date_mmdd.split("-"))
    hh, mm, rest = time_hms_mmm.split(":")
    sec = int(rest.split(".")[0])
    ms = int(rest.split(".")[1]) if "." in rest else 0
    return calendar.timegm((year, mon, day, int(hh), int(mm), sec, 0, 0, 0)) + ms / 1000.0


def kmsg_to_epoch(mono_secs: float, boot_offset_epoch: float) -> float:
    """Anchor kernel monotonic seconds onto the unified epoch timeline."""
    return boot_offset_epoch + mono_secs


def epoch_to_hilog_wall(ts: float) -> str:
    """Inverse helper used by the synthetic generator (UTC-naive convention)."""
    import time

    st = time.gmtime(int(ts))
    msec = int(round((ts - int(ts)) * 1000))
    if msec == 1000:  # rounding guard
        st = time.gmtime(int(ts) + 1)
        msec = 0
    return "%02d-%02d %02d:%02d:%02d.%03d" % (
        st.tm_mon,
        st.tm_mday,
        st.tm_hour,
        st.tm_min,
        st.tm_sec,
        msec,
    )
