# OCR Pipeline Optimization

---

## Problem

ECS pipeline containers running Tesseract OCR on batches of scanned document images
(JPEGs, 2–5 MB each) take **~11.5s average per file**, with worst cases reaching
30–72s. Containers processing ~2,500–3,000 files each run for **~9 hours**, with
degradation toward the end suggesting memory pressure or CPU throttling.

Over 52% of files exceed 10s. The `text_extraction` step dominates total pipeline
runtime by orders of magnitude compared to all other steps.

---

## Resource Allocation

**ECS task definition:** `pipeline-batch-runner`
- **CPU:** 2048 (2 vCPU)
- **Memory:** 4096 MB (4 GB)

This is undersized for CPU-bound OCR work at scale.

---

## Per-File Processing Chain

Every standalone image passes through this chain in `pipeline/steps/ocr_neurons/`:

| # | Step | Code Location | Cost |
|---|------|--------------|------|
| 1 | Edge-density gate | `image_analyzer.py:50` `has_text_content_image()` | ~5ms |
| 2 | Image open + EXIF transpose + grayscale | `preprocessor.py:69` `preprocess_standalone_image()` | ~20ms |
| 3 | Image analysis (6 phases: histogram, noise, connected components, stroke width, layout, skew) | `image_profile.py:67` `analyze_image()` | ~60–100ms |
| 4 | Parameter recommendation | `image_profile.py:277` `recommend_params()` | <1ms |
| 5 | Conditional preprocessing (deskew, invert, CLAHE, bilateral filter) | `preprocessor.py:105` `_apply_preprocessing()` | ~10–50ms |
| 6 | Redaction detection (connected-component analysis) | `redaction.py:21` `detect_redactions()` | ~20–50ms |
| 7 | Redaction masking | `redaction.py:148` `mask_redactions()` | ~5ms |
| 8 | **Tesseract pass 1** — baseline `image_to_string()` | `ocr_engine.py:56` | **~3–8s** |
| 9 | **Tesseract pass 2** — stipple recovery `image_to_string()` (invert→dilate→invert) | `ocr_engine.py:67` | **~3–8s** |
| 10 | Line-by-line merge of both passes | `ocr_engine.py:191` `_merge_ocr_passes()` | ~5ms |
| 11 | **Tesseract pass 3** — `image_to_data()` for word bounding boxes (redaction placeholders) | `ocr_engine.py:390` `_insert_redaction_placeholders()` | **~3–8s** |
| 12 | Post-processing (regex corrections) | `ocr_engine.py:227` `_postprocess_fullpage()` | <1ms |

**Three Tesseract subprocess invocations per file** dominate the total time.

---

## Identified Bottlenecks

### 1. Three Tesseract calls per file

Each `pytesseract` call spawns a subprocess and runs Tesseract on the full-resolution
image. For a typical full-page scanned document at 200+ DPI, each call takes 3–8s.
With three calls (pass 1, pass 2, `image_to_data`), the floor is ~9s per file.

### 2. Two-pass OCR always enabled

`recommend_params()` defaults `enable_two_pass: True` (`image_profile.py:297`).
For thin strokes (`stroke_width <= 2.0`, line 346), it explicitly forces two-pass.
The stipple recovery pass (invert→dilate→invert) is designed for dot-matrix/stippled
fonts. Clean scanned email documents gain nothing from the second pass.

### 3. `image_to_data()` runs even when unnecessary

`_insert_redaction_placeholders()` (`ocr_engine.py:374`) is called whenever
`redaction_boxes` is non-empty. `detect_redactions()` may produce false positives
on email scans (e.g., dark headers or footer bars), triggering the expensive
third Tesseract call for bounding-box extraction that adds no value.

### 4. Fully serial file processing

Each container processes files one at a time. No parallelism within a container
despite having 2 vCPUs. The `text_extraction.py` step processes each group
sequentially via `await extract_image_text(raw)`.

### 5. Undersized compute

2 vCPU / 4 GB is insufficient for sustained OCR workloads of thousands of files.
Tesseract is CPU-bound and benefits from more cores. Degradation patterns over
long runs suggest resource exhaustion.

---

## Optimization Plan

### OPT-1: Skip two-pass for clean documents

**Impact:** ~35% reduction in per-file time (eliminates pass 2)
**Complexity:** Low
**Files:** `image_profile.py` (`recommend_params`)

Use existing `image_profile` signals to disable two-pass when not needed:
- High `otsu_separability` (>0.7) — clean foreground/background separation
- Low `noise_sigma` (<5) — no stipple artifacts
- Normal `stroke_width` (>2.5) — not dot-matrix

Add logic in `recommend_params()` to set `enable_two_pass=False` when the image
profile indicates a clean scanned document with no stipple-like characteristics.

### OPT-2: Gate the third Tesseract call on redaction presence

**Impact:** ~30% reduction when files have no redactions
**Complexity:** Low
**Files:** `ocr_engine.py` (`ocr_fullpage`)

The `_insert_redaction_placeholders()` call at line 79 already checks
`if redaction_boxes:`, but it still invokes `image_to_data()` internally.
Verify the gate is correct, and consider:
- Tightening `detect_redactions()` thresholds to reduce false positives on email scans
- Adding a fast confidence check before committing to the `image_to_data()` call

### OPT-3: Increase ECS task CPU/memory

**Impact:** ~20–30% improvement from better Tesseract throughput
**Complexity:** Trivial (infrastructure change)
**Files:** ECS task definition `pipeline-batch-runner` in `chrono-devops`

Bump from 2 vCPU / 4 GB to at least 4 vCPU / 8 GB. Tesseract benefits from
SIMD instructions and more cache. More memory prevents swap pressure during
sustained runs.

### OPT-4: Parallel file processing within containers

**Impact:** ~2–4x throughput improvement
**Complexity:** Medium
**Files:** `text_extraction.py`, `image_extractor.py`

The `extract_image_text()` function is already `async` but runs OCR synchronously.
Use `asyncio.get_event_loop().run_in_executor()` with a `ProcessPoolExecutor` to
OCR 2–4 files concurrently per container. This pairs well with OPT-3 (more vCPUs).

Key considerations:
- Each Tesseract subprocess uses ~500MB–1GB peak memory
- With 4 vCPU / 8 GB, 2–3 concurrent workers is safe
- Need to manage the executor lifecycle per-task, not per-file

### OPT-5: Downscale high-DPI images before OCR

**Impact:** ~20–40% per-file improvement for >200 DPI images
**Complexity:** Low
**Files:** `preprocessor.py` (`preprocess_standalone_image`)

Scanned document JPEGs are commonly 300 DPI (2550×3300 pixels for letter-size).
Tesseract works well at 200 DPI. Downscaling before OCR reduces the pixel count
by ~56% (from 300→200 DPI), directly reducing Tesseract processing time.

Add a DPI check in `preprocess_standalone_image()`: if the source image exceeds
250 DPI (detected via EXIF or dimension heuristics in `_extract_dpi()`), resize
to 200 DPI equivalent before entering the OCR pipeline.

---

## Priority Order

1. **OPT-1** + **OPT-2** — code changes, biggest bang for least risk
2. **OPT-3** — infra change, immediate improvement
3. **OPT-5** — code change, compounds with OPT-1/2
4. **OPT-4** — most complex, but largest potential multiplier

Combined effect of all five: estimated **3–5x improvement** in total pipeline
throughput for image-heavy batches.
