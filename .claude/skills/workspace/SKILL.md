---
name: workspace
description: User-invoked. Use /workspace <name> to create a full parallel worktree (parent + all submodules) for independent work. Use /workspace remove <name> to tear it down, /workspace list to see existing workspaces, or /workspace gc to remove stale workspaces older than 7 days.
argument-hint: <name> | remove <name> | list | gc
---

Route based on `$ARGUMENTS`:

- If `$ARGUMENTS` starts with `remove `: extract the workspace name and run:
  ```bash
  bash .claude/scripts/workspace.sh remove <name>
  ```

- If `$ARGUMENTS` is `list`: run:
  ```bash
  bash .claude/scripts/workspace.sh list
  ```

- If `$ARGUMENTS` is `gc`: run:
  ```bash
  bash .claude/scripts/workspace.sh gc
  ```

- Otherwise treat `$ARGUMENTS` as the workspace name and run:
  ```bash
  bash .claude/scripts/workspace.sh create <name>
  ```

If `$ARGUMENTS` is empty, ask for the workspace name with `AskUserQuestion`.

After a successful `create`, remind the user they can open a new Claude Code session in the workspace path.
