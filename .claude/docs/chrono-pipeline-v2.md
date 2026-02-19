# chrono-pipeline-v2
Python data processing pipeline: OCR extraction, identity + device mapping, deduplication, upload to chrono-api.

## Commands
```bash
# Always use .venv — never system python3 or pip3
.venv/bin/python run.py <source_dir> <artifact_dir>
.venv/bin/python -m pytest tests/unit/ -x -v
```
New dependencies: add to `requirements.txt` with a minimum version pin (e.g. `newlib>=1.2.0`).

## Key Patterns
- `run.py` is the entry point — it defines the step order. Read it first to understand the flow.
- Each pipeline step is a discrete module — follow the existing step structure when adding new ones.
- AWS integration (Textract, S3, Scheduler) lives in `aws/`.

## References
- Step order & orchestration → `run.py`
- Dependencies → `requirements.txt`
- AWS integration → `aws/`
- Tests → `tests/unit/`

## Commit Convention
Present third-person tense: `Adds validation for missing device IDs`
