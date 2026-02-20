#!/usr/bin/env bash
#
# ship.sh — ChronoTracer multi-repo ship script
#
# PURPOSE:
#   Handles all git mechanics for shipping a feature across one or more
#   submodules and the mono repo parent. This script is the "mechanics"
#   half of the /ship skill — the deterministic, repeatable work that
#   doesn't require AI judgment.
#
#   The /ship skill handles the "intelligence" half:
#     - Analysing diffs to understand what changed
#     - Writing commit messages
#     - Deciding which files are meaningful vs scratch
#     - Writing the plan file this script reads
#
# USAGE:
#   Called by Claude via the /ship skill. Do not invoke directly unless
#   you have written a valid ship-plan.json first.
#
#   bash .claude/scripts/ship.sh
#
# PRE-FLIGHT:
#   The Claude Code PreToolUse hook (.claude/hooks/pre-ship.sh) intercepts
#   this script's invocation and runs the test gate (.claude/scripts/test.sh)
#   before this script ever executes. If any dirty repo's tests fail, this
#   script is blocked entirely.
#
# INPUT:
#   Reads .claude/tmp/ship-plan.json — written by the /ship skill.
#   Schema:
#     {
#       "branch": "feature/APP-XXX-description",
#       "repos": [
#         { "name": "chrono-app",  "message": "Adds OCR integration in timeline" },
#         { "name": "chrono-api",  "message": "Adds OCR result endpoints"        }
#       ]
#     }
#
# OUTPUT:
#   - One branch + commit + push + PR per dirty submodule
#   - One branch + commit + push + PR for the mono repo parent (if changed)
#   - Summary table printed at the end
#   - ship-plan.json cleaned up on success

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLAN_FILE="$SCRIPT_DIR/../tmp/ship-plan.json"

# Default reviewers added to every PR
REVIEWERS="ata-peppered,DexterW,jessicaribeiroalves,copilot"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fail() { echo "" && echo "✗  ERROR: $*" >&2 && exit 1; }
step() { echo "" && echo "── $* ──────────────────────────────────"; }
ok()   { echo "  ✓  $*"; }
info() { echo "     $*"; }

# ---------------------------------------------------------------------------
# Validate plan file
# ---------------------------------------------------------------------------

[ -f "$PLAN_FILE" ] || fail "ship-plan.json not found at $PLAN_FILE. Did the /ship skill write it?"

BRANCH=$(jq -r '.branch // ""' "$PLAN_FILE")
[ -n "$BRANCH" ] || fail "'branch' is missing from ship-plan.json"

REPO_COUNT=$(jq '.repos | length' "$PLAN_FILE")
MONO_MSG=$(jq -r '.monoMessage // ""' "$PLAN_FILE")

echo ""
echo "Shipping branch: $BRANCH"
if [ "$REPO_COUNT" -gt 0 ]; then
  echo "Repos:           $(jq -r '[.repos[].name] | join(", ")' "$PLAN_FILE")"
else
  echo "Repos:           (none — mono repo root only)"
fi

# ---------------------------------------------------------------------------
# Track results across repos for the final summary
# ---------------------------------------------------------------------------

declare -a PR_URLS=()        # "repo-name|pr-url" entries
declare -a SHIPPED_NAMES=()  # repo names that were successfully shipped
declare -a FAILED_NAMES=()   # repo names that failed

# ---------------------------------------------------------------------------
# Ship each submodule listed in the plan
# ---------------------------------------------------------------------------

for i in $([ "$REPO_COUNT" -gt 0 ] && seq 0 $(( REPO_COUNT - 1 )) || true); do
  REPO_NAME=$(jq -r ".repos[$i].name" "$PLAN_FILE")
  COMMIT_MSG=$(jq -r ".repos[$i].message // \"\"" "$PLAN_FILE")
  REPO_PATH="$MONO_ROOT/$REPO_NAME"

  step "$REPO_NAME"

  # Validate the repo directory exists
  if [ ! -d "$REPO_PATH" ]; then
    info "Directory not found at $REPO_PATH — skipping"
    FAILED_NAMES+=("$REPO_NAME")
    continue
  fi

  # Require a non-empty commit message
  if [ -z "$COMMIT_MSG" ]; then
    info "No commit message provided in ship-plan.json — skipping"
    FAILED_NAMES+=("$REPO_NAME")
    continue
  fi

  # Work inside the submodule from here
  cd "$REPO_PATH"

  # Confirm there are actually changes to commit (sanity check)
  CHANGES=$(git status --porcelain 2>/dev/null | grep -v '^??' || true)
  if [ -z "$CHANGES" ]; then
    info "No tracked-file changes detected — skipping (untracked files are not staged)"
    SKIPPED_NAMES+=("$REPO_NAME")
    continue
  fi

  # Create the branch if it doesn't exist, or switch to it if it does
  if git rev-parse --verify "$BRANCH" &>/dev/null 2>&1; then
    git checkout "$BRANCH"
    info "Switched to existing branch: $BRANCH"
  else
    git checkout -b "$BRANCH"
    info "Created branch: $BRANCH"
  fi

  # Stage all tracked changes
  # Note: untracked files are NOT staged automatically. The /ship skill
  # is responsible for instructing Claude to delete scratch files before
  # this script runs. Anything untracked that should be included must be
  # explicitly tracked (git add) by Claude before writing the plan file.
  git add -A
  info "Staged all changes"

  # Commit with the message provided by the /ship skill
  git commit -m "$COMMIT_MSG"
  ok "Committed: $COMMIT_MSG"

  # Push the branch to origin
  git push -u origin "$BRANCH"
  ok "Pushed to origin/$BRANCH"

  # Determine the base branch for the PR (prefer develop, fall back to default)
  BASE="develop"
  if ! git rev-parse --verify "origin/develop" &>/dev/null 2>&1; then
    BASE=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
    info "develop not found — using $BASE as PR base"
  fi

  # Open a PR targeting the base branch with the standard reviewer set
  PR_URL=$(gh pr create \
    --title "$COMMIT_MSG" \
    --body "$(cat <<EOF
## Summary
- See commit diff for full details.

## Test plan
- [ ] Verify changes work as expected on \`$BRANCH\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
    )" \
    --base "$BASE" \
    --reviewer "$REVIEWERS" 2>&1) || {
      info "PR creation failed (reviewer config or network issue) — branch and commit are still pushed"
      PR_URL="(PR creation failed — open manually)"
    }

  ok "PR: $PR_URL"
  PR_URLS+=("$REPO_NAME|$PR_URL")
  SHIPPED_NAMES+=("$REPO_NAME")
done

# ---------------------------------------------------------------------------
# Update the mono repo parent
# Bumps submodule gitlink refs and commits any root-level file changes
# (CLAUDE.md, .claude/, README.md, .gitmodules, etc.)
# ---------------------------------------------------------------------------

cd "$MONO_ROOT"

# Check for root-level changes (submodule ref bumps show up here too)
PARENT_CHANGES=$(git status --porcelain 2>/dev/null | grep -v '^??' || true)

if [ -n "$PARENT_CHANGES" ]; then
  step "chrono (mono repo)"

  if git rev-parse --verify "$BRANCH" &>/dev/null 2>&1; then
    git checkout "$BRANCH"
    info "Switched to existing branch: $BRANCH"
  else
    git checkout -b "$BRANCH"
    info "Created branch: $BRANCH"
  fi

  git add -A

  # Restore any submodule paths that we did NOT ship — git add -A would
  # otherwise stage their ref bumps, accidentally advancing their recorded
  # commits in the mono repo without an intentional ship of those repos.
  ALL_SUBMODULES=("chrono-app" "chrono-api" "chrono-pipeline-v2" "chrono-filter-ai-api" "chrono-devops")
  for submod in "${ALL_SUBMODULES[@]}"; do
    if [[ ! " ${SHIPPED_NAMES[*]+"${SHIPPED_NAMES[*]}"} " =~ " $submod " ]]; then
      git restore --staged "$submod" 2>/dev/null || true
    fi
  done

  # Build a short component list for the commit message
  SHIPPED_LIST=$(IFS=', '; echo "${SHIPPED_NAMES[*]+"${SHIPPED_NAMES[*]}"}")

  # Use monoMessage from the plan if provided; fall back to an auto-generated one
  if [ -n "$MONO_MSG" ]; then
    FINAL_MONO_MSG="$MONO_MSG"
  elif [ -n "$SHIPPED_LIST" ]; then
    FINAL_MONO_MSG="Updates submodule refs and ships $BRANCH across $SHIPPED_LIST"
  else
    FINAL_MONO_MSG="Updates AI tooling on $BRANCH"
  fi

  git commit -m "$FINAL_MONO_MSG"
  ok "Committed: $FINAL_MONO_MSG"

  git push -u origin "$BRANCH"
  ok "Pushed to origin/$BRANCH"

  # Build PR body with links to all component PRs
  COMPONENT_PR_LIST=""
  for entry in "${PR_URLS[@]}"; do
    RNAME="${entry%%|*}"
    RURL="${entry#*|}"
    COMPONENT_PR_LIST+="- **$RNAME**: $RURL"$'\n'
  done

  MONO_PR_TITLE="${FINAL_MONO_MSG}"
  MONO_PR_URL=$(gh pr create \
    --title "$MONO_PR_TITLE" \
    --body "$(cat <<EOF
## Component PRs
$COMPONENT_PR_LIST
## Summary
- Bumps submodule references in the mono repo following the above component PRs
- Includes any shared AI tooling or root-level changes made during this session

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
    )" \
    --base "main" \
    --reviewer "$REVIEWERS" 2>&1) || {
      info "Mono repo PR creation failed — branch and commit are still pushed"
      MONO_PR_URL="(PR creation failed — open manually)"
    }

  ok "PR: $MONO_PR_URL"
  PR_URLS+=("chrono (mono)|$MONO_PR_URL")
else
  info "No root-level changes — skipping mono repo PR"
fi

# ---------------------------------------------------------------------------
# Clean up the plan file
# ---------------------------------------------------------------------------
rm -f "$PLAN_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "════════════════════════════════════════"
echo " Ship complete"
echo "════════════════════════════════════════"
echo ""
printf "  %-24s %s\n" "Repo" "PR"
printf "  %-24s %s\n" "────────────────────────" "──────────────────────────────────────"
for entry in "${PR_URLS[@]+"${PR_URLS[@]}"}"; do
  RNAME="${entry%%|*}"
  RURL="${entry#*|}"
  printf "  %-24s %s\n" "$RNAME" "$RURL"
done

# Report failures if any
if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
  echo ""
  echo "  ⚠  Failed repos (require manual attention):"
  for name in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "     - $name"
  done
  exit 1
fi

echo ""
