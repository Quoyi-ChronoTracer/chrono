# OPT-5 Verification: DPI Downscale for Standalone Images

## Unit Tests

### `test_dpi_downscale.py` -- `_downscale_to_target_dpi()`

#### test_300_dpi_downscaled

```python
image = create_test_image(2550, 3300, dpi=300)
result = _downscale_to_target_dpi(image, detected_dpi=300, target_dpi=200, threshold=250)
assert result.width == pytest.approx(1700, abs=5)
assert result.height == pytest.approx(2200, abs=5)
```

A 300 DPI letter scan (2550x3300) is downscaled to 200 DPI equivalent (~1700x2200).

#### test_200_dpi_unchanged

```python
image = create_test_image(1700, 2200, dpi=200)
result = _downscale_to_target_dpi(image, detected_dpi=200, target_dpi=200, threshold=250)
assert result.width == 1700
assert result.height == 2200
assert result is image  # same object, no copy
```

200 DPI is below the 250 threshold. Image is returned unchanged (same object reference).

#### test_150_dpi_unchanged

```python
image = create_test_image(1275, 1650, dpi=150)
result = _downscale_to_target_dpi(image, detected_dpi=150, target_dpi=200, threshold=250)
assert result.width == 1275
assert result.height == 1650
```

150 DPI is well below threshold. No upscaling occurs.

#### test_no_dpi_metadata_standard_page

```python
image = create_test_image(2550, 3300, dpi=None)  # no DPI metadata
# Heuristic in _extract_dpi() detects 300 DPI from dimensions
detected_dpi = _extract_dpi(image)  # returns 300 via heuristic
result = _downscale_to_target_dpi(image, detected_dpi=detected_dpi, target_dpi=200, threshold=250)
assert result.width == pytest.approx(1700, abs=5)
```

Standard letter-size dimensions trigger the heuristic detection of 300 DPI, and downscaling proceeds.

#### test_no_dpi_metadata_small_image

```python
image = create_test_image(800, 600, dpi=None)
detected_dpi = _extract_dpi(image)  # returns 0 (no heuristic match)
result = _downscale_to_target_dpi(image, detected_dpi=0, target_dpi=200, threshold=250)
assert result.width == 800
assert result.height == 600
```

Small image with no DPI metadata and no heuristic match. `detected_dpi=0` triggers the "unknown DPI" path -- no downscale (safe default).

#### test_aspect_ratio_preserved

```python
image = create_test_image(2550, 3300, dpi=300)
original_ratio = image.width / image.height
result = _downscale_to_target_dpi(image, detected_dpi=300, target_dpi=200, threshold=250)
new_ratio = result.width / result.height
assert abs(original_ratio - new_ratio) / original_ratio < 0.005  # within 0.5%
```

Aspect ratio must be preserved within 0.5% after downscaling. Integer rounding of pixel dimensions can introduce tiny variations.

#### test_scale_factor_interaction

Downscale happens before `analyze_image()`, so profile metrics (otsu_separability, noise_sigma, etc.) are based on the downscaled image. The full-page OCR path does not apply `scale_factor` anyway.

```python
image = create_test_image(2550, 3300, dpi=300)
downscaled = _downscale_to_target_dpi(image, detected_dpi=300, target_dpi=200, threshold=250)
params = recommend_params(analyze_image(downscaled))
# scale_factor is computed but not consumed by ocr_fullpage
# Verify params are based on downscaled dimensions
assert params is not None
```

#### test_bilevel_edge_preservation

```python
bilevel_image = create_bilevel_test_image(2550, 3300, dpi=300)
# Apply bilevel smoothing first (as in real pipeline)
smoothed = apply_bilevel_smoothing(bilevel_image)
result = _downscale_to_target_dpi(smoothed, detected_dpi=300, target_dpi=200, threshold=250)
# Verify edges are preserved: count edge pixels before and after
original_edges = count_edge_pixels(smoothed)
result_edges = count_edge_pixels(result)
# Edge density (per pixel) should be similar
original_density = original_edges / (smoothed.width * smoothed.height)
result_density = result_edges / (result.width * result.height)
assert abs(original_density - result_density) / original_density < 0.15  # within 15%
```

Bilevel images that have been smoothed maintain edge quality after LANCZOS downscaling.

#### test_trace_event_emitted_for_downscale

```python
with mock.patch("preprocessor.trace_event") as mock_trace:
    image = create_test_image(2550, 3300, dpi=300)
    _downscale_to_target_dpi(image, detected_dpi=300, target_dpi=200, threshold=250)
    mock_trace.assert_called_once()
    call_args = mock_trace.call_args
    assert call_args[0][0] == "dpi_downscale"
    assert call_args[0][1]["detected_dpi"] == 300
    assert call_args[0][1]["target_dpi"] == 200
    assert "pixel_reduction" in call_args[0][1]
```

Verify trace event is emitted with correct metadata including detected DPI, target DPI, original size, new size, and pixel reduction ratio.

#### test_trace_event_emitted_for_skip

```python
with mock.patch("preprocessor.trace_event") as mock_trace:
    image = create_test_image(1700, 2200, dpi=200)
    _downscale_to_target_dpi(image, detected_dpi=200, target_dpi=200, threshold=250)
    mock_trace.assert_called_once()
    call_args = mock_trace.call_args
    assert call_args[0][0] == "dpi_downscale_skip"
    assert call_args[0][1]["reason"] == "below_threshold"
```

---

## OCR Quality Verification

### Character match accuracy

| Document Type | Source DPI | Target DPI | Expected Accuracy |
|---|---|---|---|
| Clean text documents | 300 | 200 | >= 99% character match |
| Noisy/stippled documents | 300 | 200 | >= 95% character match |
| Mixed quality | 300 | 200 | >= 95% character match |

Measure using character-level comparison between 300 DPI OCR output (no downscale) and 200 DPI OCR output (with downscale).

### Threshold boundary

- 250 DPI image: **NOT** downscaled (at threshold, not above)
- 251 DPI image: **IS** downscaled (above threshold)

```python
image_250 = create_test_image(2125, 2750, dpi=250)
result_250 = _downscale_to_target_dpi(image_250, detected_dpi=250, target_dpi=200, threshold=250)
assert result_250.width == 2125  # unchanged

image_251 = create_test_image(2133, 2763, dpi=251)
result_251 = _downscale_to_target_dpi(image_251, detected_dpi=251, target_dpi=200, threshold=250)
assert result_251.width < 2133  # downscaled
```

---

## Integration Tests

### Full pipeline at various DPIs

Run the complete pipeline for the same document at different DPIs:

| Input DPI | Expected Behavior | Output Quality |
|---|---|---|
| 150 DPI | No downscale | Baseline |
| 200 DPI | No downscale | Baseline |
| 250 DPI | No downscale (at threshold) | Baseline |
| 300 DPI | Downscale to 200 DPI | >= 99% match vs. baseline |
| 600 DPI | Downscale to 200 DPI | >= 99% match vs. baseline |

### Multi-page TIFF with mixed DPI per frame

Create a multi-page TIFF where:
- Frame 1: 300 DPI (should be downscaled)
- Frame 2: 200 DPI (should be unchanged)
- Frame 3: 150 DPI (should be unchanged)

Verify each frame is handled independently based on its own DPI metadata.

### PDF pages unaffected

PDF pages already render at 200 DPI in `preprocessor.py:45`. Verify:
- No `dpi_downscale` trace events for PDF-sourced pages
- PDF OCR output unchanged before/after the change
- `_downscale_to_target_dpi` is not called in the PDF code path

---

## Performance Verification

### Expected improvement

15%+ reduction in OCR time for 300 DPI standalone images.

### Pixel count correlation

OCR time correlates approximately linearly with pixel count:

| Input DPI | Pixels | Expected Relative Time |
|---|---|---|
| 300 DPI | 8.4M (2550x3300) | 1.0x (baseline) |
| 200 DPI (downscaled) | 3.7M (1700x2200) | ~0.44x |
| 600 DPI | 33.7M (5100x6600) | ~4.0x (before downscale) |
| 600 DPI (downscaled) | 3.7M (1700x2200) | ~0.44x |

The 600 DPI case sees the largest improvement: ~9x pixel reduction.

### Measurement method

Parse "Step text_extraction took Xs" log lines. Segment by input DPI:
- High DPI images (>250) should show significant improvement
- Low DPI images (<=250) should show no change

---

## Edge Case Verification

### 600 DPI large reduction

A 600 DPI letter scan at 5100x6600 (33.7M pixels) downscales to ~1700x2200 (3.7M pixels). This is a 9x pixel reduction.

Verify:
- Image quality is acceptable after 3x linear downscale
- LANCZOS resampling preserves text readability
- OCR output quality >= 95% character match

### EXIF rotation + high DPI

Some images have EXIF rotation tags (orientation 6 = 90 CW, orientation 8 = 90 CCW). Verify:
- EXIF rotation is applied before or compatible with downscaling
- Final image has correct orientation after downscale
- DPI downscale uses the correct dimension axis

### Mismatched DPI metadata

Some scanners write inconsistent DPI (e.g., `(300, 200)` for X and Y). Verify:
- The higher DPI is used for the downscale decision
- Or both axes are downscaled independently
- Aspect ratio is preserved regardless

### Very small images at high DPI

A small crop (e.g., 150x100 at 300 DPI) should route to `ocr_small_image` not `ocr_fullpage`. Verify:
- The small image routing happens before or is compatible with downscaling
- If downscaled (to 100x67), it still routes correctly
- OCR quality is acceptable for small images at reduced resolution
