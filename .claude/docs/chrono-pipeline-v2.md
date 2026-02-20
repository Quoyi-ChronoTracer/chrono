# chrono-pipeline-v2
Python data processing pipeline: OCR extraction, identity + device mapping, deduplication, upload to chrono-api.

## Setup
```bash
# Automated (from mono root)
bash .claude/scripts/bootstrap.sh chrono-pipeline-v2

# Manual
python3 -m venv chrono-pipeline-v2/.venv
chrono-pipeline-v2/.venv/bin/pip install -r requirements-dev.txt
```
Always use `.venv/bin/python` — never system python3 or pip3.

## Commands
```bash
.venv/bin/python run.py <source_dir> <artifact_dir>       # local pipeline run
.venv/bin/python -m pytest tests/unit/ -x -v              # unit tests
```

## Dependency Management
- `pyproject.toml` is the source of truth for dependencies
- `requirements.txt` mirrors pyproject.toml for pip compatibility
- `requirements-dev.txt` pulls in `requirements.txt` + test-only deps (pytest, openpyxl, reportlab, etc.)
- New deps: add to `pyproject.toml` first, then sync to `requirements.txt` with a minimum version pin (`newlib>=1.2.0`)

## Operations
### Local
```bash
.venv/bin/python run.py <source_dir> <artifact_dir>
```

### AWS — Schedule + Execute
```bash
# Schedule only (writes groups.ndjson to inventory bucket)
.venv/bin/python schedule_pipeline.py --mode aws \
  --source_bucket <SRC> --inventory_bucket <INV> \
  --artifact_bucket <ART> --report_bucket <RPT> \
  --prefix <PREFIX>

# Schedule + immediately start Step Functions
.venv/bin/python schedule_pipeline.py --mode aws \
  --source_bucket <SRC> --inventory_bucket <INV> \
  --artifact_bucket <ART> --report_bucket <RPT> \
  --execute_step_functions

# Useful flags
#   --prefix <P1> <P2>          limit to specific S3 prefixes
#   --overwrite_existing         reprocess files even if artifacts exist
#   --minimum_batch_size 1000    files per ECS batch (default 1000)
#   --max_concurrency 300        parallel ECS tasks (default 300)
#   --steps <step1> <step2>      run specific pipeline steps only
#   --skip_event_generation      skip event extraction step
#   --password_file <path>       passwords for encrypted archives
```
Full scheduling/deployment details → `Deploying.md`
Full args → `schedule_pipeline.py`

### Step Functions Phases
Schedule → Fan-out on ECS → Event generation → Upload → Dedupe → Person creation → Device cleanup → Person→Device mapping

The pipeline is **idempotent** — already-processed files are skipped via artifact checks and pre-generated event UUIDs.

## Key Patterns
- `run.py` is the entry point — it defines the step order. Read it first to understand the flow.
- Each pipeline step is a discrete module — follow the existing step structure when adding new ones.
- AWS integration (Textract, S3, Scheduler) lives in `aws/`.

## References
- Step order & orchestration → `run.py`
- Scheduling & args → `schedule_pipeline.py`
- Deployment & architecture → `Deploying.md`
- AWS integration → `aws/`
- Tests → `tests/unit/`

## Commit Convention
Present third-person tense: `Adds validation for missing device IDs`
