#!/usr/bin/env bash
#
# pre-deploy.sh — Claude Code PreToolUse hook
#
# PURPOSE:
#   Validates the deploy plan BEFORE deploy.sh executes. This is the only
#   point where the deploy plan is automatically validated — specifically
#   and only when deploy.sh is invoked.
#
# HOW IT WORKS:
#   Claude Code calls this script before every Bash tool use, passing the
#   full tool input as JSON on stdin. We inspect the command field and
#   immediately exit 0 (allow) for anything that isn't deploy.sh. Only when
#   we see .claude/scripts/deploy.sh in the command do we run validation.
#
# EXIT CODES (Claude Code PreToolUse contract):
#   0 — allow the Bash call to proceed
#   2 — block the Bash call; stderr is shown to Claude as the error reason

set -euo pipefail

# ---------------------------------------------------------------------------
# Read the tool input from stdin (provided by Claude Code as JSON)
# ---------------------------------------------------------------------------
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# ---------------------------------------------------------------------------
# Gate: only act on deploy.sh invocations — let everything else through
# ---------------------------------------------------------------------------
if ! echo "$COMMAND" | grep -qE '\.claude/scripts/deploy\.sh'; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Locate the plan file relative to this hook file
# ---------------------------------------------------------------------------
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="$HOOK_DIR/../tmp/deploy-plan.json"

# ---------------------------------------------------------------------------
# Validation: plan file exists
# ---------------------------------------------------------------------------
if [ ! -f "$PLAN_FILE" ]; then
  echo "deploy-plan.json not found at: $PLAN_FILE" >&2
  echo "The /deploy skill must write the plan file before running deploy.sh." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Validation: valid JSON
# ---------------------------------------------------------------------------
if ! jq empty "$PLAN_FILE" 2>/dev/null; then
  echo "deploy-plan.json is not valid JSON." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Validation: environment field
# ---------------------------------------------------------------------------
ENVIRONMENT=$(jq -r '.environment // ""' "$PLAN_FILE")
if [ -z "$ENVIRONMENT" ]; then
  echo "'environment' field is missing from deploy-plan.json." >&2
  exit 2
fi

case "$ENVIRONMENT" in
  staging|production) ;;
  *)
    echo "Invalid environment '$ENVIRONMENT' — must be 'staging' or 'production'." >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Validation: repos array is non-empty
# ---------------------------------------------------------------------------
REPO_COUNT=$(jq '.repos | length' "$PLAN_FILE")
if [ "$REPO_COUNT" -eq 0 ]; then
  echo "'repos' array is empty in deploy-plan.json." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Validation: each repo entry has name and tag with valid formats
# ---------------------------------------------------------------------------
SEMVER_STABLE='^v[0-9]+\.[0-9]+\.[0-9]+$'
SEMVER_RC='^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$'

for i in $(seq 0 $(( REPO_COUNT - 1 ))); do
  NAME=$(jq -r ".repos[$i].name // \"\"" "$PLAN_FILE")
  TAG=$(jq -r ".repos[$i].tag // \"\"" "$PLAN_FILE")

  if [ -z "$NAME" ]; then
    echo "repos[$i] is missing 'name'." >&2
    exit 2
  fi

  if [ -z "$TAG" ]; then
    echo "repos[$i] ('$NAME') is missing 'tag'." >&2
    exit 2
  fi

  # Tag must be valid semver (stable or RC)
  if ! [[ "$TAG" =~ $SEMVER_STABLE ]] && ! [[ "$TAG" =~ $SEMVER_RC ]]; then
    echo "repos[$i] ('$NAME') has invalid tag '$TAG' — must match vX.Y.Z or vX.Y.Z-rc.N." >&2
    exit 2
  fi

  # Cross-check: staging tags must have -rc. suffix
  if [ "$ENVIRONMENT" = "staging" ]; then
    if ! [[ "$TAG" =~ $SEMVER_RC ]]; then
      echo "repos[$i] ('$NAME') tag '$TAG' must have -rc.N suffix for staging deploys." >&2
      exit 2
    fi
  fi

  # Cross-check: production tags must NOT have -rc. suffix
  if [ "$ENVIRONMENT" = "production" ]; then
    if [[ "$TAG" =~ $SEMVER_RC ]]; then
      echo "repos[$i] ('$NAME') tag '$TAG' must not have -rc.N suffix for production deploys." >&2
      exit 2
    fi
  fi
done

# ---------------------------------------------------------------------------
# All validations passed
# ---------------------------------------------------------------------------
echo "Deploy plan validated ✓"
echo "  Environment: $ENVIRONMENT"
echo "  Repos: $(jq -r '[.repos[] | "\(.name)@\(.tag)"] | join(", ")' "$PLAN_FILE")"
exit 0
