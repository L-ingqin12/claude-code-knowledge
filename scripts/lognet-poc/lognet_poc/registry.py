"""Parser registry (design doc §三 解析器注册表).

Config-driven: adding a new log type = one entry here (+ its parser module);
unknown files go to a reported "unknown bucket", never fatal.
"""
from __future__ import annotations

import re

from .parsers import hilog, kmsg

REGISTRY: dict[str, dict] = {
    "kmsg": {
        "filename_pattern": re.compile(r"(?:kmsg|kernel).*\.log$", re.IGNORECASE),
        "parser": kmsg.parse_line,
        "clock_domain": "monotonic",
    },
    "hilog": {
        "filename_pattern": re.compile(r"hilog.*\.log$", re.IGNORECASE),
        "parser": hilog.parse_line,
        "clock_domain": "wall",
    },
}


def identify(filename: str) -> str | None:
    """Return registry key for a filename, or None for the unknown bucket."""
    name = filename.rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    for key, spec in REGISTRY.items():
        if spec["filename_pattern"].search(name):
            return key
    return None


def get_parser(key: str):
    return REGISTRY[key]["parser"]
