#!/usr/bin/env bash
#
# deploy.sh — ChronoTracer tag-based deploy script
#
# PURPOSE:
#   Handles all mechanics for deploying components via semver tags.
#   Two paths: staging (push RC tags directly) or production (trigger
#   GitHub Actions approval workflow).
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
# Staging path: push RC tags directly to each component repo
# ---------------------------------------------------------------------------

if [ "$ENVIRONMENT" = "staging" ]; then
  for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
    REPO_NAME=$(jq -r ".repos[$i].name" "$PLAN_FILE")
    TAG=$(jq -r ".repos[$i].tag" "$PLAN_FILE")
    REPO_PATH="$MONO_ROOT/$REPO_NAME"

    step "$REPO_NAME → $TAG"

    if [ ! -d "$REPO_PATH" ]; then
      info "Directory not found at $REPO_PATH — skipping"
      FAILED+=("$REPO_NAME")
      continue
    fi

    cd "$REPO_PATH"

    # Fetch latest tags from remote
    git fetch --tags
    ok "Fetched tags"

    # Check if tag already exists
    if git rev-parse "$TAG" &>/dev/null; then
      info "Tag $TAG already exists in $REPO_NAME — skipping"
      FAILED+=("$REPO_NAME")
      continue
    fi

    # Create annotated tag
    git tag -a "$TAG" -m "Release $TAG"
    ok "Created tag: $TAG"

    # Push tag to origin
    git push origin "$TAG"
    ok "Pushed tag to origin"

    TAGGED+=("$REPO_NAME|$TAG")
  done

  # ---------------------------------------------------------------------------
  # Summary — staging
  # ---------------------------------------------------------------------------

  echo ""
  echo "════════════════════════════════════════"
  echo " Deploy complete — staging"
  echo "════════════════════════════════════════"
  echo ""
  printf "  %-24s %s\n" "Repo" "Tag"
  printf "  %-24s %s\n" "────────────────────────" "──────────────────────────────────────"
  for entry in "${TAGGED[@]+"${TAGGED[@]}"}"; do
    RNAME="${entry%%|*}"
    RTAG="${entry#*|}"
    printf "  %-24s %s\n" "$RNAME" "$RTAG"
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
