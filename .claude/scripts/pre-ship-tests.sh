#!/usr/bin/env bash
#
# pre-ship-tests.sh
#
# Pre-ship test gate. Runs tests only for submodules that have uncommitted
# tracked-file changes. Untracked-only dirs are skipped.
#
# Invoked by /ship before any commits are made.
# Non-zero exit aborts the ship.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAILED=()
SKIPPED=()

run_if_dirty() {
  local name="$1"
  local path="$2"
  local cmd="$3"

  [ -d "$path" ] || return 0

  # Only tracked-file changes matter for tests — ignore untracked files
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

CURRENT=$(pwd)

if [[ "$CURRENT" != "$MONO_ROOT" && "$CURRENT" == "$MONO_ROOT/"* ]]; then
  # Single-repo mode: invoked from inside a submodule directory
  REPO=$(basename "$CURRENT")
  case "$REPO" in
    chrono-app)           run_if_dirty "$REPO" "$CURRENT" "yarn test --run && yarn lint" ;;
    chrono-api)           run_if_dirty "$REPO" "$CURRENT" "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test" ;;
    chrono-pipeline-v2)   run_if_dirty "$REPO" "$CURRENT" ".venv/bin/python -m pytest tests/unit/ -x -v" ;;
    chrono-filter-ai-api) run_if_dirty "$REPO" "$CURRENT" "pytest chrono_query/tests/ -v" ;;
    chrono-devops)        echo "✓  chrono-devops — no test suite" ;;
    *)                    echo "⚠  Unknown submodule '$REPO' — skipping tests" ;;
  esac
else
  # Multi-repo mode: invoked from the mono repo root
  run_if_dirty "chrono-app"           "$MONO_ROOT/chrono-app"           "yarn test --run && yarn lint"
  run_if_dirty "chrono-api"           "$MONO_ROOT/chrono-api"           "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test"
  run_if_dirty "chrono-pipeline-v2"   "$MONO_ROOT/chrono-pipeline-v2"   ".venv/bin/python -m pytest tests/unit/ -x -v"
  run_if_dirty "chrono-filter-ai-api" "$MONO_ROOT/chrono-filter-ai-api" "pytest chrono_query/tests/ -v"
  # chrono-devops — no test suite
fi

[ ${#SKIPPED[@]} -gt 0 ] && echo "Skipped (no changes): ${SKIPPED[*]}"
echo ""

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "✗  Tests failed in: ${FAILED[*]}"
  echo "   Fix all failures before shipping."
  exit 1
fi

echo "✓  All checks passed — ready to ship."
