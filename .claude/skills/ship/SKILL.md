---
name: ship
description: User-invoked. Use /ship <branch-name> to branch, commit, push, and open PRs across all dirty submodules and the mono repo. Works from the mono repo root (multi-repo) or from inside a single component (single-repo).
argument-hint: <branch-name>
---

# Ship Changes

Your job is the **intelligence** half of the ship process — analysis and judgment.
The mechanics (branching, committing, pushing, PRs) are handled by `.claude/scripts/ship.sh`.
The test gate fires automatically via `.claude/hooks/pre-ship.sh` before the script runs.

## Arguments

Parse from `$ARGUMENTS`: branch name (required, e.g. `ata/APP-297-pipeline-v2`).
If missing, use `AskUserQuestion` to ask for it.

## Your procedure

### 1. Discover dirty repos
Run `git status --short` in the parent, then `git -C <path> status --short` for each
submodule. Identify repos with **tracked-file changes** — ignore `.DS_Store`-only diffs
and repos with only untracked files.

### 2. Clean up scratch files
Before staging anything, delete any temp files, one-off scripts, or artifacts you created
during the session that are not part of the feature.

### 3. Analyse each dirty repo
Run `git diff` in each dirty repo to understand what changed.

### 4. Write a commit message per repo
- **Single line only**
- **Present third-person tense** — e.g. "Adds OCR extraction step", "Fixes date parsing in event deduplicator"
- Summarise the *what*, not the *why*
- Include ticket number if present in the branch name: `APP-297: Adds OCR extraction step`
- **No co-author trailers** — do not append `Co-Authored-By` or any attribution lines

### 5. Write the plan file
Create `.claude/tmp/ship-plan.json` with the branch and one message per dirty repo:

```json
{
  "branch": "<branch-name>",
  "repos": [
    { "name": "chrono-app",  "message": "<commit message>" },
    { "name": "chrono-api",  "message": "<commit message>" }
  ]
}
```

Only include repos that actually have tracked-file changes.

### 6. Run the script
```bash
bash .claude/scripts/ship.sh
```

The pre-ship hook fires automatically before this runs — tests pass or the ship is blocked.
