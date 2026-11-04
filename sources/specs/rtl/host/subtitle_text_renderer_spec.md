# subtitle_text_renderer specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: Fixed-font text rendering and hold-safe upload.

Contract: Unicode BMP character codes only, immutable2048glyph FPGA ROM, default4Chinese messages, ordinary and urgent upload banks. Complete POS host write bundle captured NEG, same POS text RAM write. No PC bitmap generation required. Public rendering outputs identical to previous accepted path for130000cycles.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module subtitle_text_renderer #(
    parameter integer SECOND_CYCLES = 50000000
) (
    input wire clk,
    input wire rst_n,
    input wire text_begin,
    input wire upload_in_progress,
    input wire upload_urgent,
    input wire [6:0] upload_length,
    input wire [7:0] upload_seconds,
    input wire text_write,
    input wire [5:0] text_address,
    input wire [15:0] text_code,
    input wire text_commit,
    input wire restore_default,
    input wire cancel_urgent,
    output wire ready,
    output wire done,
    output wire [7:0] result,
    output wire interrupt_active,
    output wire [31:0] diagnostic,
    input wire bitmap_ready,
    input wire bitmap_done,
    input wire bitmap_scroll_done,
    output wire bitmap_write,
    output wire [11:0] bitmap_address,
    output wire [15:0] bitmap_data,
    output wire [11:0] bitmap_width,
    output wire bitmap_commit
);
```

Verification evidence: validation/text_bundle.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

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
