---
name: deploy
description: User-invoked. Use /deploy <environment> to tag and deploy components to staging or production. Staging pushes RC tags directly; production triggers a GitHub Actions approval workflow.
argument-hint: <staging|production> [repo1,repo2,...]
---

# Deploy Components

Your job is the **intelligence** half of the deploy process — analysis, version decisions,
and user confirmation. The mechanics (tagging, pushing, GHA triggering) are handled by
`.claude/scripts/deploy.sh`. The validation gate fires automatically via
`.claude/hooks/pre-deploy.sh` before the script runs.

## Arguments

Parse from `$ARGUMENTS`:
- **Environment** (required): `staging` or `production`. If missing, use `AskUserQuestion` to ask for it.
- **Repo list** (optional): comma-separated repo names to limit scope (e.g. `chrono-api,chrono-app`). If omitted, deploy all 5 repos: `chrono-devops`, `chrono-api`, `chrono-pipeline-v2`, `chrono-app`, `chrono-filter-ai-api`.

## Your procedure

### 1. Determine target repos
If the user supplied a comma-separated repo list, use only those repos. Otherwise default
to all five component repos.

### 1b. Auto-include downstream repos

Apply the dependency graph to expand the target set with downstream repos that must
redeploy when an upstream changes infrastructure or APIs they depend on:

```
chrono-devops -> [chrono-api]
chrono-api    -> [chrono-app, chrono-pipeline-v2, chrono-filter-ai-api]
```

Compute the **transitive closure** — e.g. `chrono-devops` selected pulls in all four
downstream repos; `chrono-api` selected pulls in app, pipeline, and filter-ai.
Any tier-2 repo selected alone has no downstream dependencies.

For each auto-included repo, look up its **latest existing tag** (no version bump):
- **Staging**: latest `v*-rc.*` tag
- **Production**: latest stable `v*` tag (no `-rc`)

When presenting the table in step 3, annotate auto-included repos with `(auto-included)`.
The user may remove auto-included repos during confirmation — only user-selected repos
receive version bumps.

### 2. Query existing tags per repo
For each target repo, fetch and list existing version tags:
```bash
git -C <repo> fetch --tags
git -C <repo> tag --sort=-version:refname --list 'v*'
```
Parse out two values per repo:
- **Latest stable tag** — the highest tag matching `v{major}.{minor}.{patch}` with no pre-release suffix (e.g. `v1.4.2`)
- **Latest RC tag** — the highest tag matching `v{major}.{minor}.{patch}-rc.{N}` (e.g. `v1.4.3-rc.2`)

### 3. Propose version bumps
Default to a **patch bump** from the latest stable tag per repo. Present a table to the
user showing:

| Repo | Latest Stable | Proposed Tag | Note |
|------|---------------|--------------|------|
| chrono-devops | v1.2.3 | v1.2.4-rc.1 | |
| chrono-api | v2.4.9 | v2.4.10-rc.1 | |
| chrono-app | v3.1.0 | v3.1.0-rc.2 | (auto-included) |
| ... | ... | ... | |

Ask the user to **confirm or override** — they may want minor or major bumps for
user-selected repos, and may remove auto-included repos if desired.

### 4. Determine tag format by environment

#### Staging
- Tag format: `v{major}.{minor}.{patch}-rc.{N}`
- If proposing `v1.5.0` and `v1.5.0-rc.1` already exists, propose `v1.5.0-rc.2`
- Always increment the RC number from the highest existing RC for that version

#### Production
- Propose the stable version derived from the latest RC tag by stripping the `-rc.{N}` suffix
- e.g. if latest RC is `v1.5.0-rc.3`, propose `v1.5.0`
- **Warn and abort** if no RC tag exists for the proposed version — you cannot promote to production without staging first

### 5. Write the plan file
Create `.claude/tmp/deploy-plan.json` with the following structure:

```json
{
  "environment": "staging",
  "repos": [
    { "name": "chrono-devops", "tag": "v1.3.0-rc.1" },
    { "name": "chrono-api", "tag": "v2.5.0-rc.1" },
    { "name": "chrono-pipeline-v2", "tag": "v1.1.1-rc.1" },
    { "name": "chrono-app", "tag": "v3.1.0-rc.1" },
    { "name": "chrono-filter-ai-api", "tag": "v1.0.6-rc.1" }
  ]
}
```

- **Fixed deploy ordering**: devops → api → pipeline-v2 → app → filter-ai-api
- The `repos` array must always follow this order regardless of user input order
- Only include repos the user selected (or all five if no filter was given)

### 6. Run the deploy script
```bash
bash .claude/scripts/deploy.sh
```

The pre-deploy hook fires automatically before this runs — it validates the
`deploy-plan.json` schema and contents.

### 7. Post-deploy reminders
- **Staging**: no further action needed — RC tags are pushed and CircleCI pipelines trigger automatically.
- **Production**: remind the user that a **GitHub reviewer must approve** the deployment in the GitHub Actions UI after the workflow is triggered. The deploy is not complete until that approval is granted.
