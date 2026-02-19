#!/usr/bin/env bash
#
# pre-ship.sh — Claude Code PreToolUse hook
#
# PURPOSE:
#   Runs the pre-ship test gate BEFORE ship.sh executes. This is the only
#   point where tests are automatically enforced — not on every git command,
#   not on every Bash call, specifically and only when ship.sh is invoked.
#
# HOW IT WORKS:
#   Claude Code calls this script before every Bash tool use, passing the
#   full tool input as JSON on stdin. We inspect the command field and
#   immediately exit 0 (allow) for anything that isn't ship.sh. Only when
#   we see .claude/scripts/ship.sh in the command do we run the test gate.
#
# EXIT CODES (Claude Code PreToolUse contract):
#   0 — allow the Bash call to proceed
#   2 — block the Bash call; stderr is shown to Claude as the error reason

set -euo pipefail

# ---------------------------------------------------------------------------
# Read the tool input from stdin (provided by Claude Code as JSON)
# ---------------------------------------------------------------------------
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# ---------------------------------------------------------------------------
# Gate: only act on ship.sh invocations — let everything else through
# ---------------------------------------------------------------------------
if ! echo "$COMMAND" | grep -qE '\.claude/scripts/ship\.sh'; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Locate the test gate script relative to this hook file
# ---------------------------------------------------------------------------
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="$HOOK_DIR/../scripts/pre-ship-tests.sh"

if [ ! -f "$TEST_SCRIPT" ]; then
  echo "pre-ship-tests.sh not found at: $TEST_SCRIPT" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Run the test gate — output is visible in Claude Code
# ---------------------------------------------------------------------------
echo "Pre-ship test gate running..."
echo ""

if ! bash "$TEST_SCRIPT"; then
  echo "" >&2
  echo "Ship blocked — fix all test failures before shipping." >&2
  exit 2
fi

# Tests passed — allow ship.sh to proceed
exit 0
