# eg4_sdram_phy specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: 50MHz SDRAM physical timing boundary.

Contract: Core POS accepts only valid&&ready; command/address/DQM/DQ/OE NEG; DQ sampled POS and returned one further POS. pin_reset_n asserts async and releases POS, while core reset releases NEG. Init200us+CKE wake+PRE/tRP/2REF/MRS. Reject len0/>8/aligned8-word wrap; STOP/drain5 cycles; scalar/burst timeout error then precharge before reuse.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module provides a single-outstanding, one-word transaction interface.
// A later frame/line layer may issue bursts as a sequence of word requests, but
// it must not drive random requests directly from the pixel clock domain.
// The physical pins are the EG4 integrated-SDRAM pins. In the formal top they
// are connected to the device's 2M x 32 SDRAM primitive/pin wrapper.
// -----------------------------------------------------------------------------
module eg4_sdram_phy #(
    parameter integer INIT_WAIT_CYCLES        = 10000, // 200 us @ 50 MHz
    parameter integer TRP_CYCLES              = 2,
    parameter integer TRCD_CYCLES             = 2,
    parameter integer CAS_LATENCY             = 3,
    parameter integer TRSC_CYCLES             = 2,
    parameter integer TRFC_CYCLES             = 7,
    parameter integer REFRESH_INTERVAL_CYCLES = 390,   // ~7.8 us @ 50 MHz
    parameter integer REQUEST_TIMEOUT_CYCLES  = 4095
) (
    input  wire        clk,
    input  wire        rst_n,

    // One outstanding transaction. Address is SDRAM word address, not bytes.
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [20:0] req_addr_word,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,

    // Read burst interface: BL is 1..8 words and must not cross an SDRAM row.
    input  wire        burst_req_valid,
    output wire        burst_req_ready,
    input  wire [20:0] burst_req_addr_word,
    input  wire [3:0]  burst_req_len,
    output reg         burst_rsp_valid,
    output wire [31:0] burst_rsp_rdata,
    output reg         burst_rsp_last,
    output reg         burst_rsp_error,

    output reg         rsp_valid,
    output wire [31:0] rsp_rdata,
    output reg         rsp_error,
    output reg         timeout_error,
    output reg         init_done,

    // EG4 integrated SDRAM physical interface.
    output wire        sdram_clk,
    output reg         sdram_cke,
    output reg         sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n,
    output reg  [1:0]  sdram_ba,
    output reg  [10:0] sdram_addr,
    inout  wire [31:0] sdram_dq,
    output reg  [3:0]  sdram_dqm
);
```

Verification evidence: validation/registered_io_phase.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

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
