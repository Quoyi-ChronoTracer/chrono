# chrono-devops
Terraform, Docker, CircleCI — infrastructure, DNS proxy, and environment configs for dev / staging / prod.

## Tenant Isolation
- **One AWS account per customer.** Each account gets its own VPC, RDS Aurora cluster, S3 buckets, Lambda/ECS stack, and Auth0 tenant.
- Customer accounts are declared in `environments/*.yaml`. Terraform output per account lives in `output/<env>/<account-name>/`.
- There is no database-level multi-tenancy. Each customer's RDS has a single `chrono` database and `chrono_api` user.

## Key Notes
- Infrastructure is Terraform — run `terraform plan` before `apply`, always review the diff.
- CI/CD is CircleCI — pipeline definitions drive all deployments.
- Secrets live in AWS Secrets Manager — never commit credentials.
- Environment-specific configs in `environments/` affect all services in that env — changes here have wide blast radius.
- Apple Silicon + Docker Desktop: disable Rosetta acceleration.

## References
- Pipeline config → `.circleci/config.yml`
- Environment configs → `environments/`
- Service definitions → `services/`
- Deploy scripts → `scripts/`
- DNS proxy → `dns-proxy/`
