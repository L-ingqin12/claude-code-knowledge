#!/bin/bash
# ============================================================================
# Gated Bash — transparent resource-locked command wrapper (Phase 2d)
# ============================================================================
# Usage: /root/claude-gate-bash.sh <command...>
#
# Detects the resource class of the command, acquires the appropriate lock
# (with 30s spin-wait), runs the command, then releases the lock.
#
# Light commands skip the lock mechanism entirely.
# ============================================================================
set +e

GATE="/root/claude-agent-gate.sh"
COMMAND="$*"

# Detect resource class
CLASS=$(bash "$GATE" detect "$COMMAND" 2>/dev/null || echo "light")

if [ "$CLASS" != "light" ] && [ -n "$CLASS" ]; then
    # Acquire lock with 30s spin-wait timeout
    bash "$GATE" acquire "$CLASS" --wait 30 2>/dev/null
    ACQ_RC=$?
    if [ "$ACQ_RC" -ne 0 ] 2>/dev/null; then
        echo "[gate] resource '$CLASS' busy after 30s, proceeding anyway" >&2
    fi
fi

# Execute original command
eval "$COMMAND"
RC=$?

# Release lock
if [ "$CLASS" != "light" ] && [ -n "$CLASS" ]; then
    bash "$GATE" release "$CLASS" 2>/dev/null || true
fi

exit $RC
