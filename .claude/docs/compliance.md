# SOC 2 Compliance — Dev Rules

ChronoTracer holds SOC 2 Type II. Policies live in Vanta. This doc covers
the dev-actionable rules that must be enforced in code.

> **Known gaps** are marked with `⚠ GAP` — these are areas where the codebase does not
> yet meet the stated policy. Fixing these is tracked work, not aspirational. Do not
> introduce new violations in these areas, and flag them in code review.

---

## PII & Evidence Data

Evidence data (emails, calls, messages, documents, device metadata) is PII.

- **Never log evidence content or user-identifying fields** (email addresses, phone numbers, names, device IDs) — not in application logs, error messages, or API responses.
- **Never return raw evidence data in error payloads.** Errors must use opaque IDs only.
- **Mask or redact PII in non-production environments.** Test fixtures must use synthetic data, never copies of real evidence.
- Structured evidence metadata (event counts, date ranges, file types) is safe to log.

> **Note:** `chrono-filter-ai-api` logging is not directly accessible to Claude and is lower priority,
> but new code in this service should still follow the PII rules above.

## Secrets Management

- **Only approved sources:** AWS SSM Parameter Store and AWS Secrets Manager.
- **Never hardcode** secrets, API keys, tokens, connection strings, or passwords — not in code, config files, env files, CI scripts, or Terraform variables.
- `.env` files are for local dev only and must be in `.gitignore`. Never commit them.
- Rotate secrets through Secrets Manager, not by editing code.

> ⚠ GAP: `chrono-app/.env` is tracked in git containing a Sentry DSN and AG Grid license key. The `.gitignore` covers `.env.*` but not bare `.env`.
>
> ⚠ GAP: Sensitive SSM parameters in chrono-devops use `type = "String"` (plaintext) instead of `SecureString` — see `database.tf` and `s3_buckets.tf`.

## Audit Logging

Audit logging uses PostgreSQL triggers on core tables (`audit.record_versions`). The `DatabaseHandler` sets `audit.user_id` and `audit.user_name` as session variables before each query, and triggers capture mutations automatically.

**Current fields captured:** `user_id`, `user_name`, `op` (INSERT/UPDATE/DELETE), `table_name`, `old_record_id`/`new_record_id`, `time`, `changeset_id`.

- New API endpoints that mutate data **must** include audit logging — this is a blocking review item.
- Read-only endpoints do not require audit logging unless they access evidence content (not metadata).
- Audit logs are append-only. Never delete, modify, or expose a deletion endpoint for audit records.

> ⚠ GAP: `source_ip` is not captured — it is absent from the schema and not extracted from requests anywhere.
>
> ⚠ GAP: `auditChangeset` (semantic operation names) is only called for merge/unmerge operations. Standard CRUD relies on DB triggers alone without a semantic `what` label.

**References:** Audit trigger → `chrono-api/migrations/20220826165921*`, audit model → `Models/Audit.swift`, changeset helper → `Helpers/PostgresConnection+Helpers.swift`

## Encryption

- **In transit:** TLS 1.2+ on all external-facing endpoints. CloudFront enforces `TLSv1.2_2019` with redirect-to-https. API Gateway is HTTPS-only.
- **At rest:** AES-256 for S3 buckets (SSE-S3) and RDS (`storage_encrypted = true`). New storage resources must enable encryption — this is a blocking review item for infrastructure changes.
- Evidence files in S3 must use SSE-S3 or SSE-KMS. No client-side-only encryption.

> **Note:** `DatabaseHandler.swift` sets `tls: .disable` for the PostgreSQL connection. All DB traffic stays within the private VPC subnet — this is an accepted trade-off, not a policy violation, since the in-transit TLS requirement applies to external-facing endpoints.

**References:** CloudFront TLS config → `chrono-devops/output/staging/*/cloudfront.tf`, DB connection → `chrono-api/Sources/ChronoAPI/Services/Requests/DatabaseHandler.swift`

## Tenant Isolation & Access Control

Tenant isolation is **infrastructure-level**: each customer gets a dedicated AWS account with its own VPC, RDS cluster, S3 buckets, Lambda stack, and Auth0 tenant. There is no database-level multi-tenancy (RLS was removed in Oct 2024). See `.claude/docs/deployment.md` for the full architecture.

- **Never introduce cross-account data access patterns.** Each deployment is single-tenant by design.
- **All API endpoints** must require authentication. No unauthenticated routes except health checks.
- Auth is permission-based (`read`/`edit`/`admin`) via Auth0 JWTs parsed in `AuthorizedUser.swift`. Within a deployment, all authenticated users with `read` see all data.
- **IAM roles:** Least privilege. Lambda roles get only the permissions they need. Never use `*` resource in IAM policies.
- Permission and auth middleware changes are **blocking** review items.

> ⚠ GAP: `chrono-filter-ai-api` has **zero authentication** on all endpoints (`/mcp`, `/mcp-chat`, `/mcp-chat-ws`, `/semantic-search`). These query the live database unauthenticated. CORS is also `allow_origins=["*"]`.
>
> ⚠ GAP: Lambda IAM roles in `api.tf` and `ai_filter_server.tf` use `Resource = "*"` for S3, Secrets Manager, and CloudWatch actions — violates least-privilege.
>
> ⚠ GAP: `AuthorizedUser.swift` uses `.contains()` substring matching for permission parsing (transitional workaround during Auth0 migration) — `"read-restricted"` would grant `read`.

**References:** Auth middleware → `chrono-api/Sources/ChronoAPI/Models/AuthorizedUser.swift`, handler base → `Services/Requests/DatabaseHandler.swift`, IAM → `chrono-devops/output/staging/*/api.tf`

## Data Retention & Deletion

- Evidence data retention follows client-specific policies configured per tenant.
- When a deletion is requested, delete the evidence files (S3) **and** all derived data (OCR text, entity mappings, timeline events). Partial deletion is a compliance violation.
- Audit logs are exempt from deletion — they must be retained for the full compliance period.

> ⚠ GAP: `Source.deleteAttachment()` only nulls `attachment_url` in the database — **S3 objects are never deleted**. No `s3.deleteObject()` call exists anywhere in chrono-api. Derived data (OCR text, entity mappings, timeline events) is not cascade-deleted either. The pipeline's `s3_helper.delete_object` exists but is not wired to any deletion workflow.

**References:** Delete logic → `chrono-api/Sources/ChronoAPI/Models/Source.swift` (line ~162), S3 helper → `chrono-pipeline-v2/aws/s3_helper.py`

## Dependency Security

- **Run `npm audit` / `pip audit`** before shipping changes that add or update dependencies.
- New dependencies must not have known critical or high CVEs.
- Prefer well-maintained packages with active security response. Flag unmaintained or single-maintainer packages in review.

> ⚠ GAP: No automated dependency scanning in CI for any component. Dependabot is configured only for `chrono-app` (creates Linear tickets but does not block merges). The `/ship` pre-ship hook does not run audit checks.

## Change Management

- All code changes go through PRs targeting `develop`. **No direct pushes to `develop` or `main`.**
- PRs require at least one approving review before merge.
- Infrastructure changes (Terraform, IAM, security groups) require explicit compliance review.

> ⚠ GAP: CI runs on PRs only for `chrono-app` (via GitHub Actions). The other four components have CircleCI configs that trigger on branch pushes (`develop`, `staging`, `master`) but not on PRs. Branch protection rules are not codified in the repo — enforcement depends on GitHub UI settings.
