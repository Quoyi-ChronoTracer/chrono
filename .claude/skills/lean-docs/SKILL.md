---
description: Apply when creating or editing any file that shapes Claude's context — CLAUDE.md, .claude/docs/*.md, .claude/agents/*.md, .claude/skills/*/SKILL.md, or README.md. Enforces lean, reference-driven documentation.
---

## The Lean Docs Principle

**Only write what Claude cannot figure out by reading the code itself.**

For each piece of information you're about to add, ask:

1. **Can this be inferred from folder structure or file names?** → Reference the path, don't describe it.
2. **Does a source file already define this?** (`package.json`, `requirements.txt`, `Package.swift`, `.env`, schema files, config files) → Point to that file, don't copy its contents.
3. **Is this needed in EVERY context when working in this repo, or only sometimes?** → If only sometimes, omit it — Claude can read the source when needed.
4. **Is this a non-obvious pattern, gotcha, or critical rule not visible from the code?** → This belongs.
5. **Is this a command or invocation that can't be inferred?** → This belongs.

### What belongs
- Dev commands
- Non-obvious architectural patterns and the reason they exist
- Critical safety rules and gotchas
- Pointers to the right files for deeper context

### What does not belong
- Dependency lists → `package.json`, `requirements.txt`, `Package.swift`
- Env var names and values → `.env`, `env.ts`, config files
- Directory trees → Claude can glob or ls
- Anything that duplicates what's already in the codebase

---

## Splitting Context for Independent Agent Work

Some information is too deep or specific for a general context doc, but legitimately needed
for certain tasks. Split it into its own reference doc and note when an agent should load it.

**When to split:**
- The content is only needed for one category of task (e.g. "deep filter schema work", "DB migration authoring", "OCR pipeline tuning")
- The content is large enough that loading it every session wastes context budget
- The task is self-contained enough that a sub-agent could own it end-to-end

**How to reference in the parent doc:**
```markdown
## Deep Context (load when needed)
- Filter payload schema (full) → `.claude/docs/filter-schema.md`
  _Load this when building, modifying, or debugging event filters._
- DB migration authoring → `.claude/docs/db-migrations.md`
  _Spawn a sub-agent with this doc when writing or reviewing SQL migrations._
```

---

## Final review pass

Read back every line you've written. If removing it wouldn't cause Claude to make a
mistake, remove it. The goal is the smallest doc that gives Claude everything it truly
needs and nothing it can get elsewhere.
