# sd_sector_reader specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: Read-only SD sector RAM half-cycle boundary.

Contract: Private SPI receive and state/address sources are POS registers. NEG captures write enable/address/data and RAM read address; original POS writes/read pipeline preserved. No extra emit wait state; byte0 must not duplicate. 2048realRAMwrites/95044cycles equivalent with serial-card retry/CRC/address fallback test.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module converts LBA to byte address by
//     multiplying by 512.
//
// Protocol contract:
//   * C02 must have completed initialization: sd_init_ok=1.
//   * req_ready accepts a request only while idle or after a recoverable error.
//   * rsp_valid pulses once per data byte; rsp_last is asserted with the final
//     byte of the complete request; rsp_error is latched until the next request.
//   * A single sector uses CMD17. More than one sector uses CMD18 and CMD12.
//   * This module has no card-modification path.
//
// This module reuses the C01 read-only SPI byte engine and has no TF-card
// card-modification operation.
// -----------------------------------------------------------------------------
module sd_sector_reader #(
    parameter integer CLK_DIV                    = 2,
    parameter integer RESPONSE_TIMEOUT_BYTES    = 32,
    parameter integer DATA_TOKEN_TIMEOUT_BYTES  = 1024
) (
    input  wire        clk_50m,
    input  wire        rst_n,

    // C02 initialization status.
    input  wire        sd_init_ok,
    input  wire        sd_high_capacity,

    // Read request. req_lba is a sector/LBA address; req_count is a sector
    // count, with each sector exactly 512 bytes.
    input  wire        req_valid,
    input  wire [31:0] req_lba,
    input  wire [15:0] req_count,
    output wire        req_ready,

    // Read response stream.
    output reg         rsp_valid,
    output reg  [7:0]  rsp_data,
    output reg         rsp_last,
    output reg  [7:0]  rsp_error,
    output wire        busy,

    // SD SPI pins.
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n
);
```

Verification evidence: validation/sector_bundle.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

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
