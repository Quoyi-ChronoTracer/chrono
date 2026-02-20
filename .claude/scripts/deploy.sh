#!/usr/bin/env bash
#
# deploy.sh — ChronoTracer tag-based deploy script
#
# PURPOSE:
#   Handles all mechanics for deploying components via semver tags.
#   Both paths trigger GitHub Actions workflows with reviewer approval
#   gates. All tag pushes go through the Deploy Bot GitHub App,
#   enforced by tag protection rulesets.
#
#   The /deploy skill handles the "intelligence" half:
#     - Querying existing tags per repo
#     - Proposing version bumps
#     - Getting user confirmation
#     - Writing the plan file this script reads
#
# USAGE:
#   Called by Claude via the /deploy skill. Do not invoke directly unless
#   you have written a valid deploy-plan.json first.
#
#   bash .claude/scripts/deploy.sh
#
# PRE-FLIGHT:
#   The Claude Code PreToolUse hook (.claude/hooks/pre-deploy.sh) intercepts
#   this script's invocation and validates deploy-plan.json before this
#   script ever executes.
#
# INPUT:
#   Reads .claude/tmp/deploy-plan.json — written by the /deploy skill.
#   Schema:
#     {
#       "environment": "staging",
#       "repos": [
#         { "name": "chrono-devops", "tag": "v1.3.0-rc.1" },
#         { "name": "chrono-api",    "tag": "v2.5.0-rc.1" }
#       ]
#     }

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLAN_FILE="$SCRIPT_DIR/../tmp/deploy-plan.json"

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

[ -f "$PLAN_FILE" ] || fail "deploy-plan.json not found at $PLAN_FILE. Did the /deploy skill write it?"

ENVIRONMENT=$(jq -r '.environment // ""' "$PLAN_FILE")
[ -n "$ENVIRONMENT" ] || fail "'environment' is missing from deploy-plan.json"

case "$ENVIRONMENT" in
  staging|production) ;;
  *) fail "Invalid environment '$ENVIRONMENT' — must be 'staging' or 'production'" ;;
esac

REPO_COUNT=$(jq '.repos | length' "$PLAN_FILE")
[ "$REPO_COUNT" -gt 0 ] || fail "'repos' array is empty in deploy-plan.json"

echo ""
echo "Deploy environment: $ENVIRONMENT"
echo "Repos:              $(jq -r '[.repos[].name] | join(", ")' "$PLAN_FILE")"

# ---------------------------------------------------------------------------
# Track results for the final summary
# ---------------------------------------------------------------------------

declare -a TAGGED=()       # "repo-name|tag" entries
declare -a FAILED=()       # repo names that failed

# ---------------------------------------------------------------------------
# Staging path: trigger GitHub Actions staging workflow
# Tag rulesets restrict all v* tags to the Deploy Bot. Staging goes
# through GHA with a reviewer approval gate, same as production.
# ---------------------------------------------------------------------------

if [ "$ENVIRONMENT" = "staging" ]; then
  step "Triggering staging promotion workflow"

  # Build the repo_tags string: comma-separated name:tag pairs
  REPO_TAGS=""
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(jq -r ".repos[$i].name" "$PLAN_FILE")
    TAG=$(jq -r ".repos[$i].tag" "$PLAN_FILE")
    if [ -n "$REPO_TAGS" ]; then
      REPO_TAGS+=","
    fi
    REPO_TAGS+="$REPO_NAME:$TAG"
  done

  info "repo_tags: $REPO_TAGS"

  # Trigger the staging promote workflow via GitHub CLI
  gh workflow run promote-staging.yml \
    --repo Quoyi-ChronoTracer/chrono \
    --field repo_tags="$REPO_TAGS"
  ok "Workflow triggered"

  # Brief pause to let GitHub register the run
  sleep 3

  # Get the URL of the most recent run
  RUN_URL=$(gh run list \
    --repo Quoyi-ChronoTracer/chrono \
    --workflow=promote-staging.yml \
    --limit=1 \
    --json url \
    --jq '.[0].url' 2>/dev/null || echo "(could not retrieve run URL)")

  echo ""
  echo "════════════════════════════════════════"
  echo " Staging deploy triggered"
  echo "════════════════════════════════════════"
  echo ""
  echo "  A GitHub reviewer must approve the deployment."
  echo "  After approval, RC tags will be pushed by the Deploy Bot."
  echo "  CircleCI pipelines will fire automatically."
  echo "  Monitor the workflow run:"
  echo ""
  echo "  $RUN_URL"
  echo ""
  echo "  Repos included:"
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(jq -r ".repos[$i].name" "$PLAN_FILE")
    TAG=$(jq -r ".repos[$i].tag" "$PLAN_FILE")
    echo "    - $REPO_NAME @ $TAG"
  done
fi

# ---------------------------------------------------------------------------
# Production path: trigger GitHub Actions promote workflow
# ---------------------------------------------------------------------------

if [ "$ENVIRONMENT" = "production" ]; then
  step "Triggering production promotion workflow"

  # Build the repo_tags string: comma-separated name:tag pairs
  REPO_TAGS=""
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(jq -r ".repos[$i].name" "$PLAN_FILE")
    TAG=$(jq -r ".repos[$i].tag" "$PLAN_FILE")
    if [ -n "$REPO_TAGS" ]; then
      REPO_TAGS+=","
    fi
    REPO_TAGS+="$REPO_NAME:$TAG"
  done

  info "repo_tags: $REPO_TAGS"

  # Trigger the promote workflow via GitHub CLI
  gh workflow run promote.yml \
    --repo Quoyi-ChronoTracer/chrono \
    --field repo_tags="$REPO_TAGS"
  ok "Workflow triggered"

  # Brief pause to let GitHub register the run
  sleep 3

  # Get the URL of the most recent run
  RUN_URL=$(gh run list \
    --repo Quoyi-ChronoTracer/chrono \
    --workflow=promote.yml \
    --limit=1 \
    --json url \
    --jq '.[0].url' 2>/dev/null || echo "(could not retrieve run URL)")

  echo ""
  echo "════════════════════════════════════════"
  echo " Production deploy triggered"
  echo "════════════════════════════════════════"
  echo ""
  echo "  A GitHub reviewer must approve the deployment."
  echo "  Monitor the workflow run:"
  echo ""
  echo "  $RUN_URL"
  echo ""
  echo "  Repos included:"
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(jq -r ".repos[$i].name" "$PLAN_FILE")
    TAG=$(jq -r ".repos[$i].tag" "$PLAN_FILE")
    echo "    - $REPO_NAME @ $TAG"
  done
fi

# ---------------------------------------------------------------------------
# Clean up the plan file
# ---------------------------------------------------------------------------

rm -f "$PLAN_FILE"

# ---------------------------------------------------------------------------
# Report failures if any
# ---------------------------------------------------------------------------

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo ""
  echo "  ⚠  Failed repos (require manual attention):"
  for name in "${FAILED[@]+"${FAILED[@]}"}"; do
    echo "     - $name"
  done
  exit 1
fi

echo ""
