# sdram_arbiter specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: Display deadline arbitration.

Contract: One outstanding transaction. During line_urgent, defer background frame writes across all burst gaps so no repeated write/read turnaround steals the deadline. All valid/ready and terminal responses retain original semantics; bounded PHY completion is required. Audio PCM storage/render pipeline is independent of these picture line banks.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module sdram_arbiter #(
    parameter [20:0] FRAME_A_BASE_WORD   = 21'h00000,
    parameter [20:0] FRAME_B_BASE_WORD   = 21'h40000,
    parameter [20:0] AUDIO_BUF_BASE_WORD = 21'h80000
) (
    input wire clk, input wire rst_n,
    input wire line_urgent,
    input wire wr_valid, output wire wr_ready, input wire [20:0] wr_addr_word,
    input wire [31:0] wr_data, input wire [3:0] wr_strb,
    output reg wr_done, output reg wr_error,
    input wire rd_valid, output wire rd_ready, input wire [20:0] rd_addr_word,
    output reg rd_rsp_valid, output reg [31:0] rd_data, output reg rd_error,
    input wire burst_valid, output wire burst_ready, input wire [20:0] burst_addr_word,
    input wire [3:0] burst_len, output reg burst_rsp_valid,
    output reg [31:0] burst_rsp_data, output reg burst_rsp_last, output reg burst_rsp_error,
    output wire sdram_init_done, output wire busy,
    output reg phy_req_valid, input wire phy_req_ready, output reg phy_req_write,
    output reg [20:0] phy_req_addr_word, output reg [31:0] phy_req_wdata,
    output reg [3:0] phy_req_wstrb, input wire phy_rsp_valid,
    input wire [31:0] phy_rsp_rdata, input wire phy_rsp_error,
    output reg phy_burst_valid, input wire phy_burst_ready,
    output reg [20:0] phy_burst_addr_word, output reg [3:0] phy_burst_len,
    input wire phy_burst_rsp_valid, input wire [31:0] phy_burst_rsp_data,
    input wire phy_burst_rsp_last, input wire phy_burst_rsp_error,
    input wire phy_init_done
);
```

Verification evidence: validation/final_full_frame.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

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
