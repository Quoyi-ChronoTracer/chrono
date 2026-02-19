# chrono-devops
Terraform, Docker, CircleCI — infrastructure, DNS proxy, and environment configs for dev / staging / prod.

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
