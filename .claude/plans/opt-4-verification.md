# OPT-4 Verification: Parallel OCR Execution

## Unit Tests

### Executor Lifecycle

#### test_executor_created_with_correct_worker_count

```python
with mock.patch("concurrent.futures.ProcessPoolExecutor") as MockExecutor:
    run_groups(context, config={"ocr_workers": 3})
    MockExecutor.assert_called_once_with(max_workers=3)
```

Verify the `ProcessPoolExecutor` is created with the configured worker count.

#### test_executor_default_workers

```python
with mock.patch("concurrent.futures.ProcessPoolExecutor") as MockExecutor:
    run_groups(context, config={})
    MockExecutor.assert_called_once_with(max_workers=2)
```

Verify default worker count is 2 when not configured.

#### test_executor_shutdown_after_processing

```python
mock_executor = mock.MagicMock()
with mock.patch("concurrent.futures.ProcessPoolExecutor", return_value=mock_executor):
    run_groups(context, config={})
    mock_executor.shutdown.assert_called_once_with(wait=True)
```

Verify the executor is properly shut down in the `finally` block, even if processing raises an exception.

#### test_executor_shutdown_on_exception

```python
mock_executor = mock.MagicMock()
with mock.patch("concurrent.futures.ProcessPoolExecutor", return_value=mock_executor):
    with pytest.raises(PipelineError):
        run_groups(failing_context, config={})
    mock_executor.shutdown.assert_called_once_with(wait=True)
```

Verify shutdown runs even when pipeline raises.

### Concurrency

#### test_multiple_ocr_calls_run_concurrently

```python
# Use timing assertions with sleep mocks to verify concurrent execution
call_times = []

def slow_ocr(*args):
    call_times.append(("start", time.monotonic()))
    time.sleep(0.1)
    call_times.append(("end", time.monotonic()))
    return "text"

with mock.patch("pytesseract.image_to_string", side_effect=slow_ocr):
    results = await gather_ocr_pages(pages, executor, max_workers=2)

# If sequential: total >= 0.2s. If parallel: total ~0.1s
total_time = call_times[-1][1] - call_times[0][1]
assert total_time < 0.15  # concurrent execution
```

#### test_backpressure_limits_concurrent_workers

```python
# Track timestamps of concurrent active workers
active_count = []
lock = threading.Lock()

def tracked_ocr(*args):
    with lock:
        active_count.append(threading.active_count())
    time.sleep(0.05)
    return "text"

with mock.patch("pytesseract.image_to_string", side_effect=tracked_ocr):
    results = await gather_ocr_pages(many_pages, executor, max_workers=2)

# Max overlap should never exceed worker count
assert max(active_count) <= 2 + 1  # +1 for main thread
```

### Error Handling

#### test_single_file_failure_doesnt_crash_batch

```python
def sometimes_fail(image_bytes, *args):
    if b"corrupt" in image_bytes:
        raise TesseractError("OCR failed")
    return "text"

with mock.patch("pytesseract.image_to_string", side_effect=sometimes_fail):
    results = await gather_ocr_pages(
        [good_page, corrupt_page, good_page2],
        executor,
        max_workers=2,
    )

assert results[0] == "text"
assert isinstance(results[1], Exception)  # or however errors are surfaced
assert results[2] == "text"
```

One failing OCR call does not prevent other pages from completing.

---

## Integration Tests

### Batch correctness

1. Process a batch of 10+ images through the parallel pipeline
2. Verify all images produce correct OCR output
3. Compare output text with sequential baseline -- must be identical

### Artifact integrity

- All output artifacts are valid UTF-8
- No cross-contamination between files (page 3 text does not appear in page 7 output)
- File artifacts are written to correct directories
- `trace.json` contains events for all files, not just some

### Trace events

- Each processed file has corresponding trace events in the main process
- Trace events include correct page numbers and timing data
- No orphaned or misattributed trace events

---

## Concurrency Tests

### Artifact isolation

Process a batch of diverse documents (different sizes, formats, content):
- Each artifact ends up in its correct output directory
- No file handle conflicts or permission errors
- Temporary files are cleaned up

### Log integrity

- Log lines are not corrupted (no interleaved partial lines)
- Each log entry correctly identifies its source file/page
- Log ordering is consistent within each file

### trace.json completeness

- `trace.json` contains the expected number of events
- No missing events (compare event count with file count)
- Event timestamps are monotonically increasing in the main process

### Mixed failure handling

Process a batch containing both corrupt and valid files:
- Corrupt files produce error entries, not crashes
- Valid files produce correct output regardless of corrupt neighbors
- Pipeline completes with partial success, not total failure
- Error reporting identifies which files failed and why

---

## Memory Verification

### Peak RSS monitoring

```python
import psutil
process = psutil.Process()

# Monitor during processing
peak_rss = 0
while pipeline_running:
    current_rss = process.memory_info().rss
    peak_rss = max(peak_rss, current_rss)
    time.sleep(0.1)
```

| Workers | Expected Peak RSS | 8 GB Limit |
|---|---|---|
| 1 | < 2 GB | Safe |
| 2 | < 4 GB | Safe |
| 3 | < 5.5 GB | Marginal |

### Worker count configuration

- `OCR_WORKERS=1` -> effectively sequential (1 worker)
- `OCR_WORKERS=2` -> default, 2 concurrent OCR processes
- `OCR_WORKERS=4` -> 4 concurrent (only safe with large memory)
- Verify the worker count is bounded and validated at startup

---

## Performance Verification

### Throughput improvement

Expected 2-4x throughput improvement depending on document mix and worker count.

### Wall-clock comparison

Run the same batch of documents before and after:
- **Before (sequential):** Total time = N * avg_per_file_time
- **After (2 workers):** Total time ~ N * avg_per_file_time / 2
- Per-file time should be similar (OCR per page unchanged), total time drops

### Measurement

Parse pipeline logs for:
- Total step duration (wall-clock)
- Per-file duration (should be similar to sequential)
- Ratio of total_time_before / total_time_after ~ worker_count

---

## Rollback Plan

### Environment variable disable

```bash
# Option 1: Disable parallel OCR entirely
OCR_PARALLEL_DISABLED=true

# Option 2: Set workers to 1 (sequential)
OCR_MAX_WORKERS=1
```

### ECS task definition override

Add environment variable to the ECS task definition without code changes:

```json
{
  "name": "OCR_WORKERS",
  "value": "1"
}
```

This provides immediate rollback without redeployment.

---

## Known Risks

### contextvars don't propagate to ProcessPoolExecutor

`contextvars` context is not automatically copied to processes in `ProcessPoolExecutor`. Any trace events emitted inside worker processes are lost.

**Verification:** Confirm that all trace events in `trace.json` are emitted from the main process, not from workers. Workers return metadata that the main process uses to emit events.

### File descriptor exhaustion

With many concurrent Tesseract subprocesses, file descriptor limits could be reached. Each Tesseract process opens input image, intermediate files, and output files.

**Verification:** Monitor `lsof` or `/proc/self/fd` count during batch processing. Verify it stays well below `ulimit -n`.

### Runner semaphore interaction

The runner's `max_concurrency=10` semaphore controls group-level concurrency. Combined with `max_workers=2`, the theoretical maximum is `10 * 2 = 20` concurrent Tesseract processes.

**Verification:** Monitor actual concurrent process count during peak load. If it exceeds safe levels, reduce `max_concurrency` or `max_workers` to compensate.
