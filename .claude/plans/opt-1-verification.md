# OPT-1 Verification: Skip Two-Pass OCR for Clean Documents

## Unit Tests

### `test_image_profile.py` -- `recommend_params()` Clean-Document Logic

#### test_clean_document_disables_two_pass

```python
profile = ImageProfile(
    otsu_separability=0.85,
    noise_sigma=2.0,
    stroke_width=3.5,
    num_noise_specks=20,
    is_bilevel=False,
)
params = recommend_params(profile)
assert params["enable_two_pass"] is False
```

All conditions comfortably above thresholds. This is the canonical clean-document case.

#### test_clean_document_borderline_values

```python
profile = ImageProfile(
    otsu_separability=0.71,   # just above 0.7
    noise_sigma=4.9,          # just below 5.0
    stroke_width=2.6,         # just above 2.5
    num_noise_specks=199,     # just below 200
    is_bilevel=False,
)
params = recommend_params(profile)
assert params["enable_two_pass"] is False
```

All conditions at their boundary values but still passing. Verifies threshold logic uses strict comparisons correctly.

#### test_values_just_below_thresholds

```python
profile = ImageProfile(
    otsu_separability=0.69,   # below 0.7
    noise_sigma=2.0,
    stroke_width=3.5,
    num_noise_specks=20,
    is_bilevel=False,
)
params = recommend_params(profile)
assert params["enable_two_pass"] is True
```

Single condition failing (otsu below threshold) prevents clean-document shortcut. Verify default True is preserved.

#### test_stippled_document_stays_two_pass

```python
profile = ImageProfile(
    otsu_separability=0.45,
    noise_sigma=12.0,
    stroke_width=1.5,
    num_noise_specks=800,
    is_bilevel=False,
)
params = recommend_params(profile)
assert params["enable_two_pass"] is True
```

Classic stippled/noisy document -- nothing close to clean thresholds.

#### test_thin_strokes_force_two_pass

```python
profile = ImageProfile(
    otsu_separability=0.95,   # very clean
    noise_sigma=1.0,          # very low noise
    stroke_width=1.5,         # thin strokes
    num_noise_specks=10,
    is_bilevel=False,
)
params = recommend_params(profile)
assert params["enable_two_pass"] is True
```

Even with excellent separability and low noise, thin strokes (<=2.0) at line 346 forces True before the clean-document block is reached (stroke_width > 2.5 not met).

#### test_high_noise_forces_two_pass

```python
profile = ImageProfile(
    otsu_separability=0.85,
    noise_sigma=15.0,         # very high noise
    stroke_width=3.5,
    num_noise_specks=20,
    is_bilevel=False,
)
params = recommend_params(profile)
assert params["enable_two_pass"] is True
```

The high-noise block at line 398 (`noise_sigma > 10`) overrides the clean-document decision back to True. Verify the override chain works correctly.

#### test_bilevel_excluded_from_clean

```python
profile = ImageProfile(
    otsu_separability=0.85,
    noise_sigma=2.0,
    stroke_width=3.5,
    num_noise_specks=20,
    is_bilevel=True,          # bilevel excluded
)
params = recommend_params(profile)
assert params["enable_two_pass"] is True
```

Bilevel images are excluded from the clean-document path (`not profile.is_bilevel` fails).

### `test_ocr_engine.py` -- `ocr_fullpage()` Flag Path

#### test_ocr_fullpage_skips_pass2

```python
with mock.patch("pytesseract.image_to_string") as mock_ocr:
    mock_ocr.return_value = "Hello world"
    result = ocr_fullpage(image_bytes, params={"enable_two_pass": False})
    assert mock_ocr.call_count == 1
```

When `enable_two_pass=False`, only one Tesseract call is made. The second pass (lines 62-69) is skipped entirely.

#### test_ocr_fullpage_runs_pass2

```python
with mock.patch("pytesseract.image_to_string") as mock_ocr:
    mock_ocr.return_value = "Hello world"
    result = ocr_fullpage(image_bytes, params={"enable_two_pass": True})
    assert mock_ocr.call_count == 2
```

When `enable_two_pass=True`, both passes execute.

#### test_defaults_to_two_pass

```python
with mock.patch("pytesseract.image_to_string") as mock_ocr:
    mock_ocr.return_value = "Hello world"
    result = ocr_fullpage(image_bytes, params={})
    assert mock_ocr.call_count == 2
```

When `enable_two_pass` is absent from params dict, behavior defaults to True (backward compatibility).

---

## Integration Tests

### Synthetic clean email JPEG

1. Generate a synthetic clean email image (white background, crisp black text, no noise)
2. Run through `preprocess_standalone_image()` -> `recommend_params()`
3. Assert `params["enable_two_pass"]` is `False`
4. Run through `ocr_fullpage()` and verify correct text extraction with single pass

### Stippled document

1. Generate a synthetic stippled/noisy document image
2. Run through `preprocess_standalone_image()` -> `recommend_params()`
3. Assert `params["enable_two_pass"]` is `True`
4. Verify two-pass execution produces expected output

---

## Regression Tests

### Before/after comparison on sample set

1. Select a representative sample set of documents (clean emails, noisy scans, mixed quality)
2. Run OCR with two-pass enabled (baseline)
3. Run OCR with the new logic (some documents skip two-pass)
4. Compare outputs:
   - **Levenshtein distance** < 0.02 normalized (less than 2% character difference)
   - **Word count** within +/- 2% of baseline
5. Any document exceeding these thresholds must be manually reviewed

---

## Performance Verification

### Expected improvement

~35% reduction in OCR time for clean documents (eliminating 1 of 2 Tesseract passes, minus the small overhead of the first pass producing better results for some edge cases).

### Measurement method

Parse "Step text_extraction took Xs" log lines from pipeline output. Compare before/after for:
- Clean documents (should show ~35% reduction)
- Noisy/stippled documents (should show no change)
- Mixed batches (should show proportional reduction based on clean document ratio)

---

## Smoke Test

Manual single-file verification:

1. Run pipeline on a single clean email image:
   ```bash
   python run_pipeline.py --input /path/to/clean_email.jpg --trace
   ```
2. Check output params: `enable_two_pass` should be `False`
3. Verify timing: single Tesseract call, reduced step duration
4. Check `trace.json`: verify `ocr_two_pass_decision` event present with correct values
5. Verify OCR output quality matches expected text content
