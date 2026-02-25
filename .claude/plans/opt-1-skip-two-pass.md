# OPT-1: Skip Two-Pass OCR for Clean Documents

## Current Behavior

`enable_two_pass` defaults to `True` in `recommend_params()` at `image_profile.py:296`. Three code paths modify it:

1. **Thin strokes** (`stroke_width <= 2.0`) forces `True` (line 346)
2. **Thick strokes** (`stroke_width > 8.0`) sets `False` (line 354)
3. **High noise** (`noise_sigma > 10`) forces `True` (line 401)

No existing path disables two-pass for clean documents. This means every clean, high-quality scan still pays the cost of a second Tesseract pass even when the first pass produces excellent results.

---

## Proposed Changes to `recommend_params()` in `image_profile.py`

Insert a new block after the stroke-width section (after line 357), before the noise section (line 398).

### Conditions

All of the following must be true:

- `not profile.is_bilevel` -- bilevel images have different quality characteristics
- `otsu_separability > 0.7` -- strong foreground/background separation indicates clean text
- `noise_sigma < 5.0` -- low noise level
- `stroke_width > 2.5` -- not thin/fragile strokes that benefit from two-pass
- `num_noise_specks < 200` -- minimal speckle contamination

### Behavior

- Sets `enable_two_pass = False`
- Records a reason string describing the clean-document decision

### Override Safety

The high-noise block at line 398 naturally overrides back to `True` if `noise_sigma > 10`, so a noisy document that somehow passes the initial `noise_sigma < 5.0` check on re-evaluation still gets two-pass protection.

---

## Flow Trace

```
recommend_params()
  -> preprocessor._apply_preprocessing()
     returns (gray, params, redaction_boxes)
  -> ocr_engine.ocr_fullpage()
     reads `enable_two_pass` at line 59
     controls pass 2 at lines 62-69
```

### Call Sites for `ocr_fullpage()` with params

| File | Line | Notes |
|---|---|---|
| `image_extractor.py` | 31 | Standalone image path |
| `pdf_extractor.py` | 66 | PDF page path |
| `ocr_engine.py` | 148 | Backward-compat wrapper, passes `None`, always two-pass |

---

## Risk Assessment

### Near-threshold stippled fonts

Documents with `stroke_width` around 2.6 and stippled or dot-matrix fonts could be misclassified as clean. Mitigated by the `noise_sigma < 5.0` check -- stippled fonts typically have higher noise signatures.

### Mixed pages

A page with a clean header but stippled body text could have aggregate metrics that appear clean. Mitigated by conservative thresholds -- `otsu_separability > 0.7` is high, and `num_noise_specks < 200` is strict.

---

## Trace Event

Add a `trace_event` in `ocr_fullpage()` recording the `enable_two_pass` decision. This follows the Engineering.md requirement for observability on conditional code paths.

The trace event must use flat kwargs (not a nested dict) to match the `trace_event(neuron: str, **kwargs)` signature established by Risk-13:

```python
trace_event(
    "ocr_two_pass_decision",
    enable_two_pass=rp.get("enable_two_pass", True),
    reason=rp.get("two_pass_reason", "default"),
)
```

This event must be placed **inside** the existing try block for Pass 1 (added by Risk-1/Risk-3), before the actual `pytesseract.image_to_string()` call. The try/except structure in `ocr_fullpage()` now looks like:

```python
try:
    trace_event(
        "ocr_two_pass_decision",
        enable_two_pass=rp.get("enable_two_pass", True),
        reason=rp.get("two_pass_reason", "default"),
    )
    t0 = time.monotonic()
    text_baseline = pytesseract.image_to_string(
        gray, config=ocr_config, timeout=_TIMEOUT_FULLPAGE_S
    ).strip()
    duration = time.monotonic() - t0
    # ... Risk-13 timing trace_event ...
except subprocess.TimeoutExpired:
    # ... Risk-3 handler ...
except Exception as e:
    # ... Risk-1 handler ...
```

Placing the trace_event inside the try block (rather than before it) keeps the decision record adjacent to the code it governs and avoids emitting the event if `ocr_fullpage()` was called with malformed params that would raise before the Tesseract call.

---

## Interactions with Risk Implementations

### Risk-1: Tesseract Error Handling

`ocr_fullpage()` now has try/except blocks around both Pass 1 and Pass 2 Tesseract calls. The OPT-1 implementation needs to account for this:

- **Clean-document block placement is unaffected.** The clean-document logic lives in `recommend_params()` in `image_profile.py`, which runs before `ocr_fullpage()` is called. It sets `enable_two_pass = False` in the params dict. This is upstream of the try/except blocks and requires no interaction.
- **Trace event placement.** The `ocr_two_pass_decision` trace event in `ocr_fullpage()` must go inside the Pass 1 try block, before the Tesseract call. If Pass 1 raises, the trace event has already been emitted, which is correct -- it records the decision, not the outcome. The outcome (error) is separately recorded by Risk-1's error trace events (`ocr_fullpage_pass1 status=error`).
- **Test mocking.** OPT-1 engine tests that mock pytesseract must account for the try/except wrappers. When `enable_two_pass=False`, the mock should still be wrapped in the Pass 1 try block -- assert that a single call was made and no exception handler was triggered. Use `assert mock_image_to_string.call_count == 1` (unchanged from original plan) but verify the mock was called with `timeout=_TIMEOUT_FULLPAGE_S` in kwargs (Risk-3 added this parameter).

### Risk-3: Tesseract Timeout

All pytesseract calls now include `timeout=` parameters. The OPT-1 implementation interacts as follows:

- **Pass 2 timeout is still relevant.** When OPT-1 sets `enable_two_pass = False`, the Pass 2 code path (and its `timeout=_TIMEOUT_PASS2_S`) is never reached. This is correct -- the timeout constant `_TIMEOUT_PASS2_S=45` is only meaningful for documents that actually run Pass 2 (stippled/dot-matrix images).
- **Engine tests must pass timeout kwarg.** OPT-1's `test_ocr_fullpage_skips_pass2` test must verify the mock was called with `timeout=_TIMEOUT_FULLPAGE_S` (not bare). The assertion changes from "call count == 1" to "call count == 1 AND called with timeout kwarg".
- **TimeoutExpired is caught before TesseractError.** The except clause ordering is `subprocess.TimeoutExpired` first, then `Exception`. OPT-1's trace event sits before both -- it fires regardless of whether the subsequent Tesseract call times out or errors.

### Risk-10: Central Config (OCRConfig)

`recommend_params()` now accepts a `cfg: OCRConfig | None = None` parameter. The clean-document thresholds in OPT-1 must be sourced from `OCRConfig` rather than inline literals:

- **New fields needed in `OCRConfig`.** Add to the dataclass in `ocr_config.py`:
  - `clean_doc_otsu_min: float = 0.7` -- Tier 2, named constant (not env-var exposed)
  - `clean_doc_noise_sigma_max: float = 5.0` -- Tier 2
  - `clean_doc_stroke_width_min: float = 2.5` -- Tier 2
  - `clean_doc_noise_specks_max: int = 200` -- Tier 2

- **Usage in `recommend_params()`.** The clean-document block becomes:
  ```python
  _cfg = cfg or default_config()
  if (
      not profile.is_bilevel
      and profile.otsu_separability > _cfg.clean_doc_otsu_min
      and profile.noise_sigma < _cfg.clean_doc_noise_sigma_max
      and profile.stroke_width > _cfg.clean_doc_stroke_width_min
      and profile.num_noise_specks < _cfg.clean_doc_noise_specks_max
  ):
      enable_two_pass = False
      reasons.append("clean document — skipping two-pass")
  ```

- **`ocr_fullpage()` also accepts `cfg`.** Risk-10 added `cfg: OCRConfig | None = None` to `ocr_fullpage()`. The stipple dilation kernel is now `_cfg.stipple_dilation_kernel` and `min_text_length` is `_cfg.min_text_length`. OPT-1 does not need to read any new config fields in `ocr_fullpage()` -- the `enable_two_pass` decision is made upstream in `recommend_params()` and arrives via the `params` dict.

- **Test config injection.** OPT-1 tests for `recommend_params()` should use `get_ocr_config(overrides={...})` to inject test thresholds rather than relying on defaults. For example:
  ```python
  cfg = get_ocr_config(overrides={"clean_doc_otsu_min": 0.5})
  params = recommend_params(profile, cfg=cfg)
  ```

### Risk-13: OCR Observability

Risk-13 established the tracing conventions that OPT-1 must follow:

- **Flat kwargs, not nested dicts.** The original plan had `trace_event("ocr_two_pass_decision", {"enable_two_pass": ..., "reason": ...})` -- this is wrong. The correct form is `trace_event("ocr_two_pass_decision", enable_two_pass=..., reason=...)` per the `trace_event(neuron: str, **kwargs)` signature.
- **Named logger.** `ocr_engine.py` now has `logger = logging.getLogger(__name__)` (added by Risk-13). Any new log statements in OPT-1 should use `logger.info(...)` / `logger.warning(...)`, not bare `logging.info(...)`.
- **Risk-13 already emits `ocr_two_pass_decision`.** Risk-13 defines this exact event name with a richer payload (`two_pass_enabled`, `pass2_produced_text`, `winner`, `baseline_chars`, `enhanced_chars`, `merged_chars`). OPT-1's trace event (which fires before the Tesseract call) records the **decision input** (`enable_two_pass` flag value and reason), while Risk-13's event (which fires after the merge logic) records the **decision outcome**. Both are needed -- the OPT-1 event explains WHY two-pass was skipped, and the Risk-13 event confirms WHAT happened. They should use different event names to avoid confusion:
  - OPT-1: `trace_event("ocr_two_pass_config", enable_two_pass=..., reason=...)`
  - Risk-13: `trace_event("ocr_two_pass_decision", two_pass_enabled=..., winner=..., ...)`
- **`time.monotonic()` timing already exists.** Risk-13 added timing around all Tesseract calls. OPT-1 does not need to add any additional timing instrumentation.
- **Slow-call threshold.** Risk-13 added `SLOW_TESSERACT_THRESHOLD_S = 10.0` with `logger.warning` on slow calls. When OPT-1 skips Pass 2, the total OCR time decreases -- no interaction issue, but this is the performance improvement OPT-1 is designed to achieve.

---

## Tests to Add

### Extend: `tests/unit/pipeline/steps/ocr_neurons/test_image_profile.py`

This file already exists from Risk-7. OPT-1 tests should be added as a new test class in the existing file, not as a separate file.

7 tests for `recommend_params()` clean-document logic:

1. **test_clean_document_disables_two_pass** -- all conditions met, verify `enable_two_pass=False`. Pass `cfg=get_ocr_config()` explicitly.
2. **test_clean_document_borderline_values** -- values just above thresholds, verify still `False`
3. **test_values_just_below_thresholds** -- otsu=0.69, verify `True` (threshold not met)
4. **test_stippled_document_stays_two_pass** -- noisy/stippled profile, verify `True`
5. **test_thin_strokes_override** -- stroke_width=1.5 even with high otsu, verify `True`
6. **test_high_noise_overrides_clean** -- noise_sigma=15.0 overrides clean decision, verify `True`
7. **test_bilevel_excluded** -- is_bilevel=True with otherwise clean metrics, verify `True`
8. **test_clean_doc_thresholds_from_config** -- use `get_ocr_config(overrides={"clean_doc_otsu_min": 0.5})` to verify thresholds are sourced from OCRConfig, not hardcoded

### Extend: `tests/unit/pipeline/steps/ocr_neurons/test_ocr_engine.py`

2-3 tests for `enable_two_pass` flag path in `ocr_fullpage()`:

1. **test_ocr_fullpage_skips_pass2** -- mock pytesseract, params with `enable_two_pass=False`, assert Tesseract call count == 1. Verify mock was called with `timeout=_TIMEOUT_FULLPAGE_S` kwarg (Risk-3 compatibility).
2. **test_ocr_fullpage_runs_pass2** -- params with `enable_two_pass=True`, assert call count == 2. Verify first call uses `timeout=_TIMEOUT_FULLPAGE_S` and second uses `timeout=_TIMEOUT_PASS2_S`.
3. **test_defaults_to_two_pass** -- no `enable_two_pass` in params dict, assert call count == 2

---

## File Changes Summary

| # | File | Change | Dependencies |
|---|---|---|---|
| 1 | `ocr_config.py` | Add 4 Tier 2 fields: `clean_doc_otsu_min`, `clean_doc_noise_sigma_max`, `clean_doc_stroke_width_min`, `clean_doc_noise_specks_max` | Risk-10 must be implemented first |
| 2 | `image_profile.py` | `recommend_params()` -- add ~10 lines clean-document block after line 357, reading thresholds from `cfg` | Risk-10 (cfg param exists) |
| 3 | `ocr_engine.py` | `ocr_fullpage()` -- add `trace_event("ocr_two_pass_config", ...)` inside Pass 1 try block, before Tesseract call (~4 lines) | Risk-1 (try/except exists), Risk-3 (timeout exists), Risk-13 (trace_event import and logger exist) |
| 4 | `tests/unit/pipeline/steps/ocr_neurons/test_image_profile.py` | **Extend existing file** -- add 8 unit tests in new `TestCleanDocumentTwoPass` class | Risk-7 (file exists) |
| 5 | `tests/unit/pipeline/steps/ocr_neurons/test_ocr_engine.py` | **Extend** -- 2-3 additional tests, asserting timeout kwargs | Risk-3 (timeout constants) |
