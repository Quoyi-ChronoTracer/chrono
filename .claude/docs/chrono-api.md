# chrono-api
Swift AWS Lambda REST API backend. Layered architecture over PostgreSQL.

## Tenant Isolation
- Each customer deployment is a **separate AWS account** with its own RDS, S3, and Lambda stack. There is no database-level multi-tenancy — RLS and `matter_id` were removed in Oct 2024.
- Auth is permission-based (`read`/`edit`/`admin`) via Auth0 JWTs → `Models/AuthorizedUser.swift`
- Within a deployment, all authenticated users with `read` see all data.

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
