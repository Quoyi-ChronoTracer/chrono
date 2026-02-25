# OPT-5: DPI Downscale for Standalone Images

## Current DPI Handling

`_extract_dpi()` in `image_profile.py:468` uses 3-tier detection:

1. PIL `.info["dpi"]` metadata
2. TIFF tag 282 (XResolution)
3. Dimension-based heuristics (e.g., 2550x3300 implies 300 DPI letter-size)

DPI influences `recommend_params()` `scale_factor`, but `scale_factor` is **never consumed** by `ocr_fullpage()` -- it is advisory only for full-page images.

### Standalone Image Path

Image is loaded at full native resolution in `preprocessor.py:88-102`. A 300 DPI letter scan is 2550x3300 = 8.4M pixels hitting Tesseract directly.

### PDF Path

Already renders at 200 DPI (`preprocessor.py:45`). No changes needed for PDFs.

---

## Proposed Change

Add `_downscale_to_target_dpi()` in `preprocessor.py`.

### Parameters

- **Target DPI:** 200
- **Trigger threshold:** 250 DPI (only downscale if detected DPI > 250)

### Insertion Point

After bilevel smoothing (line 99), before `np.array()` conversion (line 101):

```python
# preprocessor.py, inside preprocess_standalone_image()
# ... bilevel smoothing ...
image = _downscale_to_target_dpi(image, detected_dpi, target_dpi=200, threshold=250)  # NEW
# gray = np.array(image) ...
```

### Implementation

```python
def _downscale_to_target_dpi(
    image: Image.Image,
    detected_dpi: float,
    target_dpi: int = 200,
    threshold: int = 250,
) -> Image.Image:
    """Downscale image to target DPI if above threshold.

    Returns the original image unchanged if DPI is below threshold or unknown (0).
    """
    if detected_dpi <= 0 or detected_dpi <= threshold:
        trace_event("dpi_downscale_skip", {
            "detected_dpi": detected_dpi,
            "reason": "below_threshold" if detected_dpi > 0 else "unknown_dpi",
        })
        return image

    try:
        scale = target_dpi / detected_dpi
        new_size = (int(image.width * scale), int(image.height * scale))
        downscaled = image.resize(new_size, Image.LANCZOS)

        # Update DPI metadata
        downscaled.info["dpi"] = (target_dpi, target_dpi)

        trace_event("dpi_downscale", {
            "detected_dpi": detected_dpi,
            "target_dpi": target_dpi,
            "original_size": [image.width, image.height],
            "new_size": list(new_size),
            "pixel_reduction": round(1 - (new_size[0] * new_size[1]) / (image.width * image.height), 3),
        })
        return downscaled
    except Exception:
        # Per Engineering.md: fail safe, return original
        trace_event("dpi_downscale_error", {"detected_dpi": detected_dpi})
        return image
```

---

## Key Finding: `scale_factor` Not Consumed

`scale_factor` is computed by `recommend_params()` but is not consumed in `ocr_fullpage()` for the full-page path. This means:

- Downscaling does not conflict with any existing scale logic
- The downscale happens before `analyze_image()`, so profile metrics are based on the downscaled image
- This is correct behavior: we want Tesseract to see the image at 200 DPI

Document this in a code comment at the downscale insertion point.

---

## Edge Cases

### No DPI metadata

When `_extract_dpi()` returns 0 (no metadata detected), do not downscale. This is the safe default -- we cannot determine if the image would benefit from downscaling.

Post Risk-7: The "no metadata" case is now much rarer. Risk-7's width-based heuristic with standard paper size detection (`_estimate_dpi_from_width()`) and `_snap_to_standard_dpi()` means most standard-sized document images will have an accurate DPI value even without embedded metadata. The dimension heuristic path is now the primary fallback, not the exception.

### 600 DPI scans

A 600 DPI letter scan is 5100x6600 = 33.7M pixels. Downscaling to 200 DPI yields 1700x2200 = 3.7M pixels -- a 9x pixel reduction. This produces the largest performance gain.

### Multi-page TIFFs

Work per-frame. Each frame is independently downscaled based on its own DPI metadata.

Post Risk-12: Per-frame DPI is now reliably available. Risk-12's `_extract_tiff_frame_tags()` helper in `image_extractor.py` preserves DPI tags (282, 283, 296, 262) when extracting individual TIFF frames via `tiffinfo=` on `img.save()`. This means `_extract_dpi()` will find valid metadata on extracted frames rather than falling back to heuristics. The per-frame downscale logic can rely on accurate DPI values for multi-page TIFFs.

### Bilevel after smooth

The smoothing step happens before downscale. LANCZOS resampling preserves edge quality for bilevel-smoothed images. No interaction issues.

---

## Interactions with Risk Implementations

### Risk-7: DPI Heuristic Improvements

`_extract_dpi()` in `image_profile.py` has been significantly improved. The old 3-tier detection (PIL metadata, TIFF tag, dimension heuristic) has been replaced with a more robust pipeline:

- New constants: `_PAPER_WIDTHS_INCHES`, `_STANDARD_DPIS`
- New helpers: `_snap_to_standard_dpi()`, `_estimate_dpi_from_width()`
- Tiers 3+4 replaced with multi-format width-based heuristic + aspect-ratio guard (1.2-1.7)
- Handles Letter, Legal, A4, and other standard paper sizes

**Impact on OPT-5:** The `detected_dpi` value fed into `_downscale_to_target_dpi()` is now much more reliable. Previously, a significant number of standalone images would return DPI=0 and skip downscaling. With Risk-7's improvements, more images will have accurate DPI values, increasing the hit rate of the downscale optimization. The "No DPI metadata" edge case still exists but is now the minority path.

### Risk-12: TIFF Metadata Preservation

`image_extractor.py` now includes a `_extract_tiff_frame_tags()` helper that preserves DPI tags (282, 283, 296, 262) when extracting individual frames from multi-page TIFFs. The `tiffinfo=` parameter is passed to `img.save()`.

**Impact on OPT-5:** Multi-page TIFF frames now carry DPI metadata from the original file. When OPT-5 processes TIFF frames, `_extract_dpi()` will find valid DPI metadata via PIL `.info["dpi"]` or TIFF tag 282 (tiers 1-2) rather than falling through to heuristics. This makes per-frame downscale decisions more accurate and consistent.

### Risk-5: scale_factor Dead Code

`recommend_params()` now has an advisory comment explicitly documenting that `scale_factor` is NOT consumed by `ocr_fullpage()`. The `_reasons` strings include an `(advisory)` qualifier.

**Impact on OPT-5:** No conflict. This confirms the "Key Finding" section above -- `scale_factor` remains advisory-only. The explicit code documentation means OPT-5's downscale logic does not need to coordinate with any scale_factor consumer.

### Testing Considerations

`test_image_profile.py` already exists from Risk-7's implementation. DPI-related tests for OPT-5 should extend that file rather than duplicating DPI detection test infrastructure. The new `test_dpi_downscale.py` file should focus on the downscale logic itself and can rely on Risk-7's test fixtures for DPI detection coverage.

---

## File Changes Summary

| # | File | Change |
|---|---|---|
| 1 | `preprocessor.py` | Add `_downscale_to_target_dpi()` function, modify `preprocess_standalone_image()`, add imports (`Image` from PIL) |
| 2 | `tests/unit/pipeline/steps/ocr_neurons/test_dpi_downscale.py` | **New file** -- 10 unit tests |
| 3 | `tests/unit/pipeline/steps/ocr_neurons/test_preprocessor.py` | **Extend** -- 2 integration tests |
| 4 | `tests/unit/pipeline/steps/ocr_neurons/test_image_profile.py` | **Extend** -- add DPI-downscale interaction tests that verify Risk-7's improved heuristics feed correct values to the downscale function |

### New test file: `test_dpi_downscale.py` (10 tests)

1. **test_300_dpi_downscaled** -- 2550x3300 at 300 DPI -> ~1700x2200
2. **test_200_dpi_unchanged** -- 200 DPI image returned as-is
3. **test_150_dpi_unchanged** -- 150 DPI image returned as-is
4. **test_no_dpi_metadata_standard_page** -- 2550x3300 with DPI=0 -> heuristic detects 300, downscales
5. **test_no_dpi_metadata_small_image** -- 800x600 with DPI=0 -> no downscale
6. **test_aspect_ratio_preserved** -- width/height ratio within 0.5% after downscale
7. **test_dpi_metadata_updated** -- output image .info["dpi"] == (200, 200)
8. **test_600_dpi_large_reduction** -- 5100x6600 -> ~1700x2200 (9x pixel reduction)
9. **test_bilevel_edge_preservation** -- bilevel-smoothed image maintains edge quality after downscale
10. **test_trace_event_emitted** -- verify trace_event called with correct downscale metadata

### Extended tests in `test_preprocessor.py` (2 tests)

1. **test_full_pipeline_300dpi** -- full `preprocess_standalone_image()` at 300 DPI -> output is 200 DPI equivalent
2. **test_full_pipeline_200dpi** -- full `preprocess_standalone_image()` at 200 DPI -> no size change

### Extended tests in `test_image_profile.py` (3 tests)

1. **test_risk7_heuristic_feeds_downscale_letter** -- verify `_extract_dpi()` returns 300 for a 2550x3300 image (no metadata), confirming downscale would trigger
2. **test_risk7_heuristic_feeds_downscale_a4** -- verify `_extract_dpi()` returns 300 for a 2480x3508 A4 image (no metadata), confirming downscale would trigger
3. **test_risk12_tiff_frame_dpi_preserved** -- verify that a TIFF frame extracted via `_extract_tiff_frame_tags()` retains DPI metadata readable by `_extract_dpi()`
