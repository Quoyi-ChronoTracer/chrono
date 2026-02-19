## When to use this skill
Invoke `/lean-docs` any time you are about to **create or edit** a file that shapes Claude's
context: `CLAUDE.md`, `.claude/docs/*.md`, `.claude/agents/*.md`, `.claude/commands/*.md`,
or any `README.md` in this repo. Run it before writing, and again as a final review pass
before saving.

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

Some information is too deep or too specific to belong in a general context doc, but is
legitimately needed for certain tasks. The right pattern is to **split it into its own
reference doc and note when an agent should load it**.

**When to split into a separate doc:**
- The content is only needed for one category of task (e.g. "deep filter schema work",
  "database migration authoring", "OCR pipeline tuning")
- The content is large enough that loading it in every session would waste context budget
- The task it supports is self-contained enough that a sub-agent could own it end-to-end

**How to reference it in the parent doc:**
```markdown
## Deep Context (load when needed)
- Filter payload schema (full) → `.claude/docs/filter-schema.md`
  _Load this when building, modifying, or debugging event filters._
- DB migration authoring → `.claude/docs/db-migrations.md`
  _Load this when writing or reviewing SQL migrations for chrono-api._
```

**How to annotate agent-worthy tasks:**
If a section of work is cleanly delegatable, say so explicitly:
```markdown
- OCR benchmark analysis → `.claude/docs/ocr-benchmarks.md`
  _Spawn a sub-agent with this doc when asked to evaluate or compare OCR approaches._
```

This way the main context stays lean, Claude knows exactly what to load for a given task,
and complex sub-tasks can be handed to focused agents without polluting the parent context.

---

## Final review pass
Read back every line you've written. If removing it wouldn't cause Claude to make a
mistake, remove it. The goal is the smallest doc that gives Claude everything it truly
needs and nothing it can get elsewhere.
