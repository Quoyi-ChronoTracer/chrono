# chrono-filter-ai-api
FastAPI + AWS Bedrock (Claude). Converts natural language queries into structured event filters via MCP tools.

## Commands
```bash
pip install -r requirements.txt -r requirements-dev.txt
python local.py                                         # dev server at :8000

pytest chrono_query/tests/ -v
SKIP_MIGRATIONS=true pytest chrono_query/tests/ -v     # no local test DB
createdb chrono_test                                    # one-time test DB setup
```
Deploy: `git push origin <branch>` — CircleCI auto-deploys (`master`→prod, `develop`→develop, `staging`→staging).

## Key Patterns
- **NEVER run tests against the `chrono` DB** — safety guard is in place, do not override it.
- System prompt lives in `system_prompt.txt` — date/time injected at runtime. The filter payload schema is fully documented there; read it before building or modifying filters.
- DB config is loaded from AWS SSM Parameter Store + Secrets Manager, not env vars.
- All DB access is read-only. LLM queries the DB through MCP tools in `mcp_tools/`.

## References
- Filter schema (full) → `system_prompt.txt`
- Endpoints → `main.py`
- DB query library (read-only) → `chrono_query/`
- MCP tool definitions → `mcp_tools/`
- Dependencies → `requirements.txt`
