---
name: ship
description: User-invoked. Use /ship <branch-name> to branch, commit, push, and open PRs across all dirty submodules and the mono repo. Works from the mono repo root (multi-repo) or from inside a single component (single-repo).
argument-hint: <branch-name>
---

# Ship Changes

Create branches, commit, push, and open PRs across all affected repos. Follow these conventions exactly.

## Arguments

Parse from `$ARGUMENTS`:
- Branch name (required, e.g. `ata/APP-297-pipeline-v2`)

If the branch name is missing, use `AskUserQuestion` to ask for it.

## Conventions

### Branch
- Use the exact branch name provided — do not modify it
- Create from current HEAD in each repo

### Staging
- Run `git status` in each dirty repo to review all changes
- Stage all modified and new files that are part of the work
- **Delete any scratch files, one-off scripts, or temporary artifacts** created during the session before staging — don't leave local bloat behind
- Trust `.gitignore` to handle the rest

### Commit Message
- **Auto-generated** — run `git diff --cached` in each repo and analyze the staged diff to write the message
- **Single line only** — no multi-line descriptions, no conventional commit prefixes (`chore:`, `feat:`, etc.)
- **Present third-person tense** — e.g. "Migrates ship command to skills structure", "Adds OCR extraction step", "Fixes date parsing in event deduplicator"
- Summarize the *what*, not the *why*

### Pull Request
- **Title**: Same as the commit message
- **Body**: Use this template:

```markdown
## Summary
<2-4 bullet points summarizing the changes at a high level>

## Changes

### <Component or Area>
- <specific change>
- <specific change>

## Tests
- <what test files were added/modified, or "No tests required — config/docs change">

## Test plan
- [ ] <feature-specific verification steps>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- Base branch: `develop` for all submodule PRs. `main` for the mono repo PR.
- Reviewers: always add `--reviewer ata-peppered,DexterW,jessicaribeiroalves,copilot` to every `gh pr create` call.

## Procedure

### From the mono repo root (multi-repo ship)

1. **Discover scope**: Run `git status --short` in the parent, then `git -C <path> status --short` for each submodule. Build `DIRTY_SUBMODULES` (ignore `.DS_Store`-only diffs) and `PARENT_CHANGES`.

2. **Confirm**: Print a summary of which repos have changes and what files are affected. Pause if anything looks unexpected.

3. **For each dirty submodule**:
   - `git status` and `git diff` to review changes
   - Delete any scratch files or temp artifacts
   - `git checkout -b <branch-name>` (or switch if already exists)
   - Stage relevant files
   - `git diff --cached` to analyze the staged diff
   - Write a single-line, present third-person commit message from the diff
   - Commit and push
   - `gh pr create` with the title, detailed body, base `develop`, and `--reviewer ata-peppered,DexterW,jessicaribeiroalves,copilot`

4. **Update the mono repo** (if root-level files changed or submodule refs need bumping):
   - Stage updated gitlinks and any changed root files (CLAUDE.md, .claude/, README.md)
   - `git diff --cached` to analyze
   - Write a single-line commit message summarizing the platform-level changes
   - Commit, push, `gh pr create` with base `main`, `--reviewer ata-peppered,DexterW,jessicaribeiroalves,copilot` — include links to all component PRs in the body

5. **Report**: Print a summary table:

| Repo | Branch | PR |
|---|---|---|
| chrono-app | feature/APP-XXX | https://github.com/... |
| chrono (mono) | feature/APP-XXX | https://github.com/... |

### From inside a single component directory

Same procedure, single repo only. Skip step 4 entirely.
