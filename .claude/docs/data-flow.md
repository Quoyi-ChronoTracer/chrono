# Cross-Component Data Flow

How the five ChronoTracer components connect. All components run inside a single AWS account per customer — no cross-account data flow.

```
                          ┌──────────────────┐
                          │   chrono-devops   │
                          │  (provisions all) │
                          └──────────────────┘

┌────────────┐  REST (JWT)   ┌────────────┐  asyncpg (r/w)  ┌───────────┐
│ chrono-app │──────────────▶│ chrono-api │────────────────▶│ RDS Aurora│
│  (React)   │               │  (Lambda)  │◀─ ─ ─ ─ ─ ─ ─ ─│ PostgreSQL│
└────────────┘               └────────────┘                 └───────────┘
      │                        │        │                        ▲
      │ WebSocket              │        │ signed URLs            │ asyncpg
      ▼                        │        ▼                        │ (upload)
┌──────────────────┐           │     ┌──────┐              ┌────────────────┐
│chrono-filter-ai  │           │     │  S3  │◀────────────▶│chrono-pipeline │
│    -api          │           │     │      │  read/write   │      -v2       │
│ (FastAPI + ECS)  │           │     └──────┘              │ (Step Fns+ECS) │
└──────────────────┘           │        ▲                  └────────────────┘
      │         │              │        │                        ▲
      │         │              │ trigger (Step Functions)        │
      │         │              └────────────────────────────────┘
      │         ▼
      │   ┌───────────┐
      │   │AWS Bedrock│
      │   │  (Claude) │
      │   └───────────┘
      │
      │  read-only queries
      └──────────────────▶ RDS Aurora PostgreSQL (same instance)
```

## Connections

| Source | Target | Protocol | Direction | Purpose | Key reference |
|---|---|---|---|---|---|
| chrono-app | chrono-api | REST via API Gateway HTTP | request/response | All CRUD, auth, data queries | `chrono-app/src/api/client.ts` |
| chrono-app | chrono-filter-ai-api | WebSocket via API Gateway WS | bidirectional | NL → structured event filters (AI chat) | `chrono-app/src/contexts/AIChatContext/` |
| chrono-api | RDS Aurora PostgreSQL | asyncpg (TCP) | read/write | All data persistence | `chrono-api/Sources/ChronoAPI/Services/Requests/DatabaseHandler.swift` |
| chrono-api | S3 | AWS SDK | write (signed URLs) | Evidence file uploads (admin-only) | `chrono-api/Sources/ChronoAPI/Services/Handlers/` |
| chrono-api | chrono-pipeline-v2 | AWS Step Functions API | trigger | Kicks off pipeline processing | `chrono-api/Sources/ChronoAPI/Services/Handlers/StepFunctionsHandler` |
| chrono-pipeline-v2 | S3 | AWS SDK | read/write | Reads `chronotracer_sources`, writes `chronotracer_artifacts` | `chrono-pipeline-v2/aws/` |
| chrono-pipeline-v2 | RDS Aurora PostgreSQL | asyncpg (TCP) | write | Uploads processed events, devices, identities | `chrono-pipeline-v2/uploader.py` |
| chrono-filter-ai-api | RDS Aurora PostgreSQL | asyncpg (TCP) | read-only | Queries events/entities for AI filter generation | `chrono-filter-ai-api/chrono_query/`, `chrono-filter-ai-api/mcp_tools/` |
| chrono-filter-ai-api | AWS Bedrock | AWS SDK | request/response | LLM inference (Claude) for NL → filter | `chrono-filter-ai-api/main.py` |
| chrono-devops | all components | Terraform | provisioning | VPC, RDS, S3, Lambda, ECS, API Gateway, Auth0 | `chrono-devops/environments/`, `chrono-devops/output/` |

## Non-Obvious Boundaries

- **Pipeline does not go through chrono-api to write data.** The uploader (`chrono-pipeline-v2/uploader.py`) connects directly to PostgreSQL via `asyncpg` and bulk-inserts using `UNNEST`. This is intentional — it avoids the API's per-request overhead for high-volume batch writes.
- **Pipeline processing is stateless.** Pipeline steps read from S3 and write to S3. Only the upload phase (final step) touches the database. This keeps processing decoupled from the DB schema.
- **chrono-filter-ai-api is strictly read-only against the DB.** It queries via MCP tools in `mcp_tools/` — never writes. DB config comes from AWS SSM/Secrets Manager, not env vars.
- **Two paths to PostgreSQL exist.** chrono-api (Lambda, read/write) and chrono-pipeline-v2 (ECS, write-only upload) both connect directly. chrono-filter-ai-api is the third path (ECS, read-only). All use the same `chrono_api` DB user.
- **Auth boundary.** JWT validation happens at API Gateway, not in application code. chrono-api reads claims from the gateway context. Pipeline and filter-ai-api run within the VPC with no external auth — they are not user-facing.
