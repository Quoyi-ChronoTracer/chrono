## When to use this skill
Invoke `/ship <branch-name>` when changes are ready to commit and PR — either across
multiple submodules from the mono repo root, or within a single component directory.
Handles branching, committing, pushing, and opening PRs automatically.

---

## Arguments
`$ARGUMENTS` — branch name (required). Optionally followed by a short description for
the PR title. If a ticket number appears in the branch name (e.g. `APP-297`), use it in
commit messages and PR titles.

---

## Step 1 — Discover what's dirty

**From the mono repo root (`/chrono`):**
- `git status --short` in the parent to find root-level file changes and submodule ref changes
- `git -C <path> status --short` for each submodule
- Build:
  - `DIRTY_SUBMODULES` — submodules with uncommitted changes (ignore `.DS_Store`-only diffs)
  - `PARENT_CHANGES` — root-level changed files (CLAUDE.md, .gitmodules, .claude/, etc.)

**From inside a single component directory:**
- Single-repo ship only. Skip parent repo update entirely.

---

## Step 2 — Confirm before acting

Print a summary of which repos have changes, what files are affected, and the branch name
that will be used. Pause and confirm with the user if anything looks unexpected.

---

## Step 3 — Ship each dirty submodule

For each repo in `DIRTY_SUBMODULES`:

```bash
cd <submodule-path>
git checkout -b <branch-name> 2>/dev/null || git checkout <branch-name>
git add -A
git commit -m "<APP-XXX: Description in present third-person tense>"
git push -u origin <branch-name>
gh pr create \
  --title "<APP-XXX: Description>" \
  --body "$(cat <<'EOF'
## Summary
<bullet points of what changed>

## Part of
<links to related PRs in other components if applicable>

🤖 Generated with [Claude Code](https://claude.ai/claude-code)
EOF
)" \
  --base develop
```

---

## Step 4 — Update the parent repo

After all submodule PRs are created:

```bash
cd <mono-repo-root>
git checkout -b <branch-name> 2>/dev/null || git checkout <branch-name>
git add <each-dirty-submodule-path>       # updated gitlink refs
git add CLAUDE.md .claude/ README.md      # only files that actually changed
git commit -m "chore: ships <branch-name> across [component list]"
git push -u origin <branch-name>
gh pr create \
  --title "chore: <branch-name> — platform ref update" \
  --body "$(cat <<'EOF'
## Component PRs
<list each PR with link>

## Summary
Updates submodule references and any shared AI tooling changes.

🤖 Generated with [Claude Code](https://claude.ai/claude-code)
EOF
)" \
  --base main
```

Skip this step if there are no root-level changes and the submodule ref bump adds no
meaningful value (e.g. a trivial single-component fix).

---

## Step 5 — Print summary

| Repo | Branch | PR |
|---|---|---|
| chrono-app | feature/APP-XXX | https://github.com/... |
| chrono (mono) | feature/APP-XXX | https://github.com/... |
