"""
AuditTrail — structured logging for the skill migration demo.

Creates a session directory per run, logs all decisions, and stores
artifacts (JSON reports, markdown docs) in a portable location.
"""

import datetime
import json
import os
import tempfile
import uuid
from typing import Any


class AuditTrail:
    """Create a timestamped audit session and log structured messages."""

    def __init__(self, session_id: str | None = None, base_dir: str | None = None):
        if session_id is None:
            session_id = datetime.datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:8]
        self.session_id = session_id
        self._base_dir = base_dir or os.path.join(tempfile.gettempdir(), f"skill-migration-{session_id}")
        os.makedirs(self._base_dir, exist_ok=True)
        self._log_path = os.path.join(self._base_dir, "audit.log")
        # Write header
        with open(self._log_path, "a") as f:
            f.write(f"# Audit Trail — Session {session_id}\n")
            f.write(f"# Started: {datetime.datetime.now().isoformat()}\n")
            f.write(f"# {'=' * 60}\n")

    @property
    def session_dir(self) -> str:
        return self._base_dir

    def log(self, message: str) -> None:
        """Write a timestamped log entry."""
        timestamp = datetime.datetime.now().isoformat(timespec="milliseconds")
        line = f"[{timestamp}] {message}\n"
        with open(self._log_path, "a") as f:
            f.write(line)
        print(f"  [audit] {message}")

    def store(self, filename: str, data: Any) -> str:
        """Write data (serialised to JSON if dict/list) into the session dir.

        Returns the absolute path of the stored file.
        """
        path = os.path.join(self._base_dir, filename)
        if isinstance(data, (dict, list)):
            with open(path, "w") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        else:
            with open(path, "w") as f:
                f.write(str(data))
        self.log(f"Stored artifact: {filename}")
        return path

    def summary(self) -> dict:
        """Return basic session metadata."""
        return {
            "session_id": self.session_id,
            "session_dir": self._base_dir,
            "log_path": self._log_path,
        }
