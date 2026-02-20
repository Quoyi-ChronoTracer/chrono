#!/usr/bin/env bash
#
# pull.sh — Mono repo pull
#
# PURPOSE:
#   Pulls the latest for the mono repo and all submodules in one shot.
#   Equivalent to what `git pull` would do in a true single repo.
#
# USAGE:
#   bash .claude/scripts/pull.sh
#
# WHAT IT DOES:
#   1. Pulls the current branch of the mono repo
#   2. Fetches and merges the latest from each submodule's tracked remote
#      branch (develop, as configured in .gitmodules)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "── mono repo ───────────────────────────"
git -C "$MONO_ROOT" pull
echo ""

echo "── submodules ──────────────────────────"
git -C "$MONO_ROOT" submodule update --remote --merge
echo ""

echo "✓  All repos up to date."
