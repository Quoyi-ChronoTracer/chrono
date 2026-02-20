#!/usr/bin/env bash
#
# bootstrap.sh — ChronoTracer dev environment setup
#
# PURPOSE:
#   Creates virtual environments and installs dependencies for component repos.
#   Follows the same pattern as test.sh — runs from mono root, accepts optional
#   repo list.
#
# USAGE:
#   All repos:
#     bash .claude/scripts/bootstrap.sh
#
#   Specific repos:
#     bash .claude/scripts/bootstrap.sh chrono-pipeline-v2 chrono-filter-ai-api
#
# EXIT CODES:
#   0 — all repos bootstrapped successfully
#   1 — one or more repos failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FAILED=()
SKIPPED=()

# ---------------------------------------------------------------------------
# bootstrap_python <name> <path> <requirements_args>
#   Creates .venv if missing, then pip-installs from the given requirements.
# ---------------------------------------------------------------------------

bootstrap_python() {
  local name="$1"
  local path="$2"
  local req_args="$3"

  [ -d "$path" ] || { SKIPPED+=("$name (dir missing)"); return 0; }

  echo "▶  $name"

  if [ ! -d "$path/.venv" ]; then
    echo "   Creating .venv …"
    if ! python3 -m venv "$path/.venv"; then
      FAILED+=("$name")
      echo "✗  $name — venv creation failed"
      return 0
    fi
  else
    echo "   .venv exists"
  fi

  echo "   Installing dependencies …"
  if (cd "$path" && .venv/bin/pip install --upgrade pip -q && .venv/bin/pip install $req_args -q); then
    echo "✓  $name"
  else
    FAILED+=("$name")
    echo "✗  $name — pip install failed"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# bootstrap_node <name> <path>
#   Runs yarn install if node_modules/ is missing.
# ---------------------------------------------------------------------------

bootstrap_node() {
  local name="$1"
  local path="$2"

  [ -d "$path" ] || { SKIPPED+=("$name (dir missing)"); return 0; }

  echo "▶  $name"

  if [ -d "$path/node_modules" ]; then
    echo "   node_modules exists — skipping"
    echo "✓  $name"
  else
    echo "   Running yarn install …"
    if (cd "$path" && yarn install); then
      echo "✓  $name"
    else
      FAILED+=("$name")
      echo "✗  $name — yarn install failed"
    fi
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# bootstrap_repo <name>
#   Dispatches to the correct bootstrap function for the named repo.
# ---------------------------------------------------------------------------

bootstrap_repo() {
  local name="$1"
  case "$name" in
    chrono-pipeline-v2)
      bootstrap_python "$name" "$MONO_ROOT/$name" "-r requirements-dev.txt"
      ;;
    chrono-filter-ai-api)
      bootstrap_python "$name" "$MONO_ROOT/$name" "-r requirements.txt -r requirements-dev.txt"
      ;;
    chrono-app)
      bootstrap_node "$name" "$MONO_ROOT/$name"
      ;;
    chrono-api)
      echo "✓  chrono-api — Swift (no local setup needed)"
      echo ""
      ;;
    chrono-devops)
      echo "✓  chrono-devops — Terraform (no local setup needed)"
      echo ""
      ;;
    *)
      echo "⚠  Unknown repo '$name' — skipping"
      echo ""
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Determine which repos to bootstrap
# ---------------------------------------------------------------------------

if [ $# -gt 0 ]; then
  for repo in "$@"; do
    bootstrap_repo "$repo"
  done
else
  bootstrap_repo "chrono-app"
  bootstrap_repo "chrono-api"
  bootstrap_repo "chrono-pipeline-v2"
  bootstrap_repo "chrono-filter-ai-api"
  bootstrap_repo "chrono-devops"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

[ ${#SKIPPED[@]} -gt 0 ] && echo "Skipped: ${SKIPPED[*]}"
echo ""

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "✗  Bootstrap failed for: ${FAILED[*]}"
  exit 1
fi

echo "✓  All repos bootstrapped."
