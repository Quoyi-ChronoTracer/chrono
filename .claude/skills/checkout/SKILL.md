---
name: checkout
description: User-invoked. Use /checkout <branch-name> to switch all submodules and the mono repo to the named branch. Creates the branch from current HEAD in any repo where it doesn't exist yet.
argument-hint: <branch-name>
---

Parse the branch name from `$ARGUMENTS`. If missing, ask for it with `AskUserQuestion`.

Run the checkout script:

```bash
bash .claude/scripts/checkout.sh <branch-name>
```
