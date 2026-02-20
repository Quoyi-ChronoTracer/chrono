#!/usr/bin/env bash
#
# workspace.sh — Per-submodule worktree manager
#
# PURPOSE:
#   Creates a full parallel working copy of the mono repo by setting up a
#   parent worktree and individual worktrees for each submodule, all on the
#   same branch name. This allows opening a second Claude Code session that
#   works independently without branch conflicts.
#
# USAGE:
#   bash .claude/scripts/workspace.sh create <name>
#   bash .claude/scripts/workspace.sh remove <name>
#   bash .claude/scripts/workspace.sh list
#   bash .claude/scripts/workspace.sh gc

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKTREE_BASE="$MONO_ROOT/.claude/worktrees"

SUBMODULES=("chrono-app" "chrono-api" "chrono-pipeline-v2" "chrono-filter-ai-api" "chrono-devops")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fail() { echo "" && echo "✗  ERROR: $*" >&2 && exit 1; }
step() { echo "" && echo "── $* ──────────────────────────────────"; }
ok()   { echo "  ✓  $*"; }
info() { echo "     $*"; }

# ---------------------------------------------------------------------------
# create <name>
# ---------------------------------------------------------------------------

cmd_create() {
  local name="${1:-}"
  [ -n "$name" ] || fail "Usage: workspace.sh create <name>"

  local ws_path="$WORKTREE_BASE/$name"

  [ ! -d "$ws_path" ] || fail "Workspace '$name' already exists at $ws_path"

  step "Creating parent worktree"

  # Ensure the worktrees directory exists
  mkdir -p "$WORKTREE_BASE"

  # Create parent worktree — use existing branch or create new
  if git -C "$MONO_ROOT" rev-parse --verify "$name" &>/dev/null; then
    git -C "$MONO_ROOT" worktree add "$ws_path" "$name"
    ok "Parent worktree (existing branch '$name')"
  else
    git -C "$MONO_ROOT" worktree add -b "$name" "$ws_path"
    ok "Parent worktree (new branch '$name')"
  fi

  step "Creating submodule worktrees"

  for sub in "${SUBMODULES[@]}"; do
    local sub_main="$MONO_ROOT/$sub"
    local sub_ws="$ws_path/$sub"

    # Skip submodules that don't exist in the main checkout
    if [ ! -d "$sub_main" ]; then
      info "$sub — not found, skipping"
      continue
    fi

    # The parent worktree created an empty directory for the submodule path.
    # Remove it so git worktree add can place its checkout there.
    if [ -d "$sub_ws" ]; then
      rm -rf "$sub_ws"
    fi

    # Fetch so we can see remote branches
    git -C "$sub_main" fetch --quiet 2>/dev/null || true

    # 3-tier fallback: local branch → remote branch → new from HEAD
    if git -C "$sub_main" rev-parse --verify "$name" &>/dev/null; then
      # Branch exists locally — check if it's already checked out in another worktree
      if git -C "$sub_main" worktree add "$sub_ws" "$name" 2>/dev/null; then
        ok "$sub (existing local branch)"
      else
        # Branch is checked out elsewhere — create a detached worktree won't work,
        # so create with a workspace-scoped branch name instead
        local ws_branch="ws/${name}/${sub}"
        git -C "$sub_main" worktree add -b "$ws_branch" "$sub_ws" "$name"
        ok "$sub (new branch '$ws_branch' from '$name')"
      fi
    elif git -C "$sub_main" rev-parse --verify "origin/$name" &>/dev/null; then
      git -C "$sub_main" worktree add --track -b "$name" "$sub_ws" "origin/$name"
      ok "$sub (tracking origin/$name)"
    else
      git -C "$sub_main" worktree add -b "$name" "$sub_ws"
      ok "$sub (new branch from HEAD)"
    fi
  done

  # Summary
  echo ""
  echo "════════════════════════════════════════"
  echo " Workspace ready"
  echo "════════════════════════════════════════"
  echo ""
  echo "  Path:   $ws_path"
  echo "  Branch: $name"
  echo ""
  echo "  Open a new Claude Code session there:"
  echo "    cd $ws_path && claude"
  echo ""
}

# ---------------------------------------------------------------------------
# remove <name>
# ---------------------------------------------------------------------------

cmd_remove() {
  local name="${1:-}"
  [ -n "$name" ] || fail "Usage: workspace.sh remove <name>"

  local ws_path="$WORKTREE_BASE/$name"

  [ -d "$ws_path" ] || fail "Workspace '$name' not found at $ws_path"

  step "Removing submodule worktrees"

  for sub in "${SUBMODULES[@]}"; do
    local sub_main="$MONO_ROOT/$sub"
    local sub_ws="$ws_path/$sub"

    [ -d "$sub_main" ] || continue

    if [ -d "$sub_ws" ]; then
      git -C "$sub_main" worktree remove "$sub_ws" --force 2>/dev/null || true
      ok "$sub"
    fi
  done

  step "Removing parent worktree"

  git -C "$MONO_ROOT" worktree remove "$ws_path" --force 2>/dev/null || true
  ok "Parent worktree removed"

  # Clean up any leftover files (e.g. if worktree remove left artifacts)
  if [ -d "$ws_path" ]; then
    rm -rf "$ws_path"
    info "Cleaned up leftover files"
  fi

  step "Pruning stale references"

  git -C "$MONO_ROOT" worktree prune
  for sub in "${SUBMODULES[@]}"; do
    local sub_main="$MONO_ROOT/$sub"
    [ -d "$sub_main" ] || continue
    git -C "$sub_main" worktree prune
  done
  ok "All stale worktree refs pruned"

  echo ""
  echo "✓  Workspace '$name' removed."
  echo ""
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

cmd_list() {
  if [ ! -d "$WORKTREE_BASE" ]; then
    echo "No workspaces found."
    return 0
  fi

  local found=0

  for ws_dir in "$WORKTREE_BASE"/*/; do
    [ -d "$ws_dir" ] || continue
    found=1

    local ws_name
    ws_name="$(basename "$ws_dir")"

    local branch
    branch="$(git -C "$ws_dir" branch --show-current 2>/dev/null || echo "(unknown)")"

    printf "  %-24s branch: %s\n" "$ws_name" "$branch"
  done

  if [ "$found" -eq 0 ]; then
    echo "No workspaces found."
  fi
}

# ---------------------------------------------------------------------------
# gc — remove workspaces older than 7 days
# ---------------------------------------------------------------------------

cmd_gc() {
  if [ ! -d "$WORKTREE_BASE" ]; then
    echo "No workspaces found."
    return 0
  fi

  local stale=()
  local max_age_days=7
  local now
  now=$(date +%s)

  for ws_dir in "$WORKTREE_BASE"/*/; do
    [ -d "$ws_dir" ] || continue

    local ws_name
    ws_name="$(basename "$ws_dir")"

    # Get modification time (macOS stat syntax)
    local mtime
    if stat -f %m "$ws_dir" &>/dev/null; then
      mtime=$(stat -f %m "$ws_dir")
    else
      # Linux fallback
      mtime=$(stat -c %Y "$ws_dir")
    fi

    local age_days=$(( (now - mtime) / 86400 ))

    if [ "$age_days" -ge "$max_age_days" ]; then
      stale+=("$ws_name")
    fi
  done

  if [ ${#stale[@]} -eq 0 ]; then
    echo "No stale workspaces found (all are less than $max_age_days days old)."
    return 0
  fi

  step "Removing ${#stale[@]} stale workspace(s)"

  for ws_name in "${stale[@]}"; do
    echo ""
    echo "  Removing '$ws_name' …"
    cmd_remove "$ws_name"
  done

  echo ""
  echo "✓  Garbage collection complete — removed ${#stale[@]} workspace(s)."
  echo ""
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  create) cmd_create "$@" ;;
  remove) cmd_remove "$@" ;;
  list)   cmd_list        ;;
  gc)     cmd_gc          ;;
  *)      fail "Usage: workspace.sh {create|remove|list|gc} [name]" ;;
esac
