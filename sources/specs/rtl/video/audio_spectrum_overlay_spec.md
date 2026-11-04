# audio_spectrum_overlay

## Responsibility and clocks

This module renders both audio visualization layers in the left-side HUD of the
1280x720 raster:

- spectrum frame: x=32..367, y=176..375;
- waveform frame: x=32..367, y=400..599.

Both panels consume the pixel clock and asynchronous active-low reset. The
spectrum levels and waveform samples are registered together with the raster
coordinate so color and transparency remain aligned through the existing pixel
pipeline.

## Interface

```verilog
module audio_spectrum_overlay #(
    parameter integer SPECTRUM_LEFT=32,
    parameter integer SPECTRUM_RIGHT=368,
    parameter integer SPECTRUM_TOP=176,
    parameter integer SPECTRUM_BOTTOM=376,
    parameter integer SCOPE_LEFT=32,
    parameter integer SCOPE_RIGHT=368,
    parameter integer SCOPE_TOP=400,
    parameter integer SCOPE_BOTTOM=600
)(
    input wire clk,
    input wire rst_n,
    input wire [11:0] pixel_x,
    input wire [11:0] pixel_y,
    input wire [95:0] bar_tops,
    input wire [7:0] waveform_sample,
    input wire [7:0] waveform_previous,
    input wire panel_enable,
    output wire alpha,
    output wire [15:0] rgb565
);
```

## Data contract and layout

The eight spectrum bands use 32-pixel slots. The waveform occupies the same
horizontal span below the spectrum. Both panels are opaque inside their borders
and fully transparent outside, leaving the right-side image and bottom subtitle
strip untouched.

```text
clock       _/^\_/^\_/^\_/^\_/^\
pixel_x     X  32 ... 367 X  400 ...
pixel_y     X 176 ... 375 X 400 ... 599
alpha       0   1 ...  1   0   1 ...  1
```
