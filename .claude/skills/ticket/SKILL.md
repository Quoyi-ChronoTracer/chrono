---
name: ticket
description: Fetch a Linear ticket by identifier or keyword search. Displays ticket details, derives a branch name, and optionally scaffolds tasks.
argument-hint: <APP-XXX or search terms>
---

# Fetch Linear Ticket

Look up a Linear ticket and present its details, derive a branch name, and optionally scaffold a task list.

## Arguments

Parse from `$ARGUMENTS`:
- Either a ticket identifier (e.g. `APP-297`) or free-text search terms

## Procedure

### 1. Fetch the ticket

**If `$ARGUMENTS` matches `APP-\d+`:**
- Use the Linear MCP `get_issue` tool to fetch the ticket by identifier

**Otherwise (free-text search):**
- Use the Linear MCP `list_issues` tool with the provided search terms
- If multiple results, display a numbered list and ask the user to pick one
- If no results, inform the user and stop

If the MCP call fails (not authenticated, server unavailable), instruct the user to run
`/mcp` to complete the one-time Linear OAuth setup, then stop.

### 2. Display ticket details

```
APP-XXX: <title>
Status: <workflow state>    Priority: <priority>    Assignee: <assignee name or "Unassigned">

<description — render markdown as-is>

Acceptance Criteria:
<if present, list each criterion>
```

### 3. Derive branch name

Based on the ticket title and identifier, derive a branch name following project convention:

- `feature/APP-XXX-short-kebab-description` — default
- `fix/APP-XXX-...` — if labels include "bug" or the title suggests a fix
- `chore/APP-XXX-...` — for non-functional tasks (infra, docs, refactoring)

Present the suggested branch name and ask the user to confirm or modify.

### 4. Scaffold tasks (optional)

Ask: "Want me to scaffold `tasks/todo.md` from the acceptance criteria? If so, which component?"

If the user picks a component, create `<component>/tasks/todo.md`:

```markdown
# APP-XXX: <ticket title>

- [ ] <criterion 1>
- [ ] <criterion 2>
- [ ] ...
```

If the user declines, skip this step.
