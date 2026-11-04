# host_subtitle_plane specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: Subtitle RAM timing and bank publication.

Contract: POS producer bundle is captured NEG as a whole enable/bank/address/data; same next POS RAM write as original. NEG stages use synchronous reset; RAM enable gates reset. Public ready/commit/pixel output latency unchanged. Pixel frame-boundary bank commit and bottom fullwidth scrolling remain original.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module host_subtitle_plane (
    input wire ctrl_clk,
    input wire ctrl_rst_n,
    input wire write_valid,
    input wire [11:0] write_address,
    input wire [15:0] write_data,
    input wire [11:0] write_width,
    input wire commit,
    input wire hide,
    output wire ready,
    output reg commit_done,
    output reg scroll_done,
    input wire pixel_clk,
    input wire pixel_rst_n,
    input wire frame_boundary,
    input wire pixel_valid,
    input wire display_enable,
    input wire [11:0] pixel_x,
    input wire [11:0] pixel_y,
    output wire subtitle_enabled,
    output wire subtitle_alpha,
    output wire [15:0] subtitle_rgb
);
```

Verification evidence: validation/subtitle_bundle_phase.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

Timing review: asynchronous reset asserts immediately. POS source data settles before NEG capture; subsequent POS consumer sees the same source value as before. Memory pin outputs use NEG and input capture POS. Exact bank/mailbox timing and CRC invariants are tested in the real implementation testbench, not established by this illustrative waveform.

```json
{
  "signal": [
    {
      "name": "clk_POS_NEG",
      "wave": "p......."
    },
    {
      "name": "producer_bundle",
      "wave": "x.3.4.5.",
      "data": [
        "A",
        "B",
        "C"
      ]
    },
    {
      "name": "NEG_capture",
      "wave": "x..3.4.5",
      "data": [
        "A",
        "B",
        "C"
      ]
    },
    {
      "name": "POS_consumer",
      "wave": "x...3.4.",
      "data": [
        "A",
        "B"
      ]
    }
  ],
  "head": {
    "text": "Conceptual half-cycle bundle; POS writes unchanged (review draft)"
  },
  "config": {
    "hscale": 2
  }
}
```
