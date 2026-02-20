#!/usr/bin/env bash
#
# on-session-start.sh — Claude Code SessionStart hook
#
# PURPOSE:
#   Injects a markdown state table at session startup so Claude immediately
#   knows the branch layout, dirty state, submodule alignment, and worktree
#   status — no manual git commands needed.
#
# OUTPUT:
#   Printed to stdout as markdown. Claude Code injects this into the session
#   context automatically.
#
# EXIT CODES:
#   Always 0 — informational only, never blocks.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
WORKTREE_BASE="$MONO_ROOT/.claude/worktrees"

SUBMODULES=("chrono-app" "chrono-api" "chrono-pipeline-v2" "chrono-filter-ai-api" "chrono-devops")

# ---------------------------------------------------------------------------
# Detect worktree status
# ---------------------------------------------------------------------------

IN_WORKTREE="no"
if git -C "$MONO_ROOT" rev-parse --git-common-dir &>/dev/null; then
  GIT_COMMON="$(git -C "$MONO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
  GIT_DIR="$(git -C "$MONO_ROOT" rev-parse --git-dir 2>/dev/null)"
  if [ "$GIT_COMMON" != "$GIT_DIR" ]; then
    IN_WORKTREE="yes"
  fi
fi

# ---------------------------------------------------------------------------
# Parent branch
# ---------------------------------------------------------------------------

PARENT_BRANCH="$(git -C "$MONO_ROOT" branch --show-current 2>/dev/null || echo "(detached)")"

# ---------------------------------------------------------------------------
# Submodule state table
# ---------------------------------------------------------------------------

TABLE_ROWS=""
WARNINGS=""

for sub in "${SUBMODULES[@]}"; do
  SUB_PATH="$MONO_ROOT/$sub"

  if [ ! -d "$SUB_PATH/.git" ] && [ ! -f "$SUB_PATH/.git" ]; then
    TABLE_ROWS+="| \`$sub\` | — | — | — | not initialized |\n"
    continue
  fi

  # Branch
  SUB_BRANCH="$(git -C "$SUB_PATH" branch --show-current 2>/dev/null || echo "(detached)")"

  # Dirty count (staged + unstaged modifications)
  DIRTY_COUNT="$(git -C "$SUB_PATH" diff --name-only 2>/dev/null | wc -l | tr -d ' ')"
  STAGED_COUNT="$(git -C "$SUB_PATH" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
  TOTAL_DIRTY=$(( DIRTY_COUNT + STAGED_COUNT ))

  # Untracked count
  UNTRACKED="$(git -C "$SUB_PATH" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"

  # Status note
  NOTE=""

  # Branch mismatch detection (only when parent is on a feature branch)
  if [ "$PARENT_BRANCH" != "main" ] && [ "$PARENT_BRANCH" != "develop" ] && [ "$PARENT_BRANCH" != "(detached)" ]; then
    if [ "$SUB_BRANCH" != "$PARENT_BRANCH" ]; then
      NOTE="branch mismatch"
      WARNINGS+="- \`$sub\` is on \`$SUB_BRANCH\` but parent is on \`$PARENT_BRANCH\`\n"
    fi
  fi

  # Submodule ref drift detection
  EXPECTED_REF="$(git -C "$MONO_ROOT" ls-tree HEAD "$sub" 2>/dev/null | awk '{print $3}' | cut -c1-7)"
  ACTUAL_REF="$(git -C "$SUB_PATH" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  if [ -n "$EXPECTED_REF" ] && [ -n "$ACTUAL_REF" ] && [ "$EXPECTED_REF" != "$ACTUAL_REF" ]; then
    if [ -n "$NOTE" ]; then
      NOTE+=", ref drift"
    else
      NOTE="ref drift"
    fi
    WARNINGS+="- \`$sub\` HEAD is \`$ACTUAL_REF\` but parent expects \`$EXPECTED_REF\` — run \`/pull\` to sync\n"
  fi

  [ "$TOTAL_DIRTY" -gt 0 ] && [ -z "$NOTE" ] && NOTE="dirty"
  [ "$TOTAL_DIRTY" -gt 0 ] && [[ "$NOTE" != *dirty* ]] && NOTE="${NOTE:+$NOTE, }dirty"

  TABLE_ROWS+="| \`$sub\` | $SUB_BRANCH | $TOTAL_DIRTY | $UNTRACKED | ${NOTE:---} |\n"
done

# ---------------------------------------------------------------------------
# Active workspaces
# ---------------------------------------------------------------------------

WORKSPACE_LIST=""
WORKSPACE_COUNT=0

if [ -d "$WORKTREE_BASE" ]; then
  for ws_dir in "$WORKTREE_BASE"/*/; do
    [ -d "$ws_dir" ] || continue
    WORKSPACE_COUNT=$(( WORKSPACE_COUNT + 1 ))
    ws_name="$(basename "$ws_dir")"
    ws_branch="$(git -C "$ws_dir" branch --show-current 2>/dev/null || echo "?")"
    WORKSPACE_LIST+="  - \`$ws_name\` (branch: \`$ws_branch\`)\n"
  done
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

echo "## Repo State"
echo ""
echo "**Parent branch:** \`$PARENT_BRANCH\`"
echo "**In worktree:** $IN_WORKTREE"
echo ""
echo "| Submodule | Branch | Dirty | Untracked | Note |"
echo "|---|---|---|---|---|"
echo -e "$TABLE_ROWS"

if [ -n "$WARNINGS" ]; then
  echo "### Warnings"
  echo ""
  echo -e "$WARNINGS"
fi

if [ "$WORKSPACE_COUNT" -gt 0 ]; then
  echo "### Active Workspaces ($WORKSPACE_COUNT)"
  echo ""
  echo -e "$WORKSPACE_LIST"
  if [ "$WORKSPACE_COUNT" -ge 3 ]; then
    echo "> Consider running \`/workspace remove <name>\` or \`/workspace gc\` to clean up stale workspaces."
    echo ""
  fi
fi

if [ "$IN_WORKTREE" = "no" ]; then
  echo "### Action Required"
  echo ""
  echo "> You are **not** in a worktree. If this session will produce code changes, create one first with \`/workspace <name>\`."
  echo ""
fi
