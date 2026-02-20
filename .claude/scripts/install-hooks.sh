#!/usr/bin/env bash
#
# install-hooks.sh — Install git hooks for the mono repo
#
# PURPOSE:
#   Installs a pre-commit hook at the parent repo level that warns when
#   submodule ref changes are staged. This catches accidental ref bumps
#   from `git add -A` or `git add .` at the parent level.
#
# USAGE:
#   bash .claude/scripts/install-hooks.sh
#
# IDEMPOTENT: safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOKS_DIR="$MONO_ROOT/.git/hooks"
HOOK_FILE="$HOOKS_DIR/pre-commit"

# ---------------------------------------------------------------------------
# Marker to identify our managed hook content
# ---------------------------------------------------------------------------
MARKER="# chrono-managed-hook"

# ---------------------------------------------------------------------------
# Pre-commit hook content
# ---------------------------------------------------------------------------
HOOK_CONTENT='#!/usr/bin/env bash
'"$MARKER"'
#
# pre-commit — Warn on staged submodule ref changes
#
# This hook checks if any submodule refs are staged in the parent repo.
# Submodule ref bumps should only happen intentionally via ship.sh.

STAGED_SUBS=$(git diff --cached --name-only | grep -E "^(chrono-app|chrono-api|chrono-pipeline-v2|chrono-filter-ai-api|chrono-devops)$" || true)

if [ -n "$STAGED_SUBS" ]; then
  echo ""
  echo "WARNING: Submodule ref changes are staged:"
  echo ""
  while IFS= read -r sub; do
    OLD=$(git diff --cached -- "$sub" | grep "^-Subproject commit" | awk "{print \$3}" | cut -c1-7)
    NEW=$(git diff --cached -- "$sub" | grep "^+Subproject commit" | awk "{print \$3}" | cut -c1-7)
    echo "  $sub: ${OLD:-?} → ${NEW:-?}"
  done <<< "$STAGED_SUBS"
  echo ""
  echo "If this is intentional (e.g. via ship.sh), proceed. Otherwise unstage with:"
  echo "  git reset HEAD <submodule>"
  echo ""
fi
'

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

mkdir -p "$HOOKS_DIR"

if [ -f "$HOOK_FILE" ]; then
  if grep -qF "$MARKER" "$HOOK_FILE"; then
    echo "  ✓  Pre-commit hook already installed (updating)"
    # Replace the existing managed hook
    printf '%s\n' "$HOOK_CONTENT" > "$HOOK_FILE"
    chmod +x "$HOOK_FILE"
  else
    echo "  ⚠  Pre-commit hook exists but is not managed by ChronoTracer — skipping"
    echo "     To install manually, see: .claude/scripts/install-hooks.sh"
  fi
else
  printf '%s\n' "$HOOK_CONTENT" > "$HOOK_FILE"
  chmod +x "$HOOK_FILE"
  echo "  ✓  Pre-commit hook installed"
fi
