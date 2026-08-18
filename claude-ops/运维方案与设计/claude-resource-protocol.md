---
title: Claude Resource Protocol
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-01
updated: 2026-08-17
status: review
---

# Claude Resource Protocol

See also: [[Claude-Ops-KB-Home]] · [[claude-unattended-operation-plan]] · [[AGENTS]]

> System prompt injection — teaches Claude how to work within environment resource limits.

## Environment

- Android Termux + PRoot, 7.4 GB total RAM (~2 GB available)
- Each `claude` process ~200 MB RSS
- Oversubscribing triggers OOM kills (no swap)

## Before spawning subagents

**Always run:**

```
bash /root/claude-agent-gate.sh status
```

This is non-negotiable. Do not skip it.

## Gate commands

| Command | What it does |
|---------|-------------|
| `bash /root/claude-agent-gate.sh status` | Quick state check (prints one line) |
| `bash /root/claude-agent-gate.sh check` | Full gate (returns JSON with `GREEN`/`YELLOW`/`RED`/`DENY`) |

## Resource tiers

| Status | Meaning | What to do |
|--------|---------|------------|
| **GREEN** | Memory healthy | Up to **2 concurrent** subagents OK |
| **YELLOW** | Tight | **1 subagent max** — serial only |
| **RED** / **DENY** | Critical / throttled | **Don't spawn**. Wait 10–30 s, retry. |

## Fan-out pattern

Never spawn all subagents at once. Follow this rhythm:

1. Spawn **2**
2. **Wait** for both to complete
3. Spawn **next 2**
4. Repeat

Maximum 2 in-flight at any time, regardless of tier.

## Interactive awareness

- **User actively chatting** → subagents auto-throttled (gate returns DENY more aggressively)
- **User idle** → subagents get full resources (gate relaxes)

Let the gate decide — do not second-guess it.

## If denied

1. Wait **10–30 seconds**
2. Re-run `bash /root/claude-agent-gate.sh check`
3. If GREEN/YELLOW → proceed. If still DENY → **serialize the work**: run subtasks one at a time, no parallelism.

## Golden rule

One `check` before every subagent spawn. No exceptions.

## Resource lock awareness (Phase 2d)

When running heavy commands (npm install, pip install, cmake, grep -r /, etc.), the system automatically serializes conflicting operations:

- **CPU ops** (npm install, make, cmake) — only 1 at a time
- **IO ops** (grep -r /, find /, rsync) — only 1 at a time
- **Network ops** (curl -O, git clone) — max 2 concurrent
- **Light ops** (echo, cat, ls) — unlimited, zero overhead

In non-fan-out mode (single session, no subagents), all lock overhead is skipped. The mechanism only activates when subagents are running.

To check lock status: `bash /root/claude-agent-gate.sh lock-status`
To manually gate a heavy command: `/root/claude-gate-bash.sh <command>`
