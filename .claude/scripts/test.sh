#!/usr/bin/env bash
#
# test.sh — ChronoTracer test runner
#
# PURPOSE:
#   Runs tests for submodules that have uncommitted tracked-file changes.
#   Repos with no changes are skipped — no point testing what hasn't changed.
#
# USAGE:
#   Standalone — tests all dirty submodules from the mono repo root:
#     bash .claude/scripts/test.sh
#
#   Scoped — tests only the listed repos (still skips each if not dirty):
#     bash .claude/scripts/test.sh chrono-app chrono-api
#
#   From inside a submodule (tests that repo only, if dirty):
#     bash /path/to/.claude/scripts/test.sh
#
#   Called automatically by pre-ship.sh (which passes only the repos being
#   shipped, so unrelated dirty repos don't block an unrelated ship).
#   Also safe to run standalone at any point during development.
#
# EXIT CODES:
#   0 — all checks passed (or nothing to test)
#   1 — one or more repos failed their tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAILED=()
SKIPPED=()

# ---------------------------------------------------------------------------
# run_if_dirty <name> <path> <cmd>
#   Runs <cmd> inside <path> only if it has uncommitted tracked-file changes.
#   Untracked-only dirs are silently skipped.
# ---------------------------------------------------------------------------

run_if_dirty() {
  local name="$1"
  local path="$2"
  local cmd="$3"

  [ -d "$path" ] || return 0

  # Only tracked-file changes matter — ignore untracked files
  local changes
  changes=$(git -C "$path" status --porcelain 2>/dev/null | grep -v '^??' || true)

  if [ -z "$changes" ]; then
    SKIPPED+=("$name")
    return 0
  fi

  echo "▶  $name"
  if (cd "$path" && eval "$cmd"); then
    echo "✓  $name"
  else
    FAILED+=("$name")
    echo "✗  $name FAILED"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# test_repo <name>
#   Dispatches to the correct test command for the named repo.
# ---------------------------------------------------------------------------

test_repo() {
  local name="$1"
  case "$name" in
    chrono-app)           run_if_dirty "$name" "$MONO_ROOT/$name" "yarn test --run && yarn lint" ;;
    chrono-api)           run_if_dirty "$name" "$MONO_ROOT/$name" "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test" ;;
    chrono-pipeline-v2)   run_if_dirty "$name" "$MONO_ROOT/$name" ".venv/bin/python -m pytest tests/unit/ -x -v" ;;
    chrono-filter-ai-api) run_if_dirty "$name" "$MONO_ROOT/$name" ".venv/bin/python -m pytest chrono_query/tests/ -v" ;;
    chrono-devops)        echo "✓  chrono-devops — no test suite" ;;
    *)                    echo "⚠  Unknown repo '$name' — skipping tests" ;;
  esac
}

# ---------------------------------------------------------------------------
# Determine which repos to test
# ---------------------------------------------------------------------------

CURRENT=$(pwd)

if [[ "$CURRENT" != "$MONO_ROOT" && "$CURRENT" == "$MONO_ROOT/"* ]]; then
  # Single-repo mode: invoked from inside a submodule directory
  REPO=$(basename "$CURRENT")
  test_repo "$REPO"

elif [ $# -gt 0 ]; then
  # Scoped mode: caller provided an explicit list of repos
  for repo in "$@"; do
    test_repo "$repo"
  done

else
  # Multi-repo mode: test all known repos (skip those without changes)
  test_repo "chrono-app"
  test_repo "chrono-api"
  test_repo "chrono-pipeline-v2"
  test_repo "chrono-filter-ai-api"
  # chrono-devops — no test suite
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

[ ${#SKIPPED[@]} -gt 0 ] && echo "Skipped (no changes): ${SKIPPED[*]}"
echo ""

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "✗  Tests failed in: ${FAILED[*]}"
  echo "   Fix all failures before shipping."
  exit 1
fi

echo "✓  All checks passed."
