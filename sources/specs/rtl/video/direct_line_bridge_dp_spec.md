# direct_line_bridge_dp specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: Owned, verified direct line refill.

Contract: Two banks x even/odd512x16 vendor BRAM. Four-phase request carries stable row/epoch; three synchronizer stages. Revoke ACK before first write, active bank held through blank, frame commit changes epoch, stale completion discarded. CRC failure never published, one retry only. One pixel response latency. Ordinary refill deadline22.222us; cutover/error retry separately60us covered window.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module direct_line_bridge_dp #(
    parameter integer FRAME_WIDTH=640,
    parameter integer FRAME_HEIGHT=480
) (
    input wire ctrl_clk,ctrl_rst_n,pxl_clk,pxl_rst_n,
    input wire line_req_pulse_pxl,
    input wire [11:0] line_req_y_pxl,
    input wire [20:0] frame_base_word_ctrl,
    output reg line_ready_pulse_pxl,
    output reg [11:0] line_ready_y_pxl,
    output reg line_ready_bank_pxl,
    input wire pixel_req_valid,
    input wire [11:0] pixel_req_x,pixel_req_y,
    output wire pixel_req_ready,pixel_valid,
    output wire [15:0] pixel_data,
    output reg pixel_error,
    output wire mem_rd_valid,
    input wire mem_rd_ready,
    output wire [20:0] mem_rd_addr_word,
    input wire mem_rd_rsp_valid,
    input wire [31:0] mem_rd_rsp_data,
    input wire mem_rd_error,
    output wire line_urgent_ctrl,
    output wire mem_burst_valid,
    input wire mem_burst_ready,
    output wire [20:0] mem_burst_addr_word,
    output wire [3:0] mem_burst_len,
    input wire mem_burst_rsp_valid,
    input wire [31:0] mem_burst_rsp_data,
    input wire mem_burst_rsp_last,mem_burst_rsp_error,
    input wire frame_changed_pxl,front_frame_select_pxl,
    input wire front_ready_ctrl,front_frame_select_ctrl,
    input wire [11:0] front_width_ctrl,front_height_ctrl,
    output reg crc_line_start_ctrl,
    output wire crc_frame_select_ctrl,
    output wire [8:0] crc_line_y_ctrl,
    output wire [11:0] crc_width_ctrl,
    output wire crc_word_valid_ctrl,
    output wire [31:0] crc_word_data_ctrl,
    output reg crc_line_done_ctrl,
    input wire crc_result_valid_ctrl,crc_result_ok_ctrl,
    output reg line_error_event_ctrl,
    output reg [15:0] crc_failure_count_ctrl,
    output reg [11:0] last_crc_error_y_ctrl,
    output reg [15:0] verified_frame_count_ctrl
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

## Raster-frame release and sole request producer

New raster_frame_start_pxl is synchronous to pxl_clk and occurs during vertical blank after the old raster has finished. It clears only active_valid_pxl, allowing a pending revoke of the previous raster owner to complete. Horizontal blank never releases ownership, preserving repeated scaled-row reads. Frame_changed_pxl still invalidates bank metadata and advances the frame epoch, but clears the queued request instead of creating a second row-zero request; the mapper is the sole producer. Source request/revoke/data/CRC CDC timing and one-pixel BRAM response latency are preserved.

```json
{"signal":[{"name":"pxl_clk","wave":"p......."},{"name":"old_active_owner","wave":"1..0...."},{"name":"raster_frame_start","wave":"0.10...."},{"name":"mapper_row0_request","wave":"0..10..."},{"name":"revoke_ack","wave":"0...10.."},{"name":"line_ready","wave":"0.....10"}]}
```

Tests: real 720p ordinary/letterbox/narrow/geometry-swap/startup scenarios; explicit framebuffer+writeCDC+arbiter+timedPHY+CRC full 640x480 and error injection regression. The raster service-model and actual-PHY tests are separate evidence.
