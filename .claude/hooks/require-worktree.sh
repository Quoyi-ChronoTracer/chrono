#!/usr/bin/env bash
#
# require-worktree.sh — Claude Code PreToolUse hook (Edit | Write)
#
# PURPOSE:
#   Blocks file edits outside a worktree to enforce the "always work in a
#   worktree" policy. If the session is not inside a worktree, Claude must
#   use /workspace <name> before editing code files.
#
# EXCEPTIONS (allowed even outside a worktree):
#   - Files inside .claude/  (settings, docs, plans, hooks — repo config)
#   - CLAUDE.md, README.md   (documentation at repo root)
#   - tasks/ directories     (task tracking)
#
# EXIT CODES (Claude Code PreToolUse contract):
#   0 — allow the tool call to proceed
#   2 — block the tool call; stderr is shown to Claude as the error reason

set -euo pipefail

# ---------------------------------------------------------------------------
# Read the tool input from stdin (provided by Claude Code as JSON)
# ---------------------------------------------------------------------------
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Only gate Edit and Write calls
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Extract the file path being edited
# ---------------------------------------------------------------------------
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

if [ -z "$FILE_PATH" ]; then
  # No file path — let it through (shouldn't happen, but be safe)
  exit 0
fi

# ---------------------------------------------------------------------------
# Check exceptions — always allow these regardless of worktree status
# ---------------------------------------------------------------------------

# Resolve to a path relative to the project dir for pattern matching
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
REL_PATH="$FILE_PATH"
if [ -n "$CLAUDE_PROJECT_DIR" ]; then
  REL_PATH="${FILE_PATH#"$CLAUDE_PROJECT_DIR"/}"
fi

# Exception: .claude/ directory (settings, docs, plans, hooks, skills, agents)
if [[ "$REL_PATH" == .claude/* ]]; then
  exit 0
fi

# Exception: CLAUDE.md and README.md at any level
BASENAME="$(basename "$FILE_PATH")"
if [[ "$BASENAME" == "CLAUDE.md" ]] || [[ "$BASENAME" == "README.md" ]]; then
  exit 0
fi

# Exception: tasks/ directories at any level
if [[ "$REL_PATH" == tasks/* ]] || [[ "$REL_PATH" == */tasks/* ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Check if we're inside a worktree
# ---------------------------------------------------------------------------

# Determine the mono root from this hook's location
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"

IN_WORKTREE="no"
if git -C "$MONO_ROOT" rev-parse --git-common-dir &>/dev/null; then
  GIT_COMMON="$(git -C "$MONO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
  GIT_DIR="$(git -C "$MONO_ROOT" rev-parse --git-dir 2>/dev/null)"
  if [ "$GIT_COMMON" != "$GIT_DIR" ]; then
    IN_WORKTREE="yes"
  fi
fi

if [ "$IN_WORKTREE" = "yes" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Block — not in a worktree and editing a non-exempt file
# ---------------------------------------------------------------------------
echo "Edit blocked — you are not in a worktree." >&2
echo "" >&2
echo "The project requires all code changes to happen inside a worktree." >&2
echo "Create one first:  /workspace <name>" >&2
echo "" >&2
echo "File: $FILE_PATH" >&2
exit 2
