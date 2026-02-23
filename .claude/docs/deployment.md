# Deployment Architecture

ChronoTracer runs a **single-tenant-by-deployment** model: one AWS account per customer,
each with a fully isolated infrastructure stack.

---

## Account-Per-Customer Model

Each customer (and each non-prod environment) gets a dedicated AWS account declared in
`chrono-devops/environments/<env>.yaml`. Terraform generates a complete stack per account
in `chrono-devops/output/<env>/<account-name>/`.

**What each account contains:**
- VPC with private subnets and network firewall
- RDS Aurora PostgreSQL cluster (single `chrono` database, single `chrono_api` user with `GRANT ALL`)
- S3 buckets: `chronotracer_sources`, `chronotracer_artifacts`, `chronotracer_inventory`, `chronotracer_reports`
- Lambda functions (chrono-api), ECS services, Step Functions pipelines (chrono-pipeline-v2)
- API Gateway v2 HTTP (HTTPS-only, chrono-api) + API Gateway v2 WebSocket (chrono-filter-ai-api)
- CloudFront distribution (TLS 1.2+, redirect-to-https)
- Auth0 tenant (per-account subdomain)
- CloudTrail + WAF logging to dedicated S3 buckets

**No data crosses account boundaries.** There is no shared database, no cross-account S3 access,
and no central data lake. Each customer's evidence is physically isolated.

## Authentication Flow

1. Frontend (`chrono-app`) authenticates via Auth0 → receives JWT
2. JWT is validated by API Gateway's JWT authorizer (not application code)
3. `chrono-api` Lambda reads claims from `request.context.authorizer.jwt.claims`
4. `AuthorizedUser.swift` parses permissions: `read`, `edit`, `admin`
5. `DatabaseHandler` checks required permissions before executing any handler
6. `DatabaseHandler` sets `audit.user_id` and `audit.user_name` as PostgreSQL session variables for audit triggers

**Within a deployment, all users with `read` permission see all data.** There is no sub-tenant
or matter-level scoping — that was removed in Oct 2024.

**Structural risk:** The `APIGatewayRequestHandler` base class does not enforce auth by default.
Only `DatabaseHandler` (subclass) and `withAuth()` (wrapper) enforce auth. A handler using the
base class directly will silently skip auth.

## Database

- **Engine:** Aurora PostgreSQL (encrypted at rest via `storage_encrypted = true`, default KMS)
- **Connection from Lambda:** `tls: .disable` — accepted trade-off since all DB traffic stays within the private VPC subnet
- **Users:** Single `chrono_api` user with full access. No per-role or per-user DB accounts.
- **Audit:** PostgreSQL trigger-based (`audit.record_versions`), fires on INSERT/UPDATE/DELETE on core tables. User context injected via session variables.
- **No RLS.** Row-level security and `matter_id` were fully removed in Oct 2024 (migrations `20241015*`, `20241023*`).

## S3 Storage

- All buckets use SSE-S3 (AES256). No KMS keys defined.
- Evidence uploads go to `chronotracer_sources` via signed URLs (admin permission required).
- Pipeline artifacts (OCR output, extracted events) go to `chronotracer_artifacts`.
- An IAM user (`s3uploader`) with long-lived access keys handles uploads. Keys stored in SSM as plaintext strings (known gap).

## Pipeline (Step Functions)

- Triggered via chrono-api (`StepFunctionsHandler`, admin permission required)
- Runs in the same AWS account as the customer's stack
- **Pipeline runs** read from `chronotracer_sources` and write to `chronotracer_artifacts` — they do not connect to the database. This separation keeps the pipeline stateless and avoids coupling processing stages to the DB schema.
- **The scheduler** (dat file processing engine) is the component that writes processed results to RDS. This is an intentional architectural boundary — challenge this assumption if needed, but understand the reasoning before changing it.
- Python-based stages: archive extraction, OCR, entity mapping, event creation

## Environments

| Environment | Config | Accounts |
|---|---|---|
| develop | `environments/develop.yaml` | `chrono-dev`, `dev-3` |
| staging | `environments/staging.yaml` | `chrono-demo`, `chrono-staging` |
| prod | `environments/prod.yaml` | `sdm-anaipakos-alavi` |

Terraform output exists in the repo for staging only. Prod infrastructure state is not
checked in (managed separately or not yet committed).

## CI/CD

All environments deploy through the same event-driven cascade model.

### Deploy Chain

```
Component repo event → notify-deploy.yml → mono repo deploy-<env>.yml → CircleCI pipelines
```

Each component repo has a `notify-deploy.yml` workflow that fires on:
- **Branch push** (develop) → dispatches `develop-deploy` to mono repo
- **RC tag push** (vX.Y.Z-rc.N) → dispatches `staging-deploy` to mono repo
- **Stable tag push** (vX.Y.Z) → dispatches `production-deploy` to mono repo

### Dependency Graph and Cascade

All environments use the same tier ordering:
- **Tier 0:** chrono-devops (infra) — downstream: all
- **Tier 1:** chrono-api (backend) — downstream: tier 2
- **Tier 2:** chrono-pipeline-v2, chrono-app, chrono-filter-ai-api (leaf nodes)

The source repo determines cascade scope: devops cascades to all, api cascades to
api + tier 2, edge services deploy only themselves.

What differs per environment is **which version** downstream repos deploy:
- **Develop:** HEAD of `develop` branch
- **Staging:** repo's latest RC tag (looked up via GitHub API)
- **Production:** repo's latest stable tag (looked up via GitHub API)

If a downstream repo has no tag for the target environment, the cascade fails.

### Promote Workflows

Staging and production promotions are initiated via `workflow_dispatch`:
- `promote-staging.yml` — validates RC tags, requires approval, pushes tags
- `promote.yml` — validates stable tags, verifies RC prerequisite, requires approval, pushes tags

Tag pushes trigger `notify-deploy.yml` in each component, which starts the cascade.
The promote workflows do **not** trigger CircleCI directly.

### CI Systems

| Component | CI System | PR Gate? |
|---|---|---|
| chrono-app | GitHub Actions | Yes (lint + test) |
| chrono-api | CircleCI | No |
| chrono-pipeline-v2 | CircleCI | No (Claude review on PR only) |
| chrono-filter-ai-api | CircleCI | No |
| chrono-devops | CircleCI | No |

### Tag Protection

All 5 component repos have tag rulesets restricting `v*` tag pushes to Deploy Bot App only.

## References

- Account definitions → `chrono-devops/environments/*.yaml`
- Account creation script → `chrono-devops/scripts/create_accounts.py`
- Terraform per-account stacks → `chrono-devops/output/<env>/<account>/`
- Auth model → `chrono-api/Sources/ChronoAPI/Models/AuthorizedUser.swift`
- DB connection config → `chrono-api/Sources/ChronoAPI/Services/Requests/DatabaseHandler.swift`
- Audit trigger migration → `chrono-api/migrations/20220826165921*`
- RLS removal migrations → `chrono-api/migrations/20241015*`, `20241023*`
