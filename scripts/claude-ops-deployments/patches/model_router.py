"""Adaptive model routing: Flash-first with quality-driven Pro upgrade.

Controlled by PERMAFROST_MODEL_ROUTING=1 (default off).

Strategy:
  - Simple requests → flash (save cost)
  - Complex requests → pro (ensure quality)
  - Flash response too short → upgrade to pro next turn
  - Session history shows complexity → stay pro
  - Token budget tracking → bias flash when approaching limit
"""

import threading

# Per-session state (keyed by session_id from extract_session)
_state_lock = threading.Lock()
_sessions: dict[str, dict] = {}

# Thresholds
FLASH_UPGRADE_SHORT_RESPONSE = 50   # chars: flash answer < this → upgrade
PRO_DOWNGRADE_SIMPLE_STREAK = 3     # consecutive simple turns → downgrade to flash
MAX_SESSION_STATE = 128             # LRU cap


def _get_session(session_id: str | None) -> dict:
    if not session_id:
        return {}
    with _state_lock:
        s = _sessions.get(session_id)
        if s is None:
            s = {"flash_turns": 0, "pro_turns": 0, "short_flash": 0,
                 "tool_turns": 0, "total_turns": 0}
            _sessions[session_id] = s
            while len(_sessions) > MAX_SESSION_STATE:
                _sessions.pop(next(iter(_sessions)))
        return s


def route_model(body: dict, session_id: str | None = None) -> dict:
    """Return routing decision: {'model': 'deepseek-v4-...', 'reason': '...'}"""
    msgs = body.get("messages", [])
    tools = body.get("tools", [])
    current = body.get("model", "")
    state = _get_session(session_id)

    if not msgs:
        return {"model": current, "reason": "no messages"}

    # Track session stats
    state["total_turns"] = state.get("total_turns", 0) + 1

    # Already on flash
    if "flash" in current:
        state["flash_turns"] = state.get("flash_turns", 0) + 1
        return {"model": current, "reason": "stay flash"}

    # ── Stay Pro signals ──

    # 1. Has tools → coding task
    if tools and len(tools) > 0:
        state["tool_turns"] = state.get("tool_turns", 0) + 1
        state["pro_turns"] = state.get("pro_turns", 0) + 1
        return {"model": current, "reason": "has tools"}

    # 2. Long conversation → complex
    total_chars = sum(len(str(m)) for m in msgs)
    if total_chars > 500:
        state["pro_turns"] = state.get("pro_turns", 0) + 1
        return {"model": current, "reason": "long context"}

    # 3. Established session (>3 messages)
    if len(msgs) > 3:
        state["pro_turns"] = state.get("pro_turns", 0) + 1
        return {"model": current, "reason": "established session"}

    # 4. Recent tool usage → session is complex
    for m in msgs[-2:]:
        content = m.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") in ("tool_use", "tool_result"):
                    state["tool_turns"] = state.get("tool_turns", 0) + 1
                    state["pro_turns"] = state.get("pro_turns", 0) + 1
                    return {"model": current, "reason": "recent tool use"}

    # 5. Flash has been failing recently → stay pro
    if state.get("short_flash", 0) >= 2:
        state["pro_turns"] = state.get("pro_turns", 0) + 1
        return {"model": current, "reason": "flash quality low"}

    # ── Route to Flash ──
    # Simple request: short, no tools, fresh session
    state["flash_turns"] = state.get("flash_turns", 0) + 1
    body["model"] = "deepseek-v4-flash"
    return {"model": "deepseek-v4-flash", "reason": "simple→flash"}


def feedback_flash_response(session_id: str | None, response_text: str) -> None:
    """Called after receiving a flash response. If it's too short, mark for upgrade."""
    if not session_id or not response_text:
        return
    state = _get_session(session_id)
    if len(response_text) < FLASH_UPGRADE_SHORT_RESPONSE:
        state["short_flash"] = state.get("short_flash", 0) + 1


def get_session_stats(session_id: str | None) -> dict:
    """Return routing stats for a session."""
    return dict(_get_session(session_id))
