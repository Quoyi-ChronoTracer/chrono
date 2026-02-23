# ChronoTracer — Claude Code Guide

**ChronoTracer** is an enterprise evidence processing platform: it ingests and processes
device data (emails, calls, messages, documents), runs OCR and entity resolution, and
presents an AI-powered timeline UI for analyzing evidence.

## Components

| Directory | Stack | Purpose |
|---|---|---|
| `chrono-app` | React 19 + TypeScript + Vite | Frontend timeline UI |
| `chrono-api` | Swift + AWS Lambda + PostgreSQL | REST API backend |
| `chrono-pipeline-v2` | Python + AWS | Data ingestion, OCR, entity mapping |
| `chrono-filter-ai-api` | Python + FastAPI + AWS Bedrock | NL → event filter AI service |
| `chrono-devops` | Terraform + Docker + CircleCI | Infrastructure and deployment |

> `chrono-pipeline/` is a legacy v1 directory — not a submodule, ignore it.

---

## Session Workflow

**Always work in a worktree.** At the start of every session that will produce code changes,
create a worktree before making any edits. This keeps the main working tree clean and
isolates in-progress work.

A `SessionStart` hook automatically injects repo state at the beginning of every session.
Use the table below to decide what action to take based on the signals:

| Signal | Action |
|---|---|
| **Not in worktree** | Run `/workspace <name>` before making any code changes. Edit/Write calls to code files will be blocked until you do. |
| **Branch mismatch** | A submodule is on a different branch than the parent. Run `/checkout <branch>` to realign. |
| **Ref drift** | A submodule HEAD doesn't match the parent's recorded ref. Run `/pull` to sync. |
| **Dirty submodule** | Uncommitted changes exist. Decide whether to commit (`/ship`) or stash before switching context. |
| **3+ active workspaces** | Suggest `/workspace gc` or `/workspace remove <name>` to clean up stale ones. |
| **All clean** | Proceed normally. |

---

## Engineering Principles

1. **Plan first.** For non-trivial tasks: read relevant files, write a plan to `tasks/todo.md` in the affected component, check in before coding.
2. **Small changes.** Break big problems into many small ones. Avoid large sweeping changes in one pass.
3. **Test and lint before done.** See each component doc for exact commands.
4. **Root causes only.** Never apply bandaids. Find and fix the underlying issue.
5. **Clean, DRY code.** Write tests for new code. Touch as little existing code as possible.
6. **Comments are guidance, not noise.** Only comment where logic is non-obvious.
7. **No `any` in TypeScript.** Strict types everywhere in `chrono-app`.
8. **Never be lazy.** Complete tasks fully, don't skip steps.

---

## Branch & Commit Convention

```
feature/APP-XXX-short-description
fix/APP-XXX-short-description
chore/APP-XXX-short-description
```

Commit messages: `APP-XXX: Short description in present third-person tense`
- `APP-297: Adds pipeline v2 OCR extraction step`
- `APP-123: Fixes event deduplication for overlapping time ranges`

PRs always target `develop` in each component repo.

---

## Submodule Workflow

Treat this as a single repo. Use the skills and scripts below — they propagate every operation across all submodules automatically.

```bash
# First-time clone
git clone --recurse-submodules https://github.com/Quoyi-ChronoTracer/chrono.git
```

| Operation | Skill | Script |
|---|---|---|
| Pull latest | `/pull` | `bash .claude/scripts/pull.sh` |
| Create branch | `/branch <name>` | `bash .claude/scripts/branch.sh <name>` |
| Switch branch | `/checkout <name>` | `bash .claude/scripts/checkout.sh <name>` |
| Commit + push + PR | `/ship <name>` | `bash .claude/scripts/ship.sh` |

---

## AI Tooling

All Claude Code config lives in `.claude/` in this repo and is shared across the team.

```
.claude/
├── settings.json              # Shared permissions baseline (committed)
├── settings.local.json        # Per-engineer overrides (gitignored)
├── skills/
│   ├── ship/SKILL.md          # /ship — commit, push, and open PRs across dirty repos
│   ├── branch/SKILL.md        # /branch — create branch across all repos
│   ├── checkout/SKILL.md      # /checkout — switch branch across all repos
│   ├── pull/SKILL.md          # /pull — pull latest across all repos
│   └── lean-docs/SKILL.md     # auto-invoked when editing any context doc
├── agents/
│   └── code-reviewer.md       # Cross-stack code review agent
└── docs/                      # Component knowledge base (loaded on demand)
    └── *.md
```

### `/ship <branch-name>`

Detects all dirty submodules, commits, pushes, and opens individual PRs in each component
repo, then updates the parent's submodule refs and opens a PR there too.
From inside a single component directory: behaves as a single-repo ship.

---

## Component Docs

Before working in a component, read its doc for commands, architecture, and gotchas:

- **chrono-app** → `.claude/docs/chrono-app.md`
- **chrono-api** → `.claude/docs/chrono-api.md`
- **chrono-pipeline-v2** → `.claude/docs/chrono-pipeline-v2.md`
- **chrono-filter-ai-api** → `.claude/docs/chrono-filter-ai-api.md`
- **chrono-devops** → `.claude/docs/chrono-devops.md`

## Cross-Cutting Docs

- **SOC 2 Compliance** → `.claude/docs/compliance.md`
  _Load when reviewing PRs, adding API endpoints, modifying auth/access, or handling evidence data._
- **Deployment Architecture** → `.claude/docs/deployment.md`
  _Load when working on infrastructure, auth, database, CI/CD, or cross-component integration._
- **Data Flow** → `.claude/docs/data-flow.md`
  _Load when working on cross-component integration, debugging data flow, or understanding how components connect._
