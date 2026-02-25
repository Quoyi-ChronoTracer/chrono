# OPT-2: Redaction Detection Gate

## Current Redaction Flow

```
preprocessor.py:160 -> detect_redactions(gray)
  returns redaction_boxes
preprocessor.py:161 -> masking applied
  propagated to ocr_fullpage()
ocr_engine.py:78   -> if redaction_boxes:
  -> _insert_redaction_placeholders() at :390
     calls pytesseract.image_to_data() (3rd Tesseract call, 3-8s)
```

The `_insert_redaction_placeholders()` function at line 390 makes a 3rd Tesseract call via `pytesseract.image_to_data()`. This call takes 3-8 seconds and runs even when `redaction_boxes` contains only false positives.

---

## False Positive Analysis of `detect_redactions()` Defaults

| Parameter | Default | Problem |
|---|---|---|
| `darkness_threshold=30` | Too aggressive, captures bold text headers |
| `min_width=50` | Too low (0.25 inches at 200 DPI), captures headers/logos |
| `min_height=15` | Marginal, single bold text line meets this |
| `min_solidity=0.9` | Good discriminator but still catches filled signature blocks |
| `min_aspect_ratio=1.2` | Very permissive, real redaction bars are 5:1 to 50:1 |
| `min_area=2000` | Low, bold header words exceed this |

---

## Part A -- Tighten Thresholds via `OCRConfig`

Update defaults for `detect_redactions()`. Since Risk-10 introduced `OCRConfig` as the
central config dataclass, these threshold changes should be applied as new defaults in
`OCRConfig` rather than modifying inline defaults in `detect_redactions()` directly.
The `detect_redactions(cfg=...)` parameter already accepts an `OCRConfig` instance.

| Parameter | Old | New | Rationale |
|---|---|---|---|
| `min_width` | 50 | 80 | 0.4 inches at 200 DPI, excludes single words |
| `min_height` | 15 | 18 | Excludes single bold text lines |
| `min_aspect_ratio` | 1.2 | 2.0 | Real bars are much wider than tall |
| `min_area` | 2000 | 3000 | Excludes bold header words |
| `darkness_threshold` | 30 | 20 | Tighter darkness requirement, real bars are near-black |

---

## Part B -- ~~Add `_validate_redaction_boxes()` in `ocr_engine.py`~~ SUPERSEDED by Risk-9

> **Status: Already implemented.** Risk-9 added `_validate_redaction_boxes()` with a
> `ScoredBox` dataclass that performs confidence scoring using uniformity, edge density,
> and boundary contrast sub-scores against `REDACTION_CONFIDENCE_THRESHOLD=0.65`. The gate
> logic in `ocr_fullpage()` already checks `if validated_boxes:` before calling
> `_insert_redaction_placeholders()`. Per-insertion trace events are emitted.
>
> OPT-2 does **not** need to implement Part B. The only remaining action is to verify
> that the Risk-9 threshold (`0.65`) is appropriate after Part A's tighter detection
> defaults reduce the candidate pool. If needed, adjust `REDACTION_CONFIDENCE_THRESHOLD`
> via `OCRConfig` (see Risk-10 interaction below).

---

## Part C -- ~~Add Trace Events~~ Partially Superseded by Risk-9 and Risk-13

Risk-13 already emits `redaction_detection` trace events in `preprocessor.py` with flat
kwargs (not nested dicts). Risk-9 already emits per-insertion trace events from the
validation gate in `ocr_engine.py`. Risk-1 wrapped the `pytesseract.image_to_data()` call
in try/except with `TesseractError` catching, and Risk-13 added timing around it.

**Remaining work:** Verify the existing trace events cover the gate-level summary
(candidates in vs. validated vs. rejected). If Risk-9's per-insertion events do not
include an aggregate summary, add one using flat kwargs per Risk-13 convention:

```python
trace_event(
    "redaction_gate",
    candidates_in=len(redaction_boxes),
    candidates_validated=len(validated_boxes),
    rejected=len(redaction_boxes) - len(validated_boxes),
)
```

---

## Risk Assessment

### Missing real redactions

The primary risk is that tighter thresholds or validation rejects genuine redaction bars.

**Mitigations:**

- Masking still runs on original detection (Part A tightens defaults but Risk-9's validation gate is a separate layer)
- Risk-9's `ScoredBox` confidence scoring uses uniformity/edge/boundary sub-scores with a 0.65 threshold
- Trace events (Risk-13 + Risk-9) enable monitoring for missed redactions in production
- Thresholds are conservative -- real bars are dramatically different from false positives

### Interaction between Part A and Risk-9 Validation

Part A reduces the number of candidates reaching the Risk-9 validation gate. This is
intentional -- fewer candidates means less validation compute and fewer chances for
validation errors. After applying Part A, verify that the `REDACTION_CONFIDENCE_THRESHOLD`
of 0.65 is still appropriate for the narrower candidate pool (it should be, since
surviving candidates will skew more toward genuine redactions).

---

## Tests

### ~~New: `test_redaction_gate.py`~~ -- Superseded by Risk-9

Risk-9 already created `test_redaction_false_positives.py` with validation gate tests
covering ScoredBox confidence scoring, sub-score computation, and acceptance/rejection
behavior. A separate `test_redaction_gate.py` is no longer needed.

### Extend: `tests/unit/pipeline/steps/ocr_neurons/test_redaction_false_positives.py`

Add boundary tests for the tightened OCRConfig thresholds:

- **test_new_min_width_boundary** -- 79px rejected, 80px accepted
- **test_new_min_aspect_ratio_boundary** -- 1.9 rejected, 2.0 accepted
- **test_new_darkness_threshold** -- pixel value 21 rejected, 20 accepted
- **test_new_min_area_boundary** -- 2999 rejected, 3000 accepted

### Extend: `tests/unit/pipeline/steps/ocr_neurons/test_ocr_engine.py`

Gate integration tests (validation gate already exists from Risk-9, test the full flow):

- **test_ocr_fullpage_skips_image_to_data_no_redactions** -- empty boxes, image_to_data not called
- **test_ocr_fullpage_skips_image_to_data_false_positives** -- boxes fail validation, image_to_data not called
- **test_ocr_fullpage_calls_image_to_data_real_redactions** -- real boxes pass validation, image_to_data called once

---

## Interactions with Risk Implementations

### Risk-9 (Redaction False Positives) -- Major Overlap with Part B

Risk-9 **already implements** the core validation gate that OPT-2 Part B originally
proposed. Specifically:

- A `ScoredBox` dataclass and `_validate_redaction_boxes()` function exist in
  `ocr_engine.py`.
- Confidence scoring uses uniformity, edge density, and boundary contrast sub-scores --
  the same three checks Part B specified.
- A configurable `REDACTION_CONFIDENCE_THRESHOLD=0.65` gates acceptance.
- The `ocr_fullpage()` gate logic already checks `if validated_boxes:` before calling
  `_insert_redaction_placeholders()`.
- Per-insertion trace events are emitted.
- A `build_redaction_audit_report()` function generates audit artifacts.

**Impact on OPT-2:** Part B is fully superseded. OPT-2 reduces to Part A (threshold
tightening via OCRConfig) and a verification pass on Part C trace events. The only Part B
consideration is whether the Risk-9 confidence threshold needs adjustment after Part A
narrows the candidate pool.

### Risk-10 (Central Config) -- Overlap with Part A

Risk-10 introduced `OCRConfig` as a central dataclass for all OCR thresholds.
`detect_redactions()` and `mask_redactions()` in `redaction.py` now accept a `cfg`
parameter. Thresholds like `darkness_threshold`, `min_width`, `min_height`, etc. resolve
through config defaults.

**Impact on OPT-2:** Part A threshold changes must be applied as updated defaults in
`OCRConfig`, not by editing inline defaults in `detect_redactions()`. This ensures all
call sites pick up the new values consistently.

### Risk-1 (Tesseract Error Handling) -- Overlap with Part C

Risk-1 wrapped all `pytesseract` calls in `ocr_engine.py` with try/except blocks
catching `TesseractError`. The `_insert_redaction_placeholders()` call to
`pytesseract.image_to_data()` is now guarded.

**Impact on OPT-2:** No additional error handling is needed around the `image_to_data()`
call. OPT-2 should not add redundant try/except blocks.

### Risk-13 (OCR Observability) -- Overlap with Part C

Risk-13 added trace events using flat kwargs (not nested dicts) and timing around all
Tesseract calls. A `redaction_detection` trace event already exists in `preprocessor.py`.

**Impact on OPT-2:** Most Part C trace events are already in place. The only remaining
work is verifying an aggregate gate-level summary event exists (candidates in vs.
validated vs. rejected). Any new trace events must use flat kwargs per Risk-13 convention.

### Test File Overlap

Risk-9 created `test_redaction_false_positives.py` with tests for the `ScoredBox`
validation logic. OPT-2 tests for threshold boundary behavior should **extend** this
existing file rather than creating a new `test_redaction_gate.py`.

---

## File Changes Summary

| # | File | Change | Status |
|---|---|---|---|
| 1 | `OCRConfig` (config module) | Update redaction threshold defaults (`min_width=80`, `min_height=18`, `min_aspect_ratio=2.0`, `min_area=3000`, `darkness_threshold=20`) | **Part A -- TODO** |
| 2 | `ocr_engine.py` | ~~Add `_validate_redaction_boxes()`, modify gate logic~~ | **Part B -- Done (Risk-9)** |
| 3 | `ocr_engine.py` | Verify aggregate gate summary trace event exists; add if missing (flat kwargs) | **Part C -- Verify** |
| 4 | `preprocessor.py` | ~~Add `trace_event` for detection count~~ | **Part C -- Done (Risk-13)** |
| 5 | `tests/unit/pipeline/steps/ocr_neurons/test_redaction_false_positives.py` | **Extend** -- 4 boundary tests for new thresholds, 3 gate integration tests | **TODO** |
| 6 | `tests/unit/pipeline/steps/ocr_neurons/test_ocr_engine.py` | **Extend** -- gate integration tests (skip `image_to_data` on false positives, call on real) | **TODO** |
