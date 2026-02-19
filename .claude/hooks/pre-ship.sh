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
#   The test gate is scoped to only the repos listed in ship-plan.json.
#   This means a dirty chrono-app with pre-existing failures won't block
#   a ship of unrelated mono-root-only changes.
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
# Locate the test script and plan file relative to this hook file
# ---------------------------------------------------------------------------
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="$HOOK_DIR/../scripts/test.sh"
PLAN_FILE="$HOOK_DIR/../tmp/ship-plan.json"

if [ ! -f "$TEST_SCRIPT" ]; then
  echo "test.sh not found at: $TEST_SCRIPT" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Extract the repos being shipped from the plan file (may be empty list)
# Passing the list scopes the test gate to only those repos, so unrelated
# dirty repos with pre-existing failures don't block an unrelated ship.
# ---------------------------------------------------------------------------
REPOS=()
if [ -f "$PLAN_FILE" ]; then
  while IFS= read -r repo; do
    [ -n "$repo" ] && REPOS+=("$repo")
  done < <(jq -r '.repos[].name // empty' "$PLAN_FILE" 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Run the test gate — output is visible in Claude Code
# ---------------------------------------------------------------------------
echo "Pre-ship test gate running..."
if [ ${#REPOS[@]} -gt 0 ]; then
  echo "Scoped to: ${REPOS[*]}"
else
  echo "No submodule repos in plan — skipping submodule tests."
  exit 0
fi
echo ""

if ! bash "$TEST_SCRIPT" "${REPOS[@]}"; then
  echo "" >&2
  echo "Ship blocked — fix all test failures before shipping." >&2
  exit 2
fi

# Tests passed — allow ship.sh to proceed
exit 0
