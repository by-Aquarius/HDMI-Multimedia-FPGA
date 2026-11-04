# image_audio_pair_selector

## Functional contract

The player enumerates BMP images and WAV tracks independently. `pair_mode=0`
selects WAV 0 for every image and keeps it continuous across the slideshow.
`pair_mode=1` selects WAV ordinal `N` for image ordinal `N`.

- `pair_valid` requires an image ordinal inside `image_count`.
- `audio_present` requires WAV 0 in shared mode or the same ordinal inside
  `audio_count` in per-image mode.
- `audio_missing` is high for a valid image that has no paired WAV.
- `audio_index` always equals `image_index`; no missing track falls back to WAV 0.

The source directory order must therefore place picture `N` and its soundtrack
`N` at the same ordinal in their respective BMP/WAV sequences.

## Timing

All ports are combinational. The parent samples the result in the 50 MHz media
control domain and restarts audio from the image-index commit pulse.

```text
pair_mode        0   0   1   1   1
image_index      0   2   0   1   2
image_count      3   3   3   3   3
audio_count      2   2   2   2   2
audio_index      0   0   0   1   2
pair_valid       1   1   1   1   1
audio_present    1   1   1   1   0
audio_missing    0   0   0   0   1
```
