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

### 2. Confirm which repos to ship
If **more than one** repo has tracked-file changes, present the list and ask the user
which ones to include in this ship. Do NOT assume all dirty repos should ship together —
unrelated in-progress work in other submodules should not be swept into the same branch.

If only **one** repo is dirty (or the user's request clearly names a single component),
skip the prompt and proceed with that repo.

### 3. Rebase onto latest base branch
Before branching, ensure each confirmed repo is based on the latest upstream. This
prevents shipping stale code and avoids merge conflicts in PRs.

For each confirmed **submodule repo**:
```bash
git -C <repo> fetch origin
git -C <repo> stash        # stash dirty changes
git -C <repo> checkout develop && git -C <repo> pull --ff-only origin develop
git -C <repo> stash pop    # restore changes on top of latest develop
```

For the **mono repo parent** (if it has changes):
```bash
git fetch origin
git stash
git checkout main && git pull --ff-only origin main
git stash pop
```

If `stash pop` produces conflicts, stop and inform the user before proceeding.

### 4. Clean up scratch files
Before staging anything, delete any temp files, one-off scripts, or artifacts you created
during the session that are not part of the feature.

### 5. Analyse each selected repo
Run `git diff` in each repo the user confirmed for this ship to understand what changed.

### 6. Write a commit message per repo
- **Single line only**
- **Present third-person tense** — e.g. "Adds OCR extraction step", "Fixes date parsing in event deduplicator"
- Summarise the *what*, not the *why*
- Include ticket number if present in the branch name: `APP-297: Adds OCR extraction step`
- **No co-author trailers** — do not append `Co-Authored-By` or any attribution lines

### 7. Write the plan file
Create `.claude/tmp/ship-plan.json` with the branch and one message per confirmed repo:

```json
{
  "branch": "<branch-name>",
  "monoMessage": "<optional: commit message for the mono repo commit>",
  "repos": [
    { "name": "chrono-app",  "message": "<commit message>" },
    { "name": "chrono-api",  "message": "<commit message>" }
  ]
}
```

- `repos`: only include repos that actually have tracked-file changes. Can be empty `[]` when changes are mono root only.
- `monoMessage`: include when repos is empty or when the auto-generated message ("Updates submodule refs…") wouldn't describe the change accurately.

### 8. Run the script
```bash
bash .claude/scripts/ship.sh
```

The pre-ship hook fires automatically before this runs — it reads `ship-plan.json` and
only runs tests for repos listed in the plan. Unrelated dirty repos are not tested.
