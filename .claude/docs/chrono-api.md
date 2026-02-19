# chrono-api
Swift AWS Lambda REST API. PostgreSQL with row-level security.

## Commands
```bash
# Build (first time: docker build -t swift-lambda-builder . )
./Scripts/build.sh

# Test — requires full Xcode, not just CLT
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClassName.methodName

# Database
./Scripts/create_local_database.sh          # one-time local setup
./Scripts/deploy_migration.sh <environment>
./Scripts/deploy_api.sh <environment>
```

## Key Patterns
- **DatabaseQueryable protocol**: All models implement this — follow the existing pattern when adding new models.
- **Handler pattern**: Complex operations have dedicated handlers in `Services/Handlers/`. Read existing ones before implementing anything new.
- **Row-level security**: Enforced in PostgreSQL, flows through auth helpers — never bypass.
- **Tests are strict**: Refuse to run against remote DBs. Truncate tables between runs. Requires non-superuser `chrono_api` role to properly exercise RLS.

## References
- All routes → `Sources/ChronoAPI/APILambda.swift`
- Domain models → `Sources/ChronoAPI/Models/`
- Dependencies → `Package.swift`
- DB schema & history → `migrations/`
- All scripts → `Scripts/`

## Notes
- Apple Silicon + Docker Desktop: disable Rosetta acceleration.
