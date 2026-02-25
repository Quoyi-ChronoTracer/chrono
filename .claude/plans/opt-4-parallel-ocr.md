# OPT-4: Parallel OCR Execution

## Current Execution Model

`runner.py:run_groups()` uses `asyncio.Semaphore(max_concurrency=10)` combined with `asyncio.gather` for group-level concurrency. OCR calls in `image_extractor.py` and `pdf_extractor.py` were originally synchronous, blocking the event loop.

**Post Risk-2:** Async wrappers now exist (`ocr_fullpage_async`, `ocr_small_image_async`, `ocr_standalone_image_async`) that use `loop.run_in_executor(None, ...)` with the default `ThreadPoolExecutor`. The event loop is no longer blocked, but OCR still runs in threads subject to GIL contention and without true parallelism.

**Post Risk-13:** All sync Tesseract functions (`ocr_fullpage`, `ocr_small_image`) now include `time.monotonic()` timing and emit trace events via `contextvars`-based trace context.

---

## Recommended Approach

**Swap the executor in existing async wrappers from default `ThreadPoolExecutor` to `ProcessPoolExecutor`.**

Risk-2 already built the async wrappers with `run_in_executor(None, ...)`. The `None` parameter means "use the default ThreadPoolExecutor." OPT-4's implementation is now reduced to: create a `ProcessPoolExecutor` and pass it as the `executor` argument instead of `None`. This avoids GIL contention and enables true parallelism for CPU-bound Tesseract work.

---

## Implementation

### 1. Add executor to `PipelineStepContext` in `model.py`

```python
ocr_executor: ProcessPoolExecutor | None = None
```

This makes the executor available to all pipeline steps via the existing context-passing mechanism.

### 2. Create executor in `runner.py:run_groups()`

```python
from concurrent.futures import ProcessPoolExecutor

ocr_workers = config.get("ocr_workers", 2)
executor = ProcessPoolExecutor(max_workers=ocr_workers)
context.ocr_executor = executor
try:
    # ... existing run_groups logic ...
finally:
    executor.shutdown(wait=True)
```

Configurable `ocr_workers` with default of 2.

### 3. Thread executor through `image_extractor.py` (minimal change)

Risk-2 already added `ocr_standalone_image_async()` and `extract_image_text()` awaits it. The async wrapper already calls `loop.run_in_executor(None, ...)`. OPT-4 only needs to:

- Accept the `ProcessPoolExecutor` from context
- Pass it to `ocr_standalone_image_async(executor=context.ocr_executor)` instead of `None`

For multi-page TIFFs, the existing `asyncio.gather` pattern works unchanged -- each call just uses the `ProcessPoolExecutor` instead of the default.

### 4. Thread executor through `pdf_extractor.py` (minimal change)

Risk-2 already converted `pdf_extractor.py` to `await ocr_fullpage_async()`. OPT-4 only needs to:

- Pass `context.ocr_executor` to `ocr_fullpage_async(executor=context.ocr_executor)` instead of `None`
- Verify `ocr_fullpage` is a top-level picklable function (it already is -- it's a module-level function in `ocr_engine.py`)

### 5. Thread executor through `text_extraction.py`

Pass the executor from context through to `image_extractor` and `pdf_extractor` dispatch. This is the same as before but smaller -- only adding the `executor` parameter forwarding, not the async conversion itself.

### 6. Modify `run_pipeline.py`

Add CLI argument and environment variable:

```python
parser.add_argument("--ocr-workers", type=int, default=None)
# Falls back to OCR_WORKERS env var, then default 2
ocr_workers = args.ocr_workers or int(os.environ.get("OCR_WORKERS", "2"))
```

---

## Memory Safety

| Workers | Peak Memory Estimate | Safety at 8 GB |
|---|---|---|
| 1 | ~1.5 GB | Safe |
| 2 | ~2.2 GB | Safe |
| 3 | ~3.2 GB | Marginal |
| 4 | ~4.2 GB | Risky |

2 workers is the safe default at 4 vCPU / 8 GB (OPT-3). Each Tesseract process peaks at ~800 MB for large images, plus Python overhead.

---

## Tracing

`contextvars` do not cross process boundaries. Trace events emitted inside `ProcessPoolExecutor` workers are lost.

**Mitigation:** Return metadata from workers (timing, page number, OCR metrics), emit trace events in the main process after gathering results:

```python
for result in results:
    trace_event("ocr_page_complete", {
        "page": result.page_number,
        "duration_ms": result.duration_ms,
        "word_count": result.word_count,
    })
```

---

## Risks

### Memory exhaustion

Mitigated by bounded worker count (default 2) and OPT-3's increased memory (8 GB).

### Executor starvation

A single Tesseract process hanging blocks a worker indefinitely. Mitigation: add `pytesseract` timeout via `--timeout` flag or subprocess-level alarm.

### Serialization overhead

`ProcessPoolExecutor` serializes arguments via pickle. Image bytes are large but serialization is negligible compared to OCR time (~10ms serialize vs. 3-8s OCR).

### Runner semaphore interaction

The runner's `max_concurrency=10` semaphore controls group-level concurrency. With `max_workers=2`, the theoretical maximum concurrent Tesseract processes is `10 * 2 = 20`. In practice, not all groups run OCR, so real concurrency is lower. Monitor and tune if needed.

---

## Interactions with Risk Implementations

### Risk-2: Event Loop Blocking

Risk-2 fundamentally reduces OPT-4's scope. The async infrastructure that OPT-4 originally needed to build from scratch already exists:

- `ocr_engine.py` has `ocr_fullpage_async()` and `ocr_small_image_async()` using `loop.run_in_executor(None, ...)`
- `image_extractor.py` has `ocr_standalone_image_async()` and `extract_image_text()` awaits it
- `pdf_extractor.py` calls `await ocr_fullpage_async()` instead of `ocr_fullpage()` directly

Risk-2's implementation was explicitly designed as "forward-compatible with OPT-4" -- the async wrappers accept an `executor` parameter that defaults to `None` (the default `ThreadPoolExecutor`). OPT-4 now only needs to:

1. Create a `ProcessPoolExecutor` in `runner.py`
2. Pass it as the `executor` argument to the existing async wrappers instead of `None`
3. Verify top-level OCR functions are picklable (they already are -- module-level functions)

Steps 3 and 4 of the original plan (async conversion of `image_extractor.py` and `pdf_extractor.py`) are largely complete. Only executor threading remains.

### Risk-13: OCR Observability

Risk-13 added `time.monotonic()` timing and trace events inside the sync OCR functions (`ocr_fullpage`, `ocr_small_image`). There are 6 trace event types, and `contextvars` are used for trace context propagation.

**Impact on OPT-4:** When OCR functions run in `ProcessPoolExecutor` workers, `contextvars` do not cross process boundaries. The trace events emitted inside `ocr_fullpage` and `ocr_small_image` will be lost in worker processes -- they fire but have no parent trace context to attach to.

**Mitigation (unchanged from Tracing section):** Return timing and OCR metadata from workers, then emit trace events in the main process after gathering results. The Risk-13 timing instrumentation inside the sync functions still serves local debugging in the worker, but the authoritative trace events for the pipeline's trace tree must be emitted main-process-side from the returned metadata.

---

## File Changes Summary

| # | File | Change | Scope vs. Original |
|---|---|---|---|
| 1 | `model.py` | Add `ocr_executor: ProcessPoolExecutor \| None = None` to `PipelineStepContext` | Unchanged |
| 2 | `runner.py` | Create `ProcessPoolExecutor` in `run_groups()`, configurable workers, shutdown in `finally` | Unchanged |
| 3 | `image_extractor.py` | Pass `context.ocr_executor` to existing `ocr_standalone_image_async()` | Reduced -- async wrapper already exists (Risk-2) |
| 4 | `pdf_extractor.py` | Pass `context.ocr_executor` to existing `ocr_fullpage_async()` | Reduced -- async call already exists (Risk-2), no `_ocr_pdf_page_sync` extraction needed |
| 5 | `text_extraction.py` | Thread executor from context to OCR calls | Reduced -- only executor param forwarding, not async conversion |
| 6 | `run_pipeline.py` | Add `--ocr-workers` CLI arg + `OCR_WORKERS` env var | Unchanged |
| 7 | `ocr_engine.py` | Add main-process trace event emission after gathering worker results (Risk-13 mitigation) | New -- compensates for `contextvars` loss across process boundaries |
| 8 | Tests | New and extended tests for executor lifecycle, concurrency, error handling | Unchanged |
