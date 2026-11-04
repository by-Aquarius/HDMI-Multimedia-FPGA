# media_terminal_top specification review draft

Status: manual review draft. Strict generated-deliverable gates do not pass. The governed WaveDrom runtime check reports npm and wavedrom@3.6.1 missing, so no validated SVG/spec bundle is claimed and no dependency was installed.

Purpose: Integrated reset and memory/video generation ownership.

Contract: Five control/three memory clusters: async assert, twoPOS synchronizer stages, finalNEG release forPOS consumers. PHY pin output reset releases separatelyPOS. Pixel reset unchanged. Curtain frame pulse alone delayed1PCLK in vertical blank; main raster, frame swap and RGB/valid pipelines unchanged. Memory metadata crosses2FF and mailbox settles3FF. Debug snapshots are observational, not atomic control.

Exact public interface excerpt from the current source (not a replacement parser/quality result):

```verilog
module media_terminal_top #(
    // Build-time switch: 0 disables the startup/source transition and passes
    // the raw image straight to the OSD/mixer path.
    parameter integer FADE_ENABLE = 1,
    // 0x20 completes each directional wipe phase in about eight frames at
    // 60 fps. SOFT_WIDTH tracks the per-frame sweep to keep the edge continuous.
    parameter [7:0] FADE_STEP = 8'h20
) (
    input  wire       FPGA_SYS_50M_CLK_P,
    input  wire       SD_MISO,
    input  wire       UART_RX,
    output wire       UART_TX,
    input  wire       SW0,
    input  wire       SW1,
    input  wire       SW2,
    output wire       SD_CS,
    output wire       SD_MOSI,
    output wire       SD_CLK,
    output wire       HDMI_CLK_P,
    output wire       HDMI_D2_P,
    output wire       HDMI_D1_P,
    output wire       HDMI_D0_P,
    output wire       Audio_PWM,
    input  wire [3:0] Key_Col,
    output wire [3:0] Key_Row,
    output wire       VGA_HS,
    output wire       VGA_VS,
    output wire [4:0] VGA_R,
    output wire [5:0] VGA_G,
    output wire [4:0] VGA_B,
    output wire       LED0,
    output wire       LED1,
    output wire       LED2,
    output wire       LED3,
    output wire       LED4,
    output wire       LED5,
    output wire       LED6,
    output wire       LED7,
    output wire [3:0] DigitronCS_Out,
    output wire [7:0] Digitron_Out
);
```

Verification evidence: validation/phase_reset.log. Simulation does not prove physical board recovery; native timing evidence is in reports/r294_timing_simple.rpt. R295 board programming and acceptance are pending the current repair validation. Asynchronous external changes within the private half-cycle RAM interface are outside the registered-producer contract.

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

## Image request validity and frame ownership

The registered bridge request is valid only after display_valid has latched the first real frame-manager swap ACK. It retains the existing one-clock request pipeline. Later missing-line requests still assert bridge_pixel_error and remain visible. The direct bridge receives mapper_frame_start_pxl as raster_frame_start_pxl; this pulse occurs 33 pixel clocks after VS falling, inside vertical blank. It releases prior raster-frame reader ownership and does not reset CRC, front-frame selection or the SDRAM contents.

```json
{"signal":[{"name":"pxlclk","wave":"p......."},{"name":"swap_ack_event","wave":"0.10...."},{"name":"display_valid","wave":"0..1...."},{"name":"mapper_req","wave":"1......."},{"name":"bridge_req_q","wave":"0...1..."},{"name":"vertical_frame_start","wave":"0.....10"}]}
```

Verification: full source compile, real raster startup/letterbox/dimension-swap regression, actual SDRAM/CRC end-to-end test. Physical listening and display observations remain separate from automated counters.

## WAV ownership across image changes

Normal slideshow playback selects WAV index zero when only one WAV exists.
The transport tracks that selected WAV index, not the image index. Changing
from one image to another while both images map to the same WAV must not
flush the audio FIFO, restart the WAV parser, or create a sample boundary.
Resume after pause continues to re-open the current track as a separate
documented transport event. A real WAV-index change still restarts the track.
The 180-second board trace showed 26 image commits, zero audio underruns,
zero audio errors, and zero starvation events with the corrected ownership.
