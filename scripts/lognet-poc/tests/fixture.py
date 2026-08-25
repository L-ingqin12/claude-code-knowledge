"""Shared one-shot fixture: generate synthetic package + build db once."""
from __future__ import annotations

import os
import tempfile

from lognet_poc.builder import build_package

from . import synth_gen

_CACHE: dict | None = None


def built() -> dict:
    global _CACHE
    if _CACHE is None:
        root = tempfile.mkdtemp(prefix="lognet-poc-fixture-")
        pkg = os.path.join(root, "pkg")
        db = os.path.join(root, "out", "lognet.db")
        facts = synth_gen.generate_package(pkg)
        builder, conn = build_package(pkg, db)
        conn.close()
        _CACHE = {
            "root": root,
            "pkg": pkg,
            "db": db,
            "facts": facts,
            "stats": builder.stats,
        }
    return _CACHE
