"""Deterministic synthetic log-package generator for PoC tests.

Produces a package dir (manifest.json + kernel.log + hilog_app.log) with a
PLANTED FAULT CHAIN so graph/causal behavior is assertable:

  kernel.log  (~100k kmsg lines)
    - filler info runs (8x identical consecutive -> dedup folding target)
    - t=100.0..100.4 step .1 : five `<3>` "ext4_io_error device sda sector N"
    - t=100.6                : one  `<3>` "BUG: watchdog timeout on cpu2"
  hilog_app.log (~200k hilog lines, UTC-naive wall clock = boot_offset + mono)
    - filler D/I with heavy 20x identical consecutive runs
    - planted E-burst: pid BURST_PID tag Camsrv/Render, 12 lines
      spanning boot+99.9 .. boot+100.8 (overlaps the kernel fault chain)

Seed fixed; byte-identical output across runs/machines.
"""
from __future__ import annotations

import json
import os

from lognet_poc import clocksync

BOOT_OFFSET_EPOCH = 1_756_000_000.0  # == 2025-08-24T00:26:40Z (UTC-naive convention)
EXT4_TERM = "ext4_io_error"
BUG_KW = "BUG:"
BURST_PID = 4321
BURST_TAG = "Camsrv"
BURST_DOMAIN = "Render"
BURST_N = 12
KRUN_N = 8          # identical-consecutive kmsg filler run length
HRUN_N = 20         # identical-consecutive hilog filler run length
K_LINES = 100_000
H_LINES = 200_000


def _kmsg_line(mono: float, pri: int, msg: str) -> str:
    return "<%d>[ %13.6f] %s" % (pri, mono, msg)


def _hilog_line(epoch: float, pid: int, tid: int, lvl: str, tag: str, dom: str, msg: str) -> str:
    wall = clocksync.epoch_to_hilog_wall(epoch)
    return "%s  %5d  %5d %s %s/%s: %s" % (wall, pid, tid, lvl, tag, dom, msg)


def generate_package(out_dir: str) -> dict:
    """Write the package; returns expected-anchor facts for assertions."""
    os.makedirs(out_dir, exist_ok=True)

    # ---- manifest ----
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"boot_offset_epoch": BOOT_OFFSET_EPOCH, "log_year": 2025}, f)

    # ---- kernel.log ----
    kpath = os.path.join(out_dir, "kernel.log")
    with open(kpath, "w", encoding="utf-8", newline="\n") as f:
        t = 0.0
        step = 70_000.0 / K_LINES  # ~70 s of monotonic timeline
        i = 0
        while i < K_LINES:
            in_run = (i % 1000) < KRUN_N and i >= KRUN_N
            if in_run:
                msg, pri = "usb_storage: status ok", 6
            else:
                msg, pri = "sched: tick ok #%d" % i, 6
                if i % 977 == 0:
                    pri, msg = 7, "debug noise line %d" % i
            f.write(_kmsg_line(t, pri, msg) + "\n")
            t += step
            i += 1
        # planted ext4 errors (distinct payloads -> stay unfolded)
        for j in range(5):
            f.write(
                _kmsg_line(100.0 + 0.1 * j, 3, "%s device sda sector %d" % (EXT4_TERM, 1000 + j))
                + "\n"
            )
        f.write(_kmsg_line(100.6, 3, "%s watchdog timeout on cpu2" % BUG_KW) + "\n")

    # ---- hilog_app.log ----
    hpath = os.path.join(out_dir, "hilog_app.log")
    tags = [("AudioSvc", "Play"), ("PowerMgr", "Suspend"), ("NetMgr", "Tcp")]
    with open(hpath, "w", encoding="utf-8", newline="\n") as f:
        t = 90.0
        step = 10.0 / H_LINES  # ~10 s span covering the fault window
        i = 0
        while i < H_LINES:
            in_run = (i % 500) < HRUN_N
            tag_i = (i // 500) % 3  # constant per 500-line block so runs fold
            tag, dom = tags[tag_i]
            pid = 1000 + tag_i
            if in_run:
                lvl, msg = "D", "%s buffer fill ok" % tag
            elif i % 1999 == 0:
                lvl, msg = "W", "%s retrying op" % tag
            else:
                lvl, msg = "I", "%s heartbeat #%d" % (tag, i)
            f.write(_hilog_line(BOOT_OFFSET_EPOCH + t, pid, pid * 10, lvl, tag, dom, msg) + "\n")
            t += step
            i += 1
        # planted E-burst from camera service overlapping the kernel chain
        base = BOOT_OFFSET_EPOCH + 99.9
        span = 0.9
        for j in range(BURST_N):
            ts = base + span * j / (BURST_N - 1)
            f.write(
                _hilog_line(ts, BURST_PID, BURST_PID, "E", BURST_TAG, BURST_DOMAIN,
                            "frame drop detected seq %d" % j)
                + "\n"
            )

    return {
        "boot_offset_epoch": BOOT_OFFSET_EPOCH,
        "ext4_term": EXT4_TERM,
        "bug_kw": BUG_KW,
        "burst_pid": BURST_PID,
        "burst_n": BURST_N,
        "krun_n": KRUN_N,
        "hrun_n": HRUN_N,
    }


if __name__ == "__main__":
    import sys

    dest = sys.argv[1] if len(sys.argv) > 1 else "synth-pkg"
    facts = generate_package(dest)
    print("generated:", dest)
    print("anchors:", json.dumps(facts))
