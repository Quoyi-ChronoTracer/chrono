# OPT-2 Verification: Redaction Detection Gate

## Unit Tests

### `test_ocr_engine.py` -- Redaction Gate in `ocr_fullpage()`

#### test_ocr_fullpage_skips_image_to_data_empty_boxes

```python
with mock.patch("pytesseract.image_to_data") as mock_itd:
    result = ocr_fullpage(image_bytes, params={}, redaction_boxes=[])
    mock_itd.assert_not_called()
```

When `redaction_boxes` is an empty list, `pytesseract.image_to_data` is never called. No unnecessary 3rd Tesseract pass.

#### test_ocr_fullpage_calls_image_to_data_real_boxes

```python
real_box = create_real_redaction_bar(700, 30)  # fixture: solid black bar
with mock.patch("pytesseract.image_to_data") as mock_itd:
    mock_itd.return_value = mock_data_output
    result = ocr_fullpage(image_bytes, params={}, redaction_boxes=[real_box])
    mock_itd.assert_called_once()
    assert "[[REDACTED]]" in result
```

When real redaction boxes are provided and pass validation, `image_to_data` is called once and `[[REDACTED]]` placeholders appear in output.

#### test_ocr_fullpage_skips_image_to_data_false_positives

```python
fake_box = create_bold_header_region()  # fixture: dark text header
with mock.patch("pytesseract.image_to_data") as mock_itd:
    result = ocr_fullpage(image_bytes, params={}, redaction_boxes=[fake_box])
    mock_itd.assert_not_called()
```

When redaction boxes contain only false positives that fail validation, `image_to_data` is not called.

### `test_redaction.py` -- `detect_redactions()` with New Thresholds

#### test_rejects_dark_email_header

```python
header_region = create_dark_header_image(width=120, height=25, pixel_value=25)
boxes = detect_redactions(header_region)
assert len(boxes) == 0
```

Dark email headers that previously triggered false positives are now rejected by the tighter `darkness_threshold=20` (pixel value 25 > 20).

#### test_rejects_signature_line

```python
sig_region = create_signature_line_image(width=200, height=12)
boxes = detect_redactions(sig_region)
assert len(boxes) == 0
```

Thin signature lines rejected by `min_height=18` (12 < 18).

#### test_rejects_footer_bar

```python
footer = create_footer_bar_image(width=60, height=40, aspect_ratio=1.5)
boxes = detect_redactions(footer)
assert len(boxes) == 0
```

Footer bars with low aspect ratio rejected by `min_aspect_ratio=2.0` (1.5 < 2.0).

#### test_detects_real_700x30_black_bar

```python
bar_image = create_redaction_bar_image(width=700, height=30, pixel_value=5)
boxes = detect_redactions(bar_image)
assert len(boxes) == 1
assert boxes[0].width >= 700
assert boxes[0].height >= 30
```

Real redaction bar (700x30, near-black) still detected with tighter thresholds.

#### test_detects_150x25_inline_box

```python
inline_image = create_redaction_bar_image(width=150, height=25, pixel_value=8)
boxes = detect_redactions(inline_image)
assert len(boxes) == 1
```

Inline redaction box (150x25) still detected -- above all new minimums (width 150 > 80, height 25 > 18, area 3750 > 3000, aspect 6.0 > 2.0).

#### test_detects_stacked_bars

```python
stacked_image = create_stacked_bars_image(count=3, bar_width=500, bar_height=20)
boxes = detect_redactions(stacked_image)
assert len(boxes) == 3
```

Multiple adjacent redaction bars all individually detected.

---

## Integration Tests

### Clean email scan

1. Process a clean email scan image through the full OCR pipeline
2. Count Tesseract calls: **maximum 2** (main OCR + optional second pass)
3. Verify `pytesseract.image_to_data` call count == 0
4. Verify no `[[REDACTED]]` in output text
5. Verify trace events show `redaction_detection.candidates_found == 0` or `redaction_gate.candidates_validated == 0`

### Redacted document

1. Process a document with known redaction bars
2. Verify `pytesseract.image_to_data` call count == 1
3. Verify `[[REDACTED]]` present in output at expected locations
4. Verify trace events show `redaction_gate.candidates_validated > 0`

---

## Regression Tests

### Existing test suite

Run the existing `test_redaction.py` suite with the new default thresholds:
- All tests that use explicit threshold parameters should pass unchanged
- Tests relying on default thresholds may need updating to reflect new defaults
- Review any failures to determine if they represent genuine regressions vs. expected threshold changes

### Known-redacted documents

For documents with confirmed redaction bars:
- Verify `[[REDACTED]]` placeholders appear at correct positions
- Verify no redaction bars are missed (compare with baseline output)

### Clean documents

For documents known to have no redactions:
- Verify zero `[[REDACTED]]` in output (no false positive noise)
- Compare with baseline output to confirm no text quality degradation

---

## Performance Verification

### Expected improvement

~30% reduction in OCR time for non-redacted files (eliminating the 3-8s `image_to_data` call).

### Measurement method

Query pipeline logs comparing before/after:
- Filter for "Step text_extraction took Xs" log lines
- Segment by redacted vs. non-redacted files
- Non-redacted files should show ~30% improvement
- Redacted files should show minimal change (validation adds small overhead but `image_to_data` still runs)

### Trace event analysis

Query trace events for `redaction_gate` decisions:
- Count documents where candidates were detected but none validated (false positive savings)
- Count documents where candidates were validated (real redactions processed)
- Monitor for any documents where redaction was expected but gate rejected all candidates

---

## Smoke Test

### Clean image

1. Process a clean image file through the pipeline:
   ```bash
   python run_pipeline.py --input /path/to/clean_image.jpg --trace
   ```
2. Count Tesseract calls in logs (should be 1-2, not 3)
3. Verify no `[[REDACTED]]` in output
4. Check `trace.json` for `redaction_detection` and `redaction_gate` events

### Redacted image

1. Process a known-redacted image:
   ```bash
   python run_pipeline.py --input /path/to/redacted_doc.jpg --trace
   ```
2. Count Tesseract calls (should be 3: main OCR, optional second pass, image_to_data)
3. Verify `[[REDACTED]]` present in output at correct locations
4. Check `trace.json` for `redaction_gate.candidates_validated > 0`
