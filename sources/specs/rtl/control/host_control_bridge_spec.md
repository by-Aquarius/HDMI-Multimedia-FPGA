# host_control_bridge specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: CRC-checked host control and read-only diagnostics.

R298 mode query: command 0F returns byte A0=audio_pair_mode, A1=0, D0=0, D1=A3. In the 48-bit little-endian reply_body the mode occupies bits23:16 and the capability marker bits47:40. Command13 accepts only0 or1, rejects other values without changing state, and reset selects0. No interface or UART cycle latency changes in this repair. tb_audio_mode_protocol exercises both modes, capability positions, invalid arguments, invalid CRC, and the existing subtitle/urgent recovery path (34 checks).

Contract: Protocol4 retained, KEY4-/KEY5+,volume0..10. New0C/0D/0E queries must bypass generic ACK overwrite; other commands unchanged. Capture entire48bit reply body NEG for original POS CRC-byte processing and packet assembly. Actual UART tests include upload/urgent/cancel/invalidCRC/timeout/recovery and full32bit diagnostics.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module host_control_bridge #(
    parameter integer BIT_CYCLES = 434,
    parameter integer FRAME_TIMEOUT = 500000,
    parameter integer VOLUME_STEP_CYCLES = 50000,
    parameter integer COMMIT_TIMEOUT_CYCLES = 50000000,
    parameter integer UPLOAD_TIMEOUT_CYCLES = 250000000
) (
    input wire clk,
    input wire rst_n,
    input wire serial_rx,
    output wire serial_tx,
    input wire [4:0] active_index,
    input wire [4:0] media_count,
    input wire [2:0] playback_state,
    input wire [4:0] volume_level,
    input wire [7:0] brightness,
    input wire [2:0] speed_level,
    input wire [7:0] error_code,
    input wire [7:0] status_flags,
    input wire [31:0] fault_snapshot,
    input wire [31:0] live_snapshot,
    input wire [31:0] audio_snapshot,
    input wire [31:0] load_snapshot,
    output reg [15:0] key_pulse,
    output reg [2:0] audio_diagnostic_mode,
    input wire text_ready,
    input wire text_done,
    input wire [7:0] text_result,
    input wire [31:0] recovery_snapshot,
    input wire [31:0] scheduler_snapshot,
    input wire [31:0] subtitle_snapshot,
    input wire [31:0] prompt_snapshot,
    input wire [31:0] audio_health_snapshot,
    input wire [31:0] memory_health_snapshot,memory_crc_snapshot,
    input wire [31:0] memory_pass_snapshot,
    output wire upload_in_progress,
    output reg text_begin,
    output reg text_urgent,
    output reg [7:0] text_seconds,
    output reg [6:0] text_length,
    output reg text_write,
    output reg [5:0] text_address,
    output reg [15:0] text_code,
    output reg text_commit,
    output reg restore_default,
    output reg cancel_urgent
);
```

Verification evidence: validation/memory_host_protocol.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. Programming remains deferred by user. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

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
