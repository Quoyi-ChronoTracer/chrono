# Plan: SessionStart Hook — Mono Repo State Injection

## Context

The mono repo's submodule architecture already has skills for every explicit operation (`/ship`, `/pull`, `/branch`, `/checkout`, `/workspace`), and CLAUDE.md already states "Always work in a worktree." But nothing **enforces or assists** with that policy at session start. Claude begins every session blind — no idea which branches repos are on, whether there's uncommitted work, or if it's inside a worktree. Engineers face the same gap: they have to remember the workflow rather than being guided into it.

The `SessionStart` hook (Claude Code feature) fires on every new session and can inject `additionalContext` into Claude's context. This is the right mechanism — it gives Claude live repo state on startup so it can proactively guide the session.

**Why not auto-create a workspace every session?** The `SessionStart` hook fires *after* the working directory is set — it cannot redirect Claude into a different directory. Auto-creating worktrees would also accumulate orphans and add startup latency. Instead, the hook **surfaces the need** and Claude suggests `/workspace` proactively.

---

## Files to create

| File | Purpose |
|---|---|
| `.claude/hooks/on-session-start.sh` | SessionStart hook: injects branch alignment, dirty state, worktree status |

## Files to modify

| File | Change |
|---|---|
| `.claude/settings.json` | Add `SessionStart` hook entry (leave `PreToolUse` untouched) |
| `CLAUDE.md` | Add `## Session Startup` section with action table for Claude |

---

## Design: `on-session-start.sh`

```
Input:  JSON on stdin with source, cwd, session_id
Output: JSON on stdout: { "additionalContext": "<markdown>" }
Gate:   Only on source=startup (skip resume/clear/compact)
Speed:  No network calls — local git only (~200ms)
```

**What it collects:**
1. Parent branch (`git branch --show-current`)
2. Per-submodule: branch name, dirty file count, untracked count
3. Branch mismatches (submodule ≠ parent, but only when parent is on a feature/fix/chore branch — submodules on `develop` while parent is on `develop`/`main` is normal)
4. Whether the session is inside a worktree (CWD starts with `.claude/worktrees/`)
5. Active workspaces listed from `.claude/worktrees/`

**Output example:**

```markdown
## Mono Repo State (session start)

**Parent branch**: `feature/APP-301-ocr-redesign`
**In worktree**: no

| Submodule | Branch | Dirty | Untracked |
|---|---|---|---|
| chrono-app | feature/APP-301-ocr-redesign | 0 | 0 |
| chrono-api | develop **MISMATCH** | 2 | 1 |
| chrono-pipeline-v2 | feature/APP-301-ocr-redesign | 0 | 0 |
| chrono-filter-ai-api | develop | 0 | 0 |
| chrono-devops | develop | 0 | 0 |

### Branch mismatches detected
- `chrono-api` is on `develop` but parent is on `feature/APP-301-ocr-redesign`
Use `/checkout feature/APP-301-ocr-redesign` to align all repos.

### Note
This session is in the **main checkout**, not a worktree. If you plan to make code changes, suggest `/workspace <name>` first.
```

**Patterns reused from existing scripts:**
- `SUBMODULES` array (same as `workspace.sh`, `branch.sh`, `checkout.sh`, `ship.sh`)
- `SCRIPT_DIR` / `MONO_ROOT` derivation (but using `HOOK_DIR` since it lives in `hooks/`)
- `git status --porcelain` for dirty detection (same as `ship.sh:125`)
- JSON stdin parsing with `jq` (same as `pre-ship.sh:30`)
- JSON output via `jq -Rs` for safe string encoding

**Mismatch logic:**
- Only flag mismatches when parent is NOT on `develop` or `main` (those are the normal idle states per `.gitmodules`)
- When parent is on a feature branch, any submodule not on that same branch is flagged

---

## Design: `settings.json` change

Add `SessionStart` key alongside existing hooks. Do NOT touch the existing `PreToolUse` array.

**Current** (on `main`):
```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "...pre-ship.sh" },
        { "type": "command", "command": "...pre-deploy.sh" }
      ]}
    ]
  }
}
```

**After** (add only):
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/on-session-start.sh"
          }
        ]
      }
    ],
    "PreToolUse": [ ... unchanged ... ]
  }
}
```

Empty matcher means it fires for all session events; the script gates on `startup` internally.

---

## Design: `CLAUDE.md` change

Add a `## Session Startup` section after `## Session Workflow` and before `## Engineering Principles`. This tells Claude what to do with the hook's output.

```markdown
## Session Startup

A `SessionStart` hook injects live **Mono Repo State** into context on every new session:
branch names, dirty file counts, mismatch warnings, and worktree status.

| Signal | Action |
|---|---|
| Branch mismatch detected | Suggest `/checkout <parent-branch>` before making changes |
| Not in a worktree + code changes planned | Suggest `/workspace <name>` before editing files |
| Submodule has dirty files | Mention it if relevant to the current task |
| Everything aligned, in worktree | Proceed normally |

Do not repeat the full state table to the user — reference specific issues only.
```

Also update the `.claude/` directory tree in the `## AI Tooling` section to include the hooks directory:

```
.claude/
├── settings.json
├── settings.local.json
├── hooks/
│   ├── pre-ship.sh            # test gate before ship
│   ├── pre-deploy.sh          # validation before deploy
│   └── on-session-start.sh    # injects repo state on session start
├── skills/ ...
├── agents/ ...
└── docs/ ...
```

And add an optional `claude-ws` alias note for engineers who want full auto-workspace:

```markdown
### Auto-workspace alias (optional, per-engineer)

Add to `~/.zshrc` for one-command isolated sessions:

    claude-ws() {
      local name="${1:-ws-$(date +%s)}"
      bash ~/chrono/.claude/scripts/workspace.sh create "$name"
      cd ".claude/worktrees/$name" && claude
    }
```

---

## Verification

1. Pipe simulated startup JSON into the hook — verify valid JSON output with markdown table
2. Pipe `resume` source — verify empty `{}` output
3. Put one submodule on a different branch — verify mismatch flagged
4. Start a fresh Claude Code session — verify context injection appears
5. Confirm existing `/ship` and `/deploy` hooks still work (PreToolUse untouched)
