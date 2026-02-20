#!/usr/bin/env bash
#
# checkout.sh — Mono repo branch checkout
#
# PURPOSE:
#   Checks out a branch across the mono repo and all submodules.
#   If the branch doesn't exist in a given repo, it is created from that
#   repo's current HEAD — ensuring every repo lands on the named branch.
#   Mirrors what `git checkout <branch>` would do in a true single repo.
#
# USAGE:
#   bash .claude/scripts/checkout.sh <branch-name>
#
# WHAT IT DOES:
#   For each repo (submodules first, then mono root):
#     - If the branch exists locally: checks it out
#     - If only on remote:            checks it out and tracks it
#     - If it doesn't exist at all:   creates it from current HEAD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BRANCH="${1:-}"
[ -n "$BRANCH" ] || { echo "Usage: checkout.sh <branch-name>" >&2; exit 1; }

SUBMODULES=("chrono-app" "chrono-api" "chrono-pipeline-v2" "chrono-filter-ai-api" "chrono-devops")

FAILED=()

checkout_repo() {
  local name="$1"
  local path="$2"

  [ -d "$path" ] || return 0

  echo "▶  $name"

  # Fetch so we can see remote branches without a full pull
  git -C "$path" fetch --quiet 2>/dev/null || true

  if git -C "$path" rev-parse --verify "$BRANCH" &>/dev/null; then
    # Branch exists locally — check it out
    git -C "$path" checkout "$BRANCH"
    echo "✓  $name"

  elif git -C "$path" rev-parse --verify "origin/$BRANCH" &>/dev/null; then
    # Branch exists on remote only — check out and track it
    git -C "$path" checkout --track "origin/$BRANCH"
    echo "✓  $name (tracking origin/$BRANCH)"

  else
    # Branch doesn't exist anywhere — create from current HEAD
    git -C "$path" checkout -b "$BRANCH"
    echo "✓  $name (created from HEAD)"
  fi

  echo ""
}

for name in "${SUBMODULES[@]}"; do
  checkout_repo "$name" "$MONO_ROOT/$name"
done

checkout_repo "chrono (mono)" "$MONO_ROOT"

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "⚠  Failed to checkout in: ${FAILED[*]}"
  exit 1
fi

echo "✓  All repos on branch '$BRANCH'."
