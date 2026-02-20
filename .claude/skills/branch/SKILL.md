---
name: branch
description: User-invoked. Use /branch <branch-name> to create and checkout a new branch across the mono repo and all submodules.
argument-hint: <branch-name>
---

Parse the branch name from `$ARGUMENTS`. If missing, ask for it with `AskUserQuestion`.

Run the branch script:

```bash
bash .claude/scripts/branch.sh <branch-name>
```
