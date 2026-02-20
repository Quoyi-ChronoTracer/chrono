# chrono-api
Swift AWS Lambda REST API backend. Layered architecture over PostgreSQL.

## Key Patterns
- **DatabaseQueryable protocol**: All models implement this — follow the existing pattern when adding new models.
- **Handler pattern**: Complex operations have dedicated handlers in `Services/Handlers/`. Read existing ones before implementing anything new.
- **Tests run automatically via hook** — see `.claude/settings.json`. Output surfaces directly in Claude Code.

## References
- All routes → `Sources/ChronoAPI/APILambda.swift`
- Domain models → `Sources/ChronoAPI/Models/`
- Dependencies → `Package.swift`
- DB schema & history → `migrations/`
- Scripts → `Scripts/`

## Notes
- Apple Silicon + Docker Desktop: disable Rosetta acceleration.
- Tests require full Xcode (not CLT) — the hook handles this, but if running manually see `Scripts/` or prior migration context.
