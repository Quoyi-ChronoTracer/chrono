#!/usr/bin/env bash
#
# branch.sh — Mono repo branch creation
#
# PURPOSE:
#   Creates and checks out a new branch in the mono repo and every submodule.
#   Mirrors what `git checkout -b <branch>` would do in a true single repo.
#
# USAGE:
#   bash .claude/scripts/branch.sh <branch-name>
#
# WHAT IT DOES:
#   1. Creates and checks out the branch in each submodule
#   2. Creates and checks out the branch in the mono repo root
#
# NOTE:
#   This only creates branches locally. Push happens at ship time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BRANCH="${1:-}"
[ -n "$BRANCH" ] || { echo "Usage: branch.sh <branch-name>" >&2; exit 1; }

SUBMODULES=("chrono-app" "chrono-api" "chrono-pipeline-v2" "chrono-filter-ai-api" "chrono-devops")

FAILED=()

branch_repo() {
  local name="$1"
  local path="$2"

  [ -d "$path" ] || return 0

  echo "▶  $name"
  if git -C "$path" checkout -b "$BRANCH" 2>/dev/null; then
    echo "✓  $name"
  else
    echo "✗  $name — branch may already exist (run checkout.sh to switch to it)"
    FAILED+=("$name")
  fi
  echo ""
}

for name in "${SUBMODULES[@]}"; do
  branch_repo "$name" "$MONO_ROOT/$name"
done

branch_repo "chrono (mono)" "$MONO_ROOT"

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "⚠  Some repos could not create branch: ${FAILED[*]}"
  echo "   If the branch already exists, use checkout.sh instead."
  exit 1
fi

echo "✓  Branch '$BRANCH' created across all repos."
