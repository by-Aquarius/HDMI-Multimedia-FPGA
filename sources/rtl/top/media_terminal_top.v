`timescale 1ns / 1ps
// G01 integrated media terminal top.
// Read-only chain:
//   SD init -> sector reader -> FAT32 BPB/root scan -> indexed BMP cluster stream
//   -> BMP header/decoder -> RGB565 -> SDRAM FrameB -> line prefetch
//   -> fixed 2x nearest-neighbour mapper -> line bridge -> transition -> OSD
//   -> D09 mixer -> A03 HDMI TX.
//   Indexed WAV cluster stream -> F01/F02/F03/F04 -> Audio_PWM (F3).
//
// The validated R184 video pipeline is preserved. E01/E02/E03 select BMP
// indexes; F04 maps the same compact index to the compact WAV table. Both
// file streams share the C03 sector reader through a single-owner arbiter.
// The design is read-only and never writes the TF card or SPI Flash.
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

    localparam [20:0] FRAME_A_BASE_WORD = 21'h00000;
    localparam [20:0] FRAME_B_BASE_WORD = 21'h40000;
    localparam [20:0] AUDIO_BUF_BASE_WORD = 21'h80000;

    wire clk25m;
    // Keep the control, SD, BMP and frame-loading path on the directly
    // verified 50 MHz oscillator. The pixel and SDRAM PLL domains remain
    // isolated from this control clock.
    wire sdram_ctrl_clk; wire sdram_phy_clk;
    wire ctrl_clk50 = FPGA_SYS_50M_CLK_P;
    wire pxlclk_i;
    wire pxlclk_5x_i;
    wire pll_locked;
    wire [1:0] video_clock_locks;
    reg [1:0] clock_locks_meta_ctrl,clock_locks_sync_ctrl;
    reg [7:0] pll_reset_count = 8'd0;
    wire raw_power_reset_n = pll_reset_count[7];
    wire raw_reset_n = pll_locked && pll_reset_count[7];
    // Asynchronous assertion, two POS stages, then NEG release to POS consumers.
    // Each phase boundary has half a clock for recovery/removal; no reset waiver.
    reg ctrl_reset_meta = 1'b0;
    reg ctrl_reset_settled = 1'b0;
    reg ctrl_reset_sync = 1'b0;
    reg ctrl_reset_ctl_meta = 1'b0;
    reg ctrl_reset_ctl_settled = 1'b0;
    reg ctrl_reset_ctl_sync = 1'b0;
    reg ctrl_reset_img_meta = 1'b0;
    reg ctrl_reset_img_settled = 1'b0;
    reg ctrl_reset_img_sync = 1'b0;
    reg ctrl_reset_aud_meta = 1'b0;
    reg ctrl_reset_aud_settled = 1'b0;
    reg ctrl_reset_aud_sync = 1'b0;
    reg ctrl_reset_play_meta = 1'b0;
    reg ctrl_reset_play_settled = 1'b0;
    reg ctrl_reset_play_sync = 1'b0;
    reg mem_reset_meta = 1'b0;
    reg mem_reset_settled = 1'b0;
    reg mem_reset_sync = 1'b0;
    reg mem_reset_phy_meta = 1'b0;
    reg mem_reset_phy_settled = 1'b0;
    reg mem_reset_phy_sync = 1'b0;
    reg mem_reset_bridge_meta = 1'b0;
    reg mem_reset_bridge_settled = 1'b0;
    reg mem_reset_bridge_sync = 1'b0;
    reg pxl_reset_meta = 1'b0;
    reg pxl_reset_sync = 1'b0;
    always @(posedge ctrl_clk50 or negedge raw_power_reset_n) begin
        if (!raw_power_reset_n) begin
            ctrl_reset_meta <= 1'b0; ctrl_reset_settled <= 1'b0;
            ctrl_reset_ctl_meta <= 1'b0; ctrl_reset_ctl_settled <= 1'b0;
            ctrl_reset_img_meta <= 1'b0; ctrl_reset_img_settled <= 1'b0;
            ctrl_reset_aud_meta <= 1'b0; ctrl_reset_aud_settled <= 1'b0;
            ctrl_reset_play_meta <= 1'b0; ctrl_reset_play_settled <= 1'b0;
        end else begin
            ctrl_reset_meta <= 1'b1; ctrl_reset_settled <= ctrl_reset_meta;
            ctrl_reset_ctl_meta <= 1'b1; ctrl_reset_ctl_settled <= ctrl_reset_ctl_meta;
            ctrl_reset_img_meta <= 1'b1; ctrl_reset_img_settled <= ctrl_reset_img_meta;
            ctrl_reset_aud_meta <= 1'b1; ctrl_reset_aud_settled <= ctrl_reset_aud_meta;
            ctrl_reset_play_meta <= 1'b1; ctrl_reset_play_settled <= ctrl_reset_play_meta;
        end
    end
    always @(negedge ctrl_clk50 or negedge raw_power_reset_n) begin
        if (!raw_power_reset_n) begin
            ctrl_reset_sync <= 1'b0;
            ctrl_reset_ctl_sync <= 1'b0;
            ctrl_reset_img_sync <= 1'b0;
            ctrl_reset_aud_sync <= 1'b0;
            ctrl_reset_play_sync <= 1'b0;
        end else begin
            ctrl_reset_sync <= ctrl_reset_settled;
            ctrl_reset_ctl_sync <= ctrl_reset_ctl_settled;
            ctrl_reset_img_sync <= ctrl_reset_img_settled;
            ctrl_reset_aud_sync <= ctrl_reset_aud_settled;
            ctrl_reset_play_sync <= ctrl_reset_play_settled;
        end
    end
    always @(posedge sdram_ctrl_clk or negedge raw_reset_n) begin
        if (!raw_reset_n) begin
            mem_reset_meta <= 1'b0; mem_reset_settled <= 1'b0;
            mem_reset_phy_meta <= 1'b0; mem_reset_phy_settled <= 1'b0;
            mem_reset_bridge_meta <= 1'b0; mem_reset_bridge_settled <= 1'b0;
        end else begin
            mem_reset_meta <= 1'b1; mem_reset_settled <= mem_reset_meta;
            mem_reset_phy_meta <= 1'b1; mem_reset_phy_settled <= mem_reset_phy_meta;
            mem_reset_bridge_meta <= 1'b1; mem_reset_bridge_settled <= mem_reset_bridge_meta;
        end
    end
    always @(negedge sdram_ctrl_clk or negedge raw_reset_n) begin
        if (!raw_reset_n) begin
            mem_reset_sync <= 1'b0;
            mem_reset_phy_sync <= 1'b0;
            mem_reset_bridge_sync <= 1'b0;
        end else begin
            mem_reset_sync <= mem_reset_settled;
            mem_reset_phy_sync <= mem_reset_phy_settled;
            mem_reset_bridge_sync <= mem_reset_bridge_settled;
        end
    end
    always @(posedge pxlclk_i or negedge raw_reset_n) begin
        if (!raw_reset_n) begin pxl_reset_meta <= 1'b0; pxl_reset_sync <= 1'b0; end
        else begin pxl_reset_meta <= 1'b1; pxl_reset_sync <= pxl_reset_meta; end
    end
    wire ctrl_rst_n = ctrl_reset_sync;
    wire ctrl_rst_ctl_n  = ctrl_reset_ctl_sync;
    wire ctrl_rst_img_n  = ctrl_reset_img_sync;
    wire ctrl_rst_aud_n  = ctrl_reset_aud_sync;
    wire ctrl_rst_play_n = ctrl_reset_play_sync;
    wire sd_reader_soft_reset;
    wire ctrl_rst_boot_n = ctrl_rst_img_n && !sd_reader_soft_reset;
    wire mem_rst_n  = mem_reset_sync;
    wire mem_rst_phy_n    = mem_reset_phy_sync;
    wire mem_rst_bridge_n = mem_reset_bridge_sync;
    wire pxl_rst_n  = pxl_reset_sync;
    wire media_rst_n = pxl_rst_n;
    wire bridge_line_ready_pulse;
    wire [11:0] bridge_line_ready_y;
    wire adapter_underflow_event;
    wire [7:0]  perf_fps_pxl;
    wire [7:0]  perf_swap_count_pxl;
    wire [7:0]  perf_underflow_count_pxl;
    wire [7:0]  perf_underrun_count_pxl;
    reg        perf_frame_toggle_pxl;
    reg        perf_underflow_toggle_pxl;
    reg        perf_frame_underflow_seen_pxl;

    // E01/E02/E03 run directly on the 50 MHz oscillator. All cycle counters
    // below use the native rates expected by the original control modules.
    wire [7:0] brightness_level_key;
    wire [2:0] speed_level_key;
    wire [2:0]  playback_state_ctrl;
    wire [4:0]  active_index_ctrl;
    wire        playing_ctrl;
    wire        paused_ctrl;
    wire        busy_ctrl;
    wire        error_ctrl;
    wire [7:0]  error_code_ctrl;
    wire        hold_frame_ctrl;
    wire        transition_reverse_ctrl;
    wire        transition_start_ctrl;
    wire        req_valid_ctrl;
    wire [1:0]  req_type_ctrl;
    wire [4:0]  req_index_ctrl;
    wire        req_ready_ctrl;
    wire        req_done_ctrl;
    wire        req_error_ctrl;
    wire [7:0]  req_error_code_ctrl;
    wire        media_ready_ctrl;
    wire [4:0]  media_count_ctrl;
    wire        media_boot_error_ctrl;
    wire [7:0]  media_boot_error_code_ctrl;
    wire [15:0] key_pulse_debug_ctrl;
    wire [15:0] remote_key_pulse_ctrl;
    wire [3:0] request_debug_ctrl;
    wire [2:0] curtain_debug_pxl;
    reg [2:0] curtain_debug_meta_ctrl,curtain_debug_sync_ctrl;
    reg [7:0] transaction_events_ctrl;
    reg [31:0] fault_snapshot_ctrl;
    reg [31:0] previous_snapshot_ctrl;
    reg fault_snapshot_taken_ctrl;
    reg error_seen_debug_ctrl;
    wire [31:0] live_snapshot_ctrl;
    wire [31:0] audio_snapshot_ctrl;
    wire [2:0] audio_diagnostic_ctrl;
    reg [2:0] audio_diagnostic_meta_pxl,audio_diagnostic_pxl;
    wire diagnostic_tone_ctrl = audio_diagnostic_ctrl[0];
    reg [5:0] diagnostic_tone_phase_ctrl;
    wire [15:0] diagnostic_tone_pcm_ctrl = diagnostic_tone_phase_ctrl < 24 ? 16'h1800 : 16'he800;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if(!media_rst_n)begin audio_diagnostic_meta_pxl<=0;audio_diagnostic_pxl<=0;end
        else begin audio_diagnostic_meta_pxl<=audio_diagnostic_ctrl;audio_diagnostic_pxl<=audio_diagnostic_meta_pxl;end
    end
    reg [31:0] last_load_cycles_ctrl;
    reg [31:0] load_cycles_ctrl;
    reg measuring_load_ctrl;

    wire host_bitmap_ready, host_bitmap_done, host_bitmap_write, host_bitmap_scroll_done;
    wire [11:0] host_bitmap_address;
    wire [15:0] host_bitmap_data;
    wire [11:0] host_bitmap_width;
    wire host_bitmap_commit;
    wire text_ready_ctrl, text_done_ctrl, text_begin_ctrl, text_write_ctrl, text_commit_ctrl;
    wire text_restore_ctrl, text_cancel_ctrl, text_urgent_ctrl, text_upload_ctrl;
    wire [5:0] text_address_ctrl;
    wire [15:0] text_code_ctrl;
    wire [6:0] text_length_ctrl;
    wire [7:0] text_seconds_ctrl, text_result_ctrl;
    wire interrupt_active_ctrl;
    wire [31:0] subtitle_snapshot_ctrl;
    wire [31:0] text_diagnostic_ctrl;
    assign subtitle_snapshot_ctrl={text_diagnostic_ctrl[31:2],clock_locks_sync_ctrl};
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if(!ctrl_rst_ctl_n)begin clock_locks_meta_ctrl<=0;clock_locks_sync_ctrl<=0;end
        else begin clock_locks_meta_ctrl<=video_clock_locks;clock_locks_sync_ctrl<=clock_locks_meta_ctrl;end
    end
    wire recover_image_ctrl, recovery_load_ctrl;
    wire [4:0] recovery_index_ctrl;
    wire [31:0] recovery_snapshot_ctrl, recovery_first_ctrl;
    wire [15:0] audio_grants_ctrl, image_grants_ctrl;
    reg failed_was_load_ctrl;
    reg [4:0] failed_index_ctrl;
    reg permanent_image_error_ctrl;
    wire [31:0] scheduler_snapshot_ctrl = {audio_grants_ctrl,image_grants_ctrl};
    wire host_subtitle_enabled, host_subtitle_alpha;
    wire [15:0] host_subtitle_rgb;
    reg host_subtitle_meta_ctrl, host_subtitle_sync_ctrl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin host_subtitle_meta_ctrl <= 0; host_subtitle_sync_ctrl <= 0; end
        else begin host_subtitle_meta_ctrl <= host_subtitle_enabled; host_subtitle_sync_ctrl <= host_subtitle_meta_ctrl; end
    end

    wire [4:0] volume_level_ctrl;
    wire audio_output_enable_ctrl;
    wire bridge_pixel_error;
    wire program_enabled_ctrl, program_priming_ctrl, program_paused_ctrl;
    wire program_stalled_ctrl, program_ended_ctrl, program_load_ctrl;
    wire program_swap_allowed_ctrl, program_audio_restart_ctrl;
    wire program_highlight_ctrl, index_commit_ctrl;
    wire [4:0] program_load_index_ctrl;
    wire [1:0] program_scene_ctrl;
    wire [2:0] program_caption_ctrl;
    wire [6:0] program_seconds_ctrl;
    wire req_ready_raw_ctrl;
    wire program_hold_swap_ctrl = program_enabled_ctrl &&
        !program_swap_allowed_ctrl && req_valid_ctrl && (req_type_ctrl == 2'd2);
    assign req_ready_ctrl = req_ready_raw_ctrl && !program_hold_swap_ctrl;

    wire [31:0] prompt_snapshot_ctrl;
    wire [31:0] audio_health_snapshot_ctrl;
    reg [31:0] memory_health_meta_ctrl,memory_health_sync_ctrl;
    reg [31:0] memory_crc_meta_ctrl,memory_crc_sync_ctrl;
    reg [31:0] memory_pass_meta_ctrl,memory_pass_sync_ctrl;
    wire audio_pair_mode_ctrl;
    host_control_bridge u_host_control (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_ctl_n), .serial_rx(UART_RX), .serial_tx(UART_TX),
        .active_index(active_index_ctrl), .media_count(media_count_ctrl),
        .playback_state(playback_state_ctrl), .volume_level(volume_level_ctrl),
        .brightness(brightness_level_key), .speed_level(speed_level_key),
        .error_code(error_ctrl ? error_code_ctrl : 8'd0),
        .status_flags({1'b0,interrupt_active_ctrl,host_subtitle_sync_ctrl,program_enabled_ctrl,error_ctrl,busy_ctrl,paused_ctrl,playing_ctrl}),
        .fault_snapshot(fault_snapshot_ctrl), .live_snapshot(live_snapshot_ctrl),
        .audio_snapshot(audio_snapshot_ctrl), .load_snapshot(last_load_cycles_ctrl),
        .audio_diagnostic_mode(audio_diagnostic_ctrl), .key_pulse(remote_key_pulse_ctrl),
        .text_ready(text_ready_ctrl), .text_done(text_done_ctrl), .text_result(text_result_ctrl),
        .recovery_snapshot(recovery_snapshot_ctrl), .scheduler_snapshot(scheduler_snapshot_ctrl), .subtitle_snapshot(subtitle_snapshot_ctrl),
        .prompt_snapshot(prompt_snapshot_ctrl), .audio_health_snapshot(audio_health_snapshot_ctrl),
        .memory_health_snapshot(memory_health_sync_ctrl), .memory_crc_snapshot(memory_crc_sync_ctrl),
        .memory_pass_snapshot(memory_pass_sync_ctrl),
        .audio_pair_mode(audio_pair_mode_ctrl),
        .upload_in_progress(text_upload_ctrl), .text_begin(text_begin_ctrl), .text_urgent(text_urgent_ctrl),
        .text_seconds(text_seconds_ctrl), .text_length(text_length_ctrl), .text_write(text_write_ctrl),
        .text_address(text_address_ctrl), .text_code(text_code_ctrl), .text_commit(text_commit_ctrl),
        .restore_default(text_restore_ctrl), .cancel_urgent(text_cancel_ctrl)
    );

    // Keep the swap policy of an in-flight load even if KEY2 exits the mode.
    reg program_transaction_ctrl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) program_transaction_ctrl <= 1'b0;
        else if (transition_start_ctrl) program_transaction_ctrl <= program_enabled_ctrl;
    end

    media_control_top #(
        .SCAN_DIV(5000),
        .DEBOUNCE_CYCLES(200000),
        .LONG_START_CYCLES(25000000),
        .LONG_REPEAT_CYCLES(5000000),
        .TIMER_CLK_HZ(50000000),
        .TIMER_TICK_HZ(1000),
        // The outer playback timeout must exceed all storage retry attempts.
        // Five ten-second attempts plus retry gaps fit inside sixty seconds.
        .REQUEST_TIMEOUT_CYCLES(32'd3000000000),
        .AUTO_LOAD_FIRST_IMAGE(1)
    ) u_media_control (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_ctl_n),
        .key_col(Key_Col), .key_row(Key_Row),
        .remote_key_pulse(remote_key_pulse_ctrl),
        .media_ready(media_ready_ctrl),
        .media_error(media_boot_error_ctrl),
        .media_error_code(media_boot_error_code_ctrl),
        .media_count(media_count_ctrl),
        .req_valid(req_valid_ctrl), .req_type(req_type_ctrl),
        .req_index(req_index_ctrl), .req_ready(req_ready_ctrl),
        .req_done(req_done_ctrl), .req_error(req_error_ctrl),
        .req_error_code(req_error_code_ctrl),
        .transition_enable(FADE_ENABLE != 0), .recover(recover_image_ctrl),
        .program_enable(program_enabled_ctrl),
        .external_hold(interrupt_active_ctrl), .recovery_load(recovery_load_ctrl && !interrupt_active_ctrl), .recovery_index(recovery_index_ctrl),
        .program_load(program_load_ctrl), .program_load_index(program_load_index_ctrl),
        .program_hold_swap(program_hold_swap_ctrl), .index_commit_debug(index_commit_ctrl),
        .brightness_level(brightness_level_key),
        .speed_level(speed_level_key),
        .playback_state(playback_state_ctrl), .active_index(active_index_ctrl),
        .playing(playing_ctrl), .paused(paused_ctrl),
        .busy(busy_ctrl), .error(error_ctrl), .error_code(error_code_ctrl),
        .hold_frame(hold_frame_ctrl),
        .transition_reverse(transition_reverse_ctrl),
        .transition_start(transition_start_ctrl),
        .next_index(), .period_ms(), .elapsed_ms(),
        .timer_busy(), .wrap_event(),
        .key_pulse_debug(key_pulse_debug_ctrl)
    );

    // K0 toggles the independent performance/diagnostic overlay. K0 remains
    // outside the E01 playback command mapper, so it cannot disturb playback.
    reg diag_mode_ctrl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n)
            diag_mode_ctrl <= 1'b0;
        else if (key_pulse_debug_ctrl[0])
            diag_mode_ctrl <= ~diag_mode_ctrl;
    end
    reg diag_mode_sync1_pxl;
    reg diag_mode_sync2_pxl;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            diag_mode_sync1_pxl <= 1'b0;
            diag_mode_sync2_pxl <= 1'b0;
        end else begin
            diag_mode_sync1_pxl <= diag_mode_ctrl;
            diag_mode_sync2_pxl <= diag_mode_sync1_pxl;
        end
    end

    // Bundle brightness and speed into one payload before toggling the event.
    // This prevents the pixel domain from capturing a partially updated value.
    reg [7:0]  param_prev_brightness_key;
    reg [2:0]  param_prev_speed_key;
    reg [4:0] param_prev_volume_key;
    reg [15:0] param_hold_key;
    reg        param_publish_pending_key;
    reg        param_toggle_key;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            param_prev_brightness_key <= 8'd10;
            param_prev_speed_key      <= 3'd2;
            param_prev_volume_key     <= 5'd8;
            param_hold_key            <= {5'd8, 3'd2, 8'd10};
            param_publish_pending_key <= 1'b0;
            param_toggle_key          <= 1'b0;
        end else begin
            param_prev_brightness_key <= brightness_level_key;
            param_prev_speed_key      <= speed_level_key;
            param_prev_volume_key     <= volume_level_ctrl;
            if ((brightness_level_key != param_prev_brightness_key) ||
                (speed_level_key != param_prev_speed_key) ||
                (volume_level_ctrl != param_prev_volume_key)) begin
                param_hold_key            <= {volume_level_ctrl, speed_level_key, brightness_level_key};
                param_publish_pending_key <= 1'b1;
            end else if (param_publish_pending_key) begin
                param_toggle_key          <= ~param_toggle_key;
                param_publish_pending_key <= 1'b0;
            end
        end
    end

    reg        param_sync1_pxl;
    reg        param_sync2_pxl;
    reg        param_seen_pxl;
    reg [15:0] param_payload_sync1_pxl;
    reg [15:0] param_payload_sync2_pxl;
    reg [7:0]  brightness_level_pxl;
    reg [2:0]  speed_level_pxl;
    reg [4:0]  volume_level_pxl;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            param_sync1_pxl        <= 1'b0;
            param_sync2_pxl        <= 1'b0;
            param_seen_pxl         <= 1'b0;
            param_payload_sync1_pxl <= {5'd8, 3'd2, 8'd10};
            param_payload_sync2_pxl <= {5'd8, 3'd2, 8'd10};
            brightness_level_pxl    <= 8'd10;
            speed_level_pxl         <= 3'd2;
            volume_level_pxl        <= 5'd8;
        end else begin
            param_sync1_pxl         <= param_toggle_key;
            param_sync2_pxl         <= param_sync1_pxl;
            param_payload_sync1_pxl <= param_hold_key;
            param_payload_sync2_pxl <= param_payload_sync1_pxl;
            if (param_sync2_pxl != param_seen_pxl) begin
                param_seen_pxl       <= param_sync2_pxl;
                brightness_level_pxl <= param_payload_sync2_pxl[7:0];
                speed_level_pxl      <= param_payload_sync2_pxl[10:8];
                volume_level_pxl     <= param_payload_sync2_pxl[15:11];
            end
        end
    end

    // Publish the active image index and playback error as one stable bundle.
    // The two-flop toggle handshake prevents the pixel domain from observing a
    // partially updated index/count/error combination.
    wire [19:0] status_bundle_ctrl = {
        active_index_ctrl, media_count_ctrl, media_ready_ctrl,
        error_ctrl, error_code_ctrl
    };
    reg [19:0] status_bundle_prev_ctrl;
    reg [19:0] status_hold_ctrl;
    reg        status_publish_pending_ctrl;
    reg        status_toggle_ctrl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            status_bundle_prev_ctrl     <= 20'd0;
            status_hold_ctrl            <= 20'd0;
            status_publish_pending_ctrl <= 1'b0;
            status_toggle_ctrl          <= 1'b0;
        end else begin
            status_bundle_prev_ctrl <= status_bundle_ctrl;
            if (status_bundle_ctrl != status_bundle_prev_ctrl) begin
                status_hold_ctrl            <= status_bundle_ctrl;
                status_publish_pending_ctrl <= 1'b1;
            end else if (status_publish_pending_ctrl) begin
                status_toggle_ctrl          <= ~status_toggle_ctrl;
                status_publish_pending_ctrl <= 1'b0;
            end
        end
    end

    reg        status_sync1_pxl;
    reg        status_sync2_pxl;
    reg        status_seen_pxl;
    reg [19:0] status_payload_sync1_pxl;
    reg [19:0] status_payload_sync2_pxl;
    reg [19:0] status_payload_pxl;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            status_sync1_pxl         <= 1'b0;
            status_sync2_pxl         <= 1'b0;
            status_seen_pxl          <= 1'b0;
            status_payload_sync1_pxl <= 20'd0;
            status_payload_sync2_pxl <= 20'd0;
            status_payload_pxl       <= 20'd0;
        end else begin
            status_sync1_pxl         <= status_toggle_ctrl;
            status_sync2_pxl         <= status_sync1_pxl;
            status_payload_sync1_pxl <= status_hold_ctrl;
            status_payload_sync2_pxl <= status_payload_sync1_pxl;
            if (status_sync2_pxl != status_seen_pxl) begin
                status_seen_pxl    <= status_sync2_pxl;
                status_payload_pxl <= status_payload_sync2_pxl;
            end
        end
    end

    wire [4:0] active_index_pxl       = status_payload_pxl[19:15];
    wire       media_ready_status_pxl = status_payload_pxl[9];
    wire       playback_error_pxl     = status_payload_pxl[8];
    wire [7:0] playback_error_code_pxl = status_payload_pxl[7:0];

    always @(posedge FPGA_SYS_50M_CLK_P) begin
        if (!pll_reset_count[7])
            pll_reset_count <= pll_reset_count + 1'b1;
    end

    tx_pll inst (
        .refclk(FPGA_SYS_50M_CLK_P),
        .reset(!pll_reset_count[7]),
        .clock_locks(video_clock_locks), .extlock(pll_locked),
        .clk0_out(clk25m),
        .clk1_out(pxlclk_i),
        .clk2_out(pxlclk_5x_i)
    );

    SDRAM_PLL u_sdram_pll (.reset(!pll_reset_count[7]), .refclk(FPGA_SYS_50M_CLK_P), .clk0_out(sdram_ctrl_clk), .clk1_out(sdram_phy_clk), .clk2_out());

    // ----------------------------------------------------------------------
    // C02/C03/C04/C05/C06 read-only storage chain.
    // All C/D control blocks use the validated pixel clock in this temporary
    // top. SD clock speed is reduced by CLK_DIV parameters.
    // ----------------------------------------------------------------------
    wire sd_init_done;
    wire sd_init_ok;
    wire [7:0] sd_init_error;
    wire [31:0] sd_ocr;
    wire sd_high_capacity;
    wire c02_sd_clk, c02_sd_mosi, c02_sd_cs_n;

    sd_card_init #(
        .CLK_DIV(64),
        .RESPONSE_TIMEOUT_BYTES(64),
        .CMD_RETRIES(2),
        .ACMD41_RETRIES(255),
        .CS_GAP_CYCLES(2),
        .CS_GAP_CLOCKS(8),
        .ACMD41_N1_CLOCKS(4000)
    ) u_sd_init (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_n), .sd_miso(SD_MISO),
        .sd_clk(c02_sd_clk), .sd_mosi(c02_sd_mosi), .sd_cs_n(c02_sd_cs_n),
        .init_busy(), .init_done(sd_init_done), .sd_init_ok(sd_init_ok),
        .init_error(sd_init_error), .ocr_value(sd_ocr),
        .sd_high_capacity(sd_high_capacity)
    );

    wire sector_req_valid;
    wire [31:0] sector_req_lba;
    wire [15:0] sector_req_count;
    wire sector_req_ready;
    wire sector_rsp_valid;
    wire [7:0] sector_rsp_data;
    wire sector_rsp_last;
    wire [7:0] sector_rsp_error;
    wire sector_busy;
    wire c03_sd_clk, c03_sd_mosi, c03_sd_cs_n;

    // Preserve the first low-level C03 failure across BPB/reader retries. The
    // BPB parser intentionally maps every C03 failure to its own ERR_READER,
    // so this latch is required to distinguish R1, token, stop and CRC faults.
    reg [7:0] first_sector_error_q;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n)
            first_sector_error_q <= 8'd0;
        else if ((first_sector_error_q == 8'd0) &&
                 (sector_rsp_error != 8'd0))
            first_sector_error_q <= sector_rsp_error;
    end
    wire [7:0] sector_error_diag_code =
        8'h90 | first_sector_error_q[3:0];

    sd_sector_reader #(
        // 6.25 MHz read clock (50 MHz domain with DIV=4 on both edges).
        // R263 revalidated this rate on the board in the native 50 MHz control
        // domain; keep it while retaining the R264 adaptive display pipeline.
        .CLK_DIV(3),
        .RESPONSE_TIMEOUT_BYTES(65536),
        .DATA_TOKEN_TIMEOUT_BYTES(262143)
    ) u_sector_reader (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_boot_n),
        .sd_init_ok(sd_init_ok), .sd_high_capacity(sd_high_capacity),
        .req_valid(sector_req_valid), .req_lba(sector_req_lba),
        .req_count(sector_req_count), .req_ready(sector_req_ready),
        .rsp_valid(sector_rsp_valid), .rsp_data(sector_rsp_data),
        .rsp_last(sector_rsp_last), .rsp_error(sector_rsp_error),
        .busy(sector_busy), .sd_clk(c03_sd_clk), .sd_mosi(c03_sd_mosi),
        .sd_miso(SD_MISO), .sd_cs_n(c03_sd_cs_n)
    );

    localparam [2:0] OWNER_NONE = 3'd0;
    localparam [2:0] OWNER_BPB = 3'd1;
    localparam [2:0] OWNER_SCAN = 3'd2;
    localparam [2:0] OWNER_CLUSTER = 3'd3;
    localparam [2:0] OWNER_AUDIO = 3'd4;
    reg [2:0] reader_owner;

    wire bpb_start;
    wire bpb_req_valid;
    wire [31:0] bpb_req_lba;
    wire [15:0] bpb_req_count;
    wire bpb_req_ready;
    wire bpb_done;
    wire bpb_valid;
    wire [7:0] bpb_error;
    wire [31:0] bpb_first_data_lba;
    wire [31:0] bpb_root_cluster;
    wire [31:0] bpb_first_fat_lba;
    wire [31:0] bpb_fat_size_sectors;
    wire [7:0] bpb_spc;

    wire scan_start;
    wire scan_req_valid;
    wire [31:0] scan_req_lba;
    wire [15:0] scan_req_count;
    wire scan_req_ready;
    wire scan_done;
    wire scan_valid;
    wire scan_media_valid;
    wire [7:0] scan_error;
    wire [7:0] scan_media_count;
    wire [1:0] scan_media_type;
    wire [31:0] scan_first_cluster;
    wire [31:0] scan_file_size;
    wire [3:0] scan_media_index;
    wire [87:0] scan_media_name;
    wire scan_index_wr_en;
    wire [3:0] scan_index_wr_index;
    wire [87:0] scan_index_wr_name;
    wire [1:0] scan_index_wr_type;
    wire [31:0] scan_index_wr_cluster;
    wire [31:0] scan_index_wr_size;

    fat32_bpb_parser u_bpb (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_boot_n), .start(bpb_start),
        .reader_req_valid(bpb_req_valid), .reader_req_lba(bpb_req_lba),
        .reader_req_count(bpb_req_count), .reader_req_ready(bpb_req_ready),
        .reader_rsp_valid(sector_rsp_valid && reader_owner == OWNER_BPB),
        .reader_rsp_data(sector_rsp_data), .reader_rsp_last(sector_rsp_last),
        .reader_rsp_error(sector_rsp_error), .busy(), .done(bpb_done),
        .fat32_valid(bpb_valid), .error_code(bpb_error),
        .partition_type(), .partition_start_lba(), .bytes_per_sector(),
        .sectors_per_cluster(bpb_spc), .reserved_sector_count(), .fat_count(),
        .fat_size_sectors(bpb_fat_size_sectors), .root_cluster(bpb_root_cluster),
        .total_sectors(), .first_fat_lba(bpb_first_fat_lba),
        .first_data_lba(bpb_first_data_lba), .cluster_count()
    );

    wire boot_terminal_error;
    wire [2:0] boot_attempt_count;
    media_boot_retry #(
        .BPB_TIMEOUT_CYCLES(50000000),
        .READER_RESET_CYCLES(32),
        .RETRY_GAP_CYCLES(500000),
        .MAX_ATTEMPTS(4)
    ) u_boot_retry (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_n),
        .sd_init_done(sd_init_done), .sd_init_ok(sd_init_ok),
        .bpb_done(bpb_done), .bpb_valid(bpb_valid),
        .bpb_start(bpb_start), .reader_reset(sd_reader_soft_reset),
        .terminal_error(boot_terminal_error), .attempt_count(boot_attempt_count)
    );

    fat32_dir_scanner #(.INDEX_WIDTH(4), .MAX_MEDIA_FILES(16)) u_scan (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_n), .start(scan_start),
        .first_data_lba(bpb_first_data_lba), .root_cluster(bpb_root_cluster),
        .sectors_per_cluster(bpb_spc), .reader_req_valid(scan_req_valid),
        .reader_req_lba(scan_req_lba), .reader_req_count(scan_req_count),
        .reader_req_ready(scan_req_ready),
        .reader_rsp_valid(sector_rsp_valid && reader_owner == OWNER_SCAN),
        .reader_rsp_data(sector_rsp_data), .reader_rsp_last(sector_rsp_last),
        .reader_rsp_error(sector_rsp_error), .busy(), .done(scan_done),
        .fat32_dir_valid(scan_valid), .error_code(scan_error),
        .media_valid(scan_media_valid), .media_index(scan_media_index),
        .media_name_83(scan_media_name), .media_type(scan_media_type),
        .media_first_cluster(scan_first_cluster), .media_file_size(scan_file_size),
        .media_count(scan_media_count), .index_wr_en(scan_index_wr_en),
        .index_wr_index(scan_index_wr_index), .index_wr_name_83(scan_index_wr_name),
        .index_wr_type(scan_index_wr_type),
        .index_wr_first_cluster(scan_index_wr_cluster),
        .index_wr_file_size(scan_index_wr_size)
    );

    media_index_ram #(.INDEX_WIDTH(4), .DEPTH(16)) u_index (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_n), .clear(scan_start),
        .wr_en(scan_index_wr_en), .wr_index(scan_index_wr_index),
        .wr_name_83(scan_index_wr_name), .wr_type(scan_index_wr_type),
        .wr_first_cluster(scan_index_wr_cluster), .wr_file_size(scan_index_wr_size),
        .rd_en(1'b0), .rd_index(4'd0), .rd_valid(), .rd_name_83(), .rd_type(),
        .rd_first_cluster(), .rd_file_size(), .item_count()
    );

    // BMP-only metadata table. The source directory scanner also counts WAV
    // files, while E02 indexes images only. Each supported-size BMP receives a
    // compact image index 0..15 used by the playback controller.
    reg [31:0] bmp_cluster_mem [0:15];
    reg [31:0] bmp_size_mem [0:15];
    reg [31:0] wav_cluster_mem [0:15];
    reg [31:0] wav_size_mem [0:15];
    reg [4:0]  bmp_count_q;
    reg [4:0]  wav_count_q;
    reg [4:0]  media_count_q;
    reg        media_ready_q;
    reg        media_boot_error_q;
    reg [7:0]  media_boot_error_code_q;
    reg scan_launched;
    reg scan_done_seen;
    reg scan_start_r;
    reg [1:0] scan_attempt_q;
    reg [15:0] scan_retry_wait_q;
    reg d02_image_done_seen_ctrl;
    reg frame_load_done_seen_ctrl;
    reg frame_swap_ack_seen_ctrl;

    localparam [1:0] MEDIA_BMP = 2'd1;
    localparam [1:0] MEDIA_WAV = 2'd2;
    localparam [1:0] SCAN_MAX_ATTEMPTS = 2'd3;
    localparam [15:0] SCAN_RETRY_GAP = 16'd2048;
    // Accept smaller BMPs too; D01/D02 validate the real dimensions and
    // frame_buffer_manager rejects sources larger than its 640x480 store.
    localparam [31:0] MIN_BMP_FILE_SIZE = 32'd54;
    localparam [31:0] MAX_BMP_FILE_SIZE = 32'd1048576;
    wire bmp_scan_hit = scan_media_valid &&
                        (scan_media_type == MEDIA_BMP) &&
                        (scan_file_size >= MIN_BMP_FILE_SIZE) &&
                        (scan_file_size <= MAX_BMP_FILE_SIZE);
    wire [4:0] bmp_count_next = bmp_count_q + (bmp_scan_hit ? 5'd1 : 5'd0);
    wire wav_scan_hit = scan_media_valid && (scan_media_type == MEDIA_WAV);
    wire [4:0] wav_count_next = wav_count_q + (wav_scan_hit ? 5'd1 : 5'd0);
    always @(posedge ctrl_clk50 or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            bmp_count_q       <= 5'd0;
            wav_count_q       <= 5'd0;
            media_count_q     <= 5'd0;
            media_ready_q     <= 1'b0;
            media_boot_error_q <= 1'b0;
            media_boot_error_code_q <= 8'd0;
            scan_launched     <= 1'b0;
            scan_done_seen    <= 1'b0;
            scan_start_r      <= 1'b0;
            scan_attempt_q    <= 2'd0;
            scan_retry_wait_q <= 16'd0;
        end else begin
            scan_start_r <= 1'b0;
            if (bpb_done && bpb_valid && !scan_launched) begin
                scan_start_r  <= 1'b1;
                scan_launched  <= 1'b1;
                scan_attempt_q <= 2'd1;
            end
            if (scan_retry_wait_q != 16'd0) begin
                scan_retry_wait_q <= scan_retry_wait_q - 1'b1;
                if (scan_retry_wait_q == 16'd1)
                    scan_start_r <= 1'b1;
            end
            if (scan_start_r) begin
                bmp_count_q  <= 5'd0;
                wav_count_q  <= 5'd0;
                media_ready_q <= 1'b0;
            end
            if (bmp_scan_hit) begin
                bmp_cluster_mem[bmp_count_q[3:0]] <= scan_first_cluster;
                bmp_size_mem[bmp_count_q[3:0]]    <= scan_file_size;
                bmp_count_q <= bmp_count_next;
            end
            if (wav_scan_hit) begin
                wav_cluster_mem[wav_count_q[3:0]] <= scan_first_cluster;
                wav_size_mem[wav_count_q[3:0]]    <= scan_file_size;
                wav_count_q <= wav_count_next;
            end
            if (sd_init_done && !sd_init_ok && !media_boot_error_q) begin
                media_boot_error_q      <= 1'b1;
                media_boot_error_code_q <= (sd_init_error != 8'd0) ?
                                           sd_init_error : 8'hE1;
            end else if (boot_terminal_error && !media_boot_error_q) begin
                media_boot_error_q      <= 1'b1;
                media_boot_error_code_q <= (bpb_error != 8'd0) ?
                                           bpb_error : 8'hE3;
            end else if (scan_done && !scan_valid && !media_boot_error_q) begin
                if (scan_attempt_q < SCAN_MAX_ATTEMPTS) begin
                    scan_attempt_q    <= scan_attempt_q + 1'b1;
                    scan_retry_wait_q <= SCAN_RETRY_GAP;
                end else begin
                    media_boot_error_q      <= 1'b1;
                    media_boot_error_code_q <= (scan_error != 8'd0) ?
                                               scan_error : 8'hE4;
                end
            end else if (scan_done && scan_valid &&
                         (bmp_count_next == 5'd0) && !media_boot_error_q) begin
                media_boot_error_q      <= 1'b1;
                media_boot_error_code_q <= 8'hE6;
            end
            if (scan_done) begin
                if (scan_valid) begin
                    scan_done_seen <= 1'b1;
                    media_count_q <= bmp_count_next;
                    media_ready_q <= (bmp_count_next != 5'd0);
                end
            end
        end
    end
    assign scan_start = scan_start_r;
    assign media_ready_ctrl = media_ready_q;
    assign media_count_ctrl = media_count_q;
    assign media_boot_error_ctrl = media_boot_error_q;
    assign media_boot_error_code_ctrl = media_boot_error_code_q;

    wire       load_start_ctrl;
    wire [4:0] load_index_ctrl;
    wire       swap_request_ctrl;
    wire       bmp_start_r = load_start_ctrl;
    wire [31:0] selected_bmp_cluster = bmp_cluster_mem[load_index_ctrl[3:0]];
    wire [31:0] selected_bmp_size    = bmp_size_mem[load_index_ctrl[3:0]];

    wire cluster_req_valid;
    wire [31:0] cluster_req_lba;
    wire [15:0] cluster_req_count;
    localparam integer STREAM_FIFO_DEPTH = 1024;
    localparam integer STREAM_FIFO_ADDR_WIDTH = 10;
    wire [8:0] stream_head_word;
    reg [STREAM_FIFO_ADDR_WIDTH-1:0] stream_fifo_wr_ptr;
    reg [STREAM_FIFO_ADDR_WIDTH-1:0] stream_fifo_rd_ptr;
    reg [STREAM_FIFO_ADDR_WIDTH:0] stream_fifo_count;
    reg stream_fifo_overflow;
    wire cluster_req_ready;
    // A C06 data request returns a complete 512-byte sector. Only launch it
    // when the stream FIFO can absorb one complete sector plus the delayed
    // final byte from the previous sector.
    wire cluster_req_is_data = (cluster_req_lba >= bpb_first_data_lba);
    wire cluster_data_req_allow = !cluster_req_is_data ||
                                      (stream_fifo_count < (STREAM_FIFO_DEPTH - 512));
    wire cluster_rsp_valid = sector_rsp_valid && reader_owner == OWNER_CLUSTER;
    wire [7:0] cluster_error;
    wire [7:0] cluster_error_detail;
    wire cluster_byte_valid;
    wire [7:0] cluster_byte_data;
    wire cluster_byte_last;

    fat32_cluster_reader #(
        .FAT_RESPONSE_TIMEOUT_CYCLES(1048576),
        .WAIT_TIMEOUT_CYCLES(32'h3FFF_FFFF)
    ) u_cluster (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_img_n), .start(bmp_start_r), .request_pause(1'b0),
        .file_first_cluster(selected_bmp_cluster),
        .file_size_bytes(selected_bmp_size),
        .first_data_lba(bpb_first_data_lba), .sectors_per_cluster(bpb_spc),
        .first_fat_lba(bpb_first_fat_lba), .fat_size_sectors(bpb_fat_size_sectors),
        .reader_req_valid(cluster_req_valid), .reader_req_lba(cluster_req_lba),
        .reader_req_count(cluster_req_count), .reader_req_ready(cluster_req_ready),
        .reader_rsp_valid(cluster_rsp_valid), .reader_rsp_data(sector_rsp_data),
        .reader_rsp_last(sector_rsp_last), .reader_rsp_error(sector_rsp_error),
        .busy(), .done(), .error_code(cluster_error),
        .error_detail(cluster_error_detail),
        .byte_valid(cluster_byte_valid), .byte_data(cluster_byte_data),
        .byte_last(cluster_byte_last)
    );

    // ----------------------------------------------------------------------
    // G01 audio path: indexed WAV metadata, F04, and a sector-sized skid FIFO.
    // F04 runs in the verified 50 MHz control domain. The skid FIFO absorbs
    // the current 512-byte C03 sector while F04 pauses its consumer.
    // ----------------------------------------------------------------------
    wire audio_media_ready = scan_done_seen && scan_valid;
    // The playback FSM boots in READY (paused) and only enters PLAY after K10.
    // Audio must not start the SD reader while paused: the reader would hold
    // its request for the whole pause and eventually report a B5 timeout.
    reg normal_audio_running_ctrl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_play_n) begin
        if(!ctrl_rst_play_n) normal_audio_running_ctrl<=0;
        else if(playing_ctrl) normal_audio_running_ctrl<=1;
        else if((playback_state_ctrl==3'd2 || playback_state_ctrl==3'd4) && !recover_image_ctrl)
            normal_audio_running_ctrl<=0;
    end
    wire manual_audio_play_gate = normal_audio_running_ctrl;
    // Program pauses retain the WAV reader/skid/FIFO. Only sample consumption
    // pauses; disabling the transport here would restart the narration.
    wire audio_play_gate = program_enabled_ctrl ?
        (!program_priming_ctrl && !error_ctrl) : manual_audio_play_gate;
    wire [4:0] audio_media_count = wav_count_q;
    wire       audio_open_valid;
    wire [4:0] audio_open_index;
    wire       audio_open_ready;
    wire       audio_reader_hold;
    wire       audio_active;
    wire       audio_error;
    wire [7:0] audio_error_code;
    wire       audio_underrun;
    wire       audio_track_done;
    wire       audio_missing;
    wire [4:0] audio_index;
    wire [11:0] audio_fill_level;
    wire [15:0] pcm_sample_ctrl;
    wire        pcm_valid_ctrl;

    reg        audio_reader_start_q;
    reg [1:0]  audio_reader_reset_hold;
    reg [4:0]  audio_reader_index_q;
    reg [31:0] audio_reader_cluster_q;
    reg [31:0] audio_reader_size_q;
    wire       audio_reader_busy;
    wire       audio_reader_done;
    wire [7:0] audio_reader_error_raw;
    wire       audio_reader_byte_valid;
    wire [7:0] audio_reader_byte_data;
    wire       audio_reader_byte_last;
    wire       audio_req_valid;
    wire [31:0] audio_req_lba;
    wire [15:0] audio_req_count;
    wire       audio_req_ready;
    wire       audio_rsp_valid;
    wire       mux_choose_audio;

    // One 512-byte C03 sector must fit even when F04 is paused, so 512 bytes
    // is the smallest safe skid. Halving it also relieves LUT congestion.
    localparam integer AUDIO_SKID_DEPTH = 1024;
    localparam integer AUDIO_SKID_ADDR_WIDTH = 10;
    wire [8:0] audio_head_word;
    reg [AUDIO_SKID_ADDR_WIDTH-1:0] audio_skid_wr_ptr;
    reg [AUDIO_SKID_ADDR_WIDTH-1:0] audio_skid_rd_ptr;
    reg [AUDIO_SKID_ADDR_WIDTH:0] audio_skid_count;
    reg audio_skid_overflow;

    wire audio_reader_reset_q = (audio_reader_reset_hold != 1'b0);
    wire audio_skid_empty = (audio_skid_count == 0);
    wire audio_skid_full = (audio_skid_count == AUDIO_SKID_DEPTH);
    wire audio_skid_head_last = audio_head_word[8];
    wire audio_skid_pop = !audio_reader_hold && !audio_skid_empty;
    wire audio_skid_clear = audio_reader_reset_q || !audio_play_gate ||
                            (audio_open_valid && audio_open_ready);
    wire audio_skid_write = audio_reader_byte_valid &&
                            !audio_skid_full && !audio_skid_clear;
    wire audio_f4_byte_valid = audio_skid_pop;
    wire audio_f4_byte_last = audio_skid_head_last;
    wire audio_f4_reader_done;
    audio_stream_completion u_audio_completion (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_aud_n), .clear(audio_skid_clear),
        .last_consumed(audio_skid_pop && audio_skid_head_last),
        .reader_done(audio_reader_done), .completed(audio_f4_reader_done)
    );
    wire [9:0] audio_next_read_address = audio_skid_rd_ptr + audio_skid_pop;
    sector_lookahead_ram u_audio_sector_ram (
        .clk(ctrl_clk50),.rst_n(ctrl_rst_aud_n),.clear(audio_skid_clear),
        .write_valid(audio_skid_write),.write_address(audio_skid_wr_ptr),
        .write_data({audio_reader_byte_last,audio_reader_byte_data}),
        .next_read_address(audio_next_read_address),.head_data(audio_head_word)
    );
    wire [7:0] audio_f4_reader_error = audio_skid_overflow ?
                                       8'h09 : audio_reader_error_raw;

    assign audio_open_ready = audio_media_ready && audio_play_gate &&
                              (audio_open_index < audio_media_count) &&
                              !audio_reader_busy &&
                              audio_skid_empty &&
                              !audio_reader_reset_q;
    assign audio_rsp_valid = sector_rsp_valid && (reader_owner == OWNER_AUDIO);
    assign audio_req_ready = sector_req_ready && mux_choose_audio;

    // A new open request while the previous stream is active restarts only the
    // audio C06 client. The shared C03 transaction is allowed to finish; its
    // late response has no owner and is ignored.
    always @(posedge ctrl_clk50 or negedge ctrl_rst_aud_n) begin
        if (!ctrl_rst_aud_n) begin
            audio_reader_start_q    <= 1'b0;
            audio_reader_reset_hold <= 1'b0;
            audio_reader_index_q    <= 5'd0;
            audio_reader_cluster_q  <= 32'd0;
            audio_reader_size_q     <= 32'd0;
        end else begin
            audio_reader_start_q <= 1'b0;
            if (audio_open_valid && audio_open_ready) begin
                audio_reader_start_q   <= 1'b1;
                audio_reader_index_q   <= audio_open_index;
                audio_reader_cluster_q <= wav_cluster_mem[audio_open_index[3:0]];
                audio_reader_size_q    <= wav_size_mem[audio_open_index[3:0]];
                audio_reader_reset_hold <= 1'b0;
            end else if (audio_open_valid && !audio_open_ready &&
                         !audio_reader_reset_q) begin
                audio_reader_reset_hold <= 2'd2;
            end else if (audio_reader_reset_hold != 1'b0) begin
                audio_reader_reset_hold <= audio_reader_reset_hold - 1'b1;
            end
        end
    end

    always @(posedge ctrl_clk50 or negedge ctrl_rst_aud_n) begin
        if (!ctrl_rst_aud_n || audio_skid_clear) begin
            audio_skid_wr_ptr      <= {AUDIO_SKID_ADDR_WIDTH{1'b0}};
            audio_skid_rd_ptr      <= {AUDIO_SKID_ADDR_WIDTH{1'b0}};
            audio_skid_count       <= {(AUDIO_SKID_ADDR_WIDTH+1){1'b0}};
            audio_skid_overflow    <= 1'b0;
        end else begin
            if (audio_skid_write) begin
                audio_skid_wr_ptr <= audio_skid_wr_ptr + 1'b1;
            end else if (audio_reader_byte_valid && audio_skid_full) begin
                audio_skid_overflow <= 1'b1;
            end
            if (audio_skid_pop)
                audio_skid_rd_ptr <= audio_skid_rd_ptr + 1'b1;
            case ({audio_skid_write, audio_skid_pop})
                2'b10: audio_skid_count <= audio_skid_count + 1'b1;
                2'b01: audio_skid_count <= audio_skid_count - 1'b1;
                default: audio_skid_count <= audio_skid_count;
            endcase
            end
    end

    fat32_cluster_reader #(
        // 4096 cycles (82 us at 50 MHz) is shorter than one 512-byte SPI
        // sector (~655 us at 6.25 MHz). The audio FAT lookup often waits for
        // an image sector, so give it a full-sector-plus-arbitration window.
        .FAT_RESPONSE_TIMEOUT_CYCLES(1048576),
        .WAIT_TIMEOUT_CYCLES(32'h3FFF_FFFF)
    ) u_audio_cluster (
        .clk_50m(ctrl_clk50),
        .rst_n(ctrl_rst_aud_n && !audio_reader_reset_q && audio_play_gate),
        .start(audio_reader_start_q), .request_pause(audio_reader_hold),
        .file_first_cluster(audio_reader_cluster_q),
        .file_size_bytes(audio_reader_size_q),
        .first_data_lba(bpb_first_data_lba), .sectors_per_cluster(bpb_spc),
        .first_fat_lba(bpb_first_fat_lba), .fat_size_sectors(bpb_fat_size_sectors),
        .reader_req_valid(audio_req_valid),
        .reader_req_lba(audio_req_lba),
        .reader_req_count(audio_req_count),
        .reader_req_ready(audio_req_ready),
        .reader_rsp_valid(audio_rsp_valid),
        .reader_rsp_data(sector_rsp_data),
        .reader_rsp_last(sector_rsp_last),
        .reader_rsp_error(sector_rsp_error),
        .busy(audio_reader_busy), .done(audio_reader_done),
        .error_code(audio_reader_error_raw),
        .byte_valid(audio_reader_byte_valid),
        .byte_data(audio_reader_byte_data),
        .byte_last(audio_reader_byte_last)
    );

    // The media pipeline (SD reader, BMP decoder and audio byte stream) shares
    // the raw 50 MHz control domain, so the audio controller uses its native
    // 48 kHz timing without a divided-clock correction.
    // Ordinary playback supports either one continuous soundtrack or one WAV
    // per committed image. Program mode keeps its authored WAV 0 timeline.
    wire [4:0] selected_audio_wav_index;
    wire       audio_pair_present;
    image_audio_pair_selector u_audio_pair (
        .pair_mode(audio_pair_mode_ctrl),
        .image_index(active_index_ctrl),
        .image_count(media_count_ctrl),
        .audio_count(audio_media_count),
        .audio_index(selected_audio_wav_index),
        .pair_valid(),
        .audio_present(audio_pair_present),
        .audio_missing()
    );
    wire [4:0] audio_wav_index =
        program_enabled_ctrl ? 5'd0 : selected_audio_wav_index;

    reg [4:0] audio_wav_index_q;
    reg       audio_retry_q;
    reg       audio_play_gate_q;
    reg       audio_pair_mode_q;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_play_n) begin
        if (!ctrl_rst_play_n) begin
            audio_wav_index_q   <= 5'd0;
            audio_retry_q       <= 1'b0;
            audio_play_gate_q   <= 1'b0;
            audio_pair_mode_q   <= 1'b0;
        end else begin
            audio_wav_index_q   <= audio_wav_index;
            audio_retry_q       <= (audio_wav_index != audio_wav_index_q);
            audio_play_gate_q   <= audio_play_gate;
            audio_pair_mode_q   <= audio_pair_mode_ctrl;
        end
    end
    wire audio_resume_retry = audio_play_gate && !audio_play_gate_q &&
                              audio_pair_present;
    wire audio_commit_retry = index_commit_ctrl && audio_pair_mode_ctrl &&
                              !program_enabled_ctrl;
    wire audio_mode_retry = audio_pair_mode_ctrl != audio_pair_mode_q;
    wire audio_loop_retry = !program_enabled_ctrl && !audio_pair_mode_ctrl &&
                            audio_track_done;

    audio_playback_ctrl #(
        .C_CLOCK_HZ(50000000),
        .C_SAMPLE_HZ(48000)
    ) u_audio_playback (
        .i_clk(ctrl_clk50), .i_rstn(ctrl_rst_play_n),
        .i_image_index(audio_wav_index),
        .i_image_playing(program_enabled_ctrl ? !program_priming_ctrl : normal_audio_running_ctrl),
        .i_image_paused(program_enabled_ctrl ?
            (program_paused_ctrl || program_stalled_ctrl || program_ended_ctrl || interrupt_active_ctrl) : (!normal_audio_running_ctrl || interrupt_active_ctrl)),
        .i_transition_active(1'b0),
        .i_retry(program_enabled_ctrl ? program_audio_restart_ctrl :
                 (audio_commit_retry || audio_mode_retry ||
                  audio_loop_retry || audio_resume_retry)),
        .i_audio_ready(audio_media_ready),
        .i_audio_count(audio_media_count),
        .i_reader_byte_valid(audio_f4_byte_valid),
        .i_reader_byte_data(audio_head_word[7:0]),
        .i_reader_byte_last(audio_f4_byte_last),
        .i_reader_done(audio_f4_reader_done),
        .i_reader_error(audio_f4_reader_error),
        .i_audio_open_ready(audio_open_ready),
        .o_audio_open_valid(audio_open_valid),
        .o_audio_open_index(audio_open_index),
        .o_reader_hold(audio_reader_hold),
        .o_audio_pwm(),
        .o_pwm_enable(audio_output_enable_ctrl),
        .o_sample_tick_enable(),
        .o_duty_debug(),
        .o_audio_active(audio_active),
        .o_audio_error(audio_error),
        .o_audio_error_code(audio_error_code),
        .o_audio_underrun(audio_underrun),
        .o_audio_track_done(audio_track_done),
        .o_audio_missing(audio_missing),
        .o_audio_index(audio_index),
        .o_fill_level(audio_fill_level),
        .o_pcm_sample(pcm_sample_ctrl),
        .o_pcm_valid(pcm_valid_ctrl)
    );

    program_timeline u_program (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_ctl_n),
        .mode_key(key_pulse_debug_ctrl[2] && !interrupt_active_ctrl), .pause_key(key_pulse_debug_ctrl[10] && !interrupt_active_ctrl),
        .suspend(interrupt_active_ctrl),
        .manual_key((key_pulse_debug_ctrl[9] || key_pulse_debug_ctrl[11]) && !interrupt_active_ctrl),
        .media_ready(media_ready_ctrl), .media_count(media_count_ctrl),
        .audio_count(audio_media_count), .media_busy(busy_ctrl), .media_error(error_ctrl),
        .index_commit(index_commit_ctrl),
        .prefetch_ready(req_valid_ctrl && (req_type_ctrl == 2'd2)),
        .pcm_valid(pcm_valid_ctrl), .pcm_underrun(audio_underrun),
        .track_done(audio_track_done), .audio_error(audio_error),
        .enabled(program_enabled_ctrl), .priming(program_priming_ctrl),
        .paused(program_paused_ctrl), .stalled(program_stalled_ctrl),
        .ended(program_ended_ctrl), .load_valid(program_load_ctrl),
        .load_index(program_load_index_ctrl), .swap_allowed(program_swap_allowed_ctrl),
        .audio_restart(program_audio_restart_ctrl), .scene(program_scene_ctrl),
        .caption(program_caption_ctrl), .highlight(program_highlight_ctrl),
        .seconds(program_seconds_ctrl)
    );

    wire hdmi_pcm_valid_ctrl;
    wire [15:0] hdmi_pcm_ctrl;
    wire volume_pcm_valid_ctrl;
    wire [15:0] volume_pcm_ctrl;
    // Prompts run only in ordinary AUTO/MAN playback; authored PROG narration is untouched.
    reg voice_prompts_enabled_ctrl, voice_running_seen_ctrl;
    wire voice_running_ctrl = normal_audio_running_ctrl && !program_enabled_ctrl &&
        !interrupt_active_ctrl && !error_ctrl;
    wire voice_busy_ctrl;
    wire [15:0] voice_pcm_ctrl;
    wire [7:0] voice_events_ctrl;
    wire [4:0] voice_index_ctrl;
    wire voice_enabled_ctrl = voice_prompts_enabled_ctrl && !program_enabled_ctrl;
    wire voice_audible_ctrl = voice_enabled_ctrl && voice_running_ctrl && voice_busy_ctrl;
    wire voice_trigger_ctrl = !program_enabled_ctrl && media_ready_ctrl &&
        (index_commit_ctrl || (voice_running_ctrl && !voice_running_seen_ctrl && !voice_busy_ctrl));
    always @(posedge ctrl_clk50 or negedge ctrl_rst_play_n) begin
        if (!ctrl_rst_play_n) begin voice_prompts_enabled_ctrl<=1; voice_running_seen_ctrl<=0; end
        else begin
            voice_running_seen_ctrl<=voice_running_ctrl;
            if (key_pulse_debug_ctrl[3]) voice_prompts_enabled_ctrl<=!voice_prompts_enabled_ctrl;
        end
    end
    image_voice_prompt u_image_voice (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_play_n), .sample_tick(hdmi_pcm_valid_ctrl && !(audio_output_enable_ctrl && audio_underrun)),
        .enable(voice_enabled_ctrl), .running(voice_running_ctrl),
        .trigger(voice_trigger_ctrl), .image_index(active_index_ctrl),
        .busy(voice_busy_ctrl), .pcm(voice_pcm_ctrl),
        .event_count(voice_events_ctrl), .spoken_index(voice_index_ctrl)
    );
    wire mixed_pcm_valid_ctrl;
    wire [15:0] mixed_pcm_ctrl;
    wire prompt_overflow_ctrl;
    assign prompt_snapshot_ctrl = {8'h53,voice_events_ctrl,3'd0,voice_index_ctrl,3'd0,prompt_overflow_ctrl,voice_running_ctrl,voice_audible_ctrl,voice_busy_ctrl,voice_prompts_enabled_ctrl};
    // Preserve missing-data validity through the mixer so the existing heartbeat can smooth it.
    wire final_audio_overflow_ctrl;
    reg [7:0] music_starvation_events_ctrl;
    reg music_starved_seen_ctrl;
    wire music_starved_ctrl=audio_output_enable_ctrl && audio_underrun;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_play_n) begin
        if (!ctrl_rst_play_n) begin music_starvation_events_ctrl<=0; music_starved_seen_ctrl<=0; end
        else begin
            music_starved_seen_ctrl<=music_starved_ctrl;
            if (music_starved_ctrl && !music_starved_seen_ctrl && music_starvation_events_ctrl!=255)
                music_starvation_events_ctrl<=music_starvation_events_ctrl+1'b1;
        end
    end
    assign audio_health_snapshot_ctrl={8'ha2,music_starvation_events_ctrl,audio_fill_level[7:0],
        1'b0,voice_prompts_enabled_ctrl,audio_underrun,audio_output_enable_ctrl,
        1'b0,prompt_overflow_ctrl,final_audio_overflow_ctrl,audio_error};
    audio_prompt_mixer u_prompt_mixer (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_play_n), .sample_tick(hdmi_pcm_valid_ctrl),
        .music_enable(audio_output_enable_ctrl), .music_valid(pcm_valid_ctrl && !audio_underrun), .music_pcm(pcm_sample_ctrl),
        .voice_enable(voice_audible_ctrl), .voice_busy(voice_busy_ctrl), .voice_pcm(voice_pcm_ctrl),
        .output_valid(mixed_pcm_valid_ctrl), .output_pcm(mixed_pcm_ctrl), .overflow(prompt_overflow_ctrl)
    );
    audio_volume_control u_audio_volume (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_play_n),
        .key_up(key_pulse_debug_ctrl[5]), .key_down(key_pulse_debug_ctrl[4]),
        .enable(audio_output_enable_ctrl || voice_audible_ctrl || diagnostic_tone_ctrl),
        .sample_valid(diagnostic_tone_ctrl ? hdmi_pcm_valid_ctrl : mixed_pcm_valid_ctrl), .sample_pcm(diagnostic_tone_ctrl ? diagnostic_tone_pcm_ctrl : mixed_pcm_ctrl),
        .volume_level(volume_level_ctrl),
        .output_valid(volume_pcm_valid_ctrl), .output_pcm(volume_pcm_ctrl)
    );
    audio_pwm u_volume_pwm (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_play_n),
        .sample_valid(hdmi_pcm_valid_ctrl), .sample_pcm(hdmi_pcm_ctrl),
        .underrun(1'b0), .pwm_enable(1'b1),
        .audio_pwm(Audio_PWM), .duty_debug()
    );

    wire hdmi_pcm_strobe_pxl;
    wire [15:0] hdmi_pcm_pxl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_play_n) begin
        if(!ctrl_rst_play_n)diagnostic_tone_phase_ctrl<=0;
        else if(hdmi_pcm_valid_ctrl)diagnostic_tone_phase_ctrl<=diagnostic_tone_phase_ctrl==47 ? 0 : diagnostic_tone_phase_ctrl+1'b1;
    end
    audio_output_heartbeat u_audio_heartbeat (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_play_n), .enable(audio_output_enable_ctrl || voice_audible_ctrl || diagnostic_tone_ctrl),
        .sample_valid(volume_pcm_valid_ctrl), .sample_pcm(volume_pcm_ctrl),
        .output_valid(hdmi_pcm_valid_ctrl), .output_pcm(hdmi_pcm_ctrl), .overflow(final_audio_overflow_ctrl)
    );
    hdmi_audio_sample_cdc u_hdmi_audio_cdc (
        .clk_ctrl(ctrl_clk50), .rst_ctrl_n(ctrl_rst_play_n),
        .sample_valid_ctrl(hdmi_pcm_valid_ctrl), .sample_ctrl(hdmi_pcm_ctrl),
        .clk_pixel(pxlclk_i), .rst_pixel_n(media_rst_n),
        .sample_strobe_pixel(hdmi_pcm_strobe_pxl), .sample_pixel(hdmi_pcm_pxl)
    );

    // Shared smoothed post-volume PCM makes both audio outputs and visuals agree.
    // The bank remains in the verified 50 MHz audio domain.
    wire [63:0] spectrum_levels_ctrl;
    wire [95:0] spectrum_bar_tops_ctrl;
    reg spectrum_toggle_ctrl;
    reg [15:0] spectrum_publish_count_ctrl;
    reg [95:0] spectrum_bar_tops_hold_ctrl;
    spectrum_8band u_audio_spectrum (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_play_n),
        // At mute, use the established idle-release path to discard integer
        // filter residue and let all bars settle completely to zero.
        .sample_valid(hdmi_pcm_valid_ctrl && (volume_level_ctrl != 5'd0) &&
            (audio_output_enable_ctrl || voice_audible_ctrl || diagnostic_tone_ctrl || (hdmi_pcm_ctrl != 0))),
        .sample_pcm(hdmi_pcm_ctrl),
        .levels(spectrum_levels_ctrl),
        .bar_tops(spectrum_bar_tops_ctrl)
    );
    always @(posedge ctrl_clk50 or negedge ctrl_rst_play_n) begin
        if (!ctrl_rst_play_n) begin
            spectrum_toggle_ctrl <= 1'b0;
            spectrum_publish_count_ctrl <= 16'd0;
            spectrum_bar_tops_hold_ctrl <= {8{12'd1008}};
        end else if (spectrum_publish_count_ctrl == 16'd49999) begin
            // Publish a held snapshot every millisecond, including silence.
            spectrum_publish_count_ctrl <= 16'd0;
            spectrum_bar_tops_hold_ctrl <= spectrum_bar_tops_ctrl;
            spectrum_toggle_ctrl <= ~spectrum_toggle_ctrl;
        end else begin
            spectrum_publish_count_ctrl <= spectrum_publish_count_ctrl + 1'b1;
        end
    end

    // Slow audio status crosses into the pixel domain through two flops.
    wire audio_ok_ctrl = audio_active && !audio_error;
    reg  audio_ok_sync1_pxl;
    reg  audio_ok_sync2_pxl;
    reg  audio_error_sync1_pxl;
    reg  audio_error_sync2_pxl;
    reg [7:0] audio_error_code_sync1_pxl;
    reg [7:0] audio_error_code_sync2_pxl;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            audio_ok_sync1_pxl          <= 1'b0;
            audio_ok_sync2_pxl          <= 1'b0;
            audio_error_sync1_pxl       <= 1'b0;
            audio_error_sync2_pxl       <= 1'b0;
            audio_error_code_sync1_pxl  <= 8'd0;
            audio_error_code_sync2_pxl  <= 8'd0;
        end else begin
            audio_ok_sync1_pxl         <= audio_ok_ctrl;
            audio_ok_sync2_pxl         <= audio_ok_sync1_pxl;
            audio_error_sync1_pxl      <= audio_error;
            audio_error_sync2_pxl      <= audio_error_sync1_pxl;
            audio_error_code_sync1_pxl <= audio_error_code;
            audio_error_code_sync2_pxl <= audio_error_code_sync1_pxl;
        end
    end

    // Only one filesystem client is active at a time: BPB, directory scan, or
    // image/audio cluster streams. This keeps the C03 reader single-transaction.
    wire owner_free = (reader_owner == OWNER_NONE);
    wire audio_req_is_data = (audio_req_lba >= bpb_first_data_lba);
    wire audio_req_allow = (!audio_reader_hold || !audio_req_is_data) &&
                           !audio_reader_reset_q &&
                           (!audio_req_is_data ||
                            (audio_skid_count < (AUDIO_SKID_DEPTH - 512)));
    wire mux_req_valid = owner_free && (bpb_req_valid || scan_req_valid ||
                              (cluster_req_valid && cluster_data_req_allow) ||
                              (audio_req_valid && audio_req_allow));
    wire mux_choose_bpb = owner_free && bpb_req_valid;
    wire mux_choose_scan = owner_free && !bpb_req_valid && scan_req_valid;
    wire scheduler_urgent_ctrl;
    wire mux_choose_cluster;
    audio_sector_scheduler u_audio_scheduler (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_ctl_n), .owner_free(owner_free),
        .request_accepted(sector_req_valid && sector_req_ready),
        .boot_request(bpb_req_valid), .scan_request(scan_req_valid),
        .image_request(cluster_req_valid && cluster_data_req_allow),
        .audio_request(audio_req_valid && audio_req_allow), .audio_metadata(!audio_req_is_data),
        .audio_active(audio_play_gate && !audio_error && !interrupt_active_ctrl),
        .audio_fill(audio_fill_level), .choose_image(mux_choose_cluster), .choose_audio(mux_choose_audio),
        .urgent(scheduler_urgent_ctrl), .audio_grants(audio_grants_ctrl), .image_grants(image_grants_ctrl)
    );
    assign sector_req_valid = mux_req_valid;
    assign sector_req_lba = mux_choose_bpb ? bpb_req_lba :
                            mux_choose_scan ? scan_req_lba :
                            mux_choose_cluster ? cluster_req_lba : audio_req_lba;
    assign sector_req_count = mux_choose_bpb ? bpb_req_count :
                              mux_choose_scan ? scan_req_count :
                              mux_choose_cluster ? cluster_req_count : audio_req_count;
    assign bpb_req_ready = sector_req_ready && mux_choose_bpb;
    assign scan_req_ready = sector_req_ready && mux_choose_scan;
    assign cluster_req_ready = sector_req_ready && mux_choose_cluster;

    always @(posedge ctrl_clk50 or negedge ctrl_rst_img_n) begin
        if (!ctrl_rst_img_n)
            reader_owner <= OWNER_NONE;
        else if (!ctrl_rst_boot_n)
            reader_owner <= OWNER_NONE;
        else begin
            if (audio_reader_reset_q && (reader_owner == OWNER_AUDIO))
                reader_owner <= OWNER_NONE;
            else if (reader_owner == OWNER_NONE && sector_req_valid && sector_req_ready) begin
                if (mux_choose_bpb) reader_owner <= OWNER_BPB;
                else if (mux_choose_scan) reader_owner <= OWNER_SCAN;
                else if (mux_choose_cluster) reader_owner <= OWNER_CLUSTER;
                else if (mux_choose_audio) reader_owner <= OWNER_AUDIO;
            end else if (reader_owner != OWNER_NONE &&
                         (sector_rsp_last || (sector_rsp_error != 8'd0))) begin
                reader_owner <= OWNER_NONE;
            end
        end
    end

    assign SD_CS   = sd_init_ok ? c03_sd_cs_n : c02_sd_cs_n;
    assign SD_CLK  = sd_init_ok ? c03_sd_clk : c02_sd_clk;
    assign SD_MOSI = sd_init_ok ? c03_sd_mosi : c02_sd_mosi;

    // ----------------------------------------------------------------------
    // D01/D02/D03 file stream and FrameB load.
    // C06 emits a continuous file stream without ready; D01 consumes bytes 0..53,
    // the router skips to pixel_data_offset, then D02 consumes the pixel stream.
    // ----------------------------------------------------------------------

    wire stream_fifo_empty = (stream_fifo_count == 0);
    wire stream_fifo_full  = (stream_fifo_count == STREAM_FIFO_DEPTH);
    wire stream_fifo_push  = cluster_byte_valid && !stream_fifo_full;
    wire [7:0] stream_fifo_head_data = stream_head_word[7:0];
    wire       stream_fifo_head_last = stream_head_word[8];
    wire d01_in_ready;
    wire d02_in_ready;
    wire d01_done;
    wire d01_header_valid;
    wire [7:0] d01_error;
    wire [31:0] d01_pixel_offset;
    wire [11:0] d01_width, d01_height;
    wire d01_top_down;
    wire [31:0] d01_row_stride;
    wire d01_start = bmp_start_r;
    wire d02_start = d01_done;
    wire d01_in_valid = !stream_fifo_empty && !d01_header_valid;
    reg  [31:0] d02_skip_remaining;
    wire d02_skip_active = d01_header_valid && (d02_skip_remaining != 32'd0);
    wire d02_skip_pop = !stream_fifo_empty && d02_skip_active;
    wire d02_in_valid = !stream_fifo_empty && d01_header_valid &&
                        !d01_done && !d02_skip_active;
    wire stream_fifo_pop = (d01_in_valid && d01_in_ready) ||
                           (d02_in_valid && d02_in_ready) ||
                           d02_skip_pop;
    wire d03_ready;
    wire [9:0] stream_next_read_address = stream_fifo_rd_ptr + stream_fifo_pop;
    sector_lookahead_ram u_image_sector_ram (
        .clk(ctrl_clk50),.rst_n(ctrl_rst_img_n),.clear(bmp_start_r),
        .write_valid(stream_fifo_push),.write_address(stream_fifo_wr_ptr),
        .write_data({cluster_byte_last,cluster_byte_data}),
        .next_read_address(stream_next_read_address),.head_data(stream_head_word)
    );
    always @(posedge ctrl_clk50 or negedge ctrl_rst_img_n) begin
        if (!ctrl_rst_img_n || bmp_start_r) begin
            stream_fifo_wr_ptr  <= {STREAM_FIFO_ADDR_WIDTH{1'b0}};
            stream_fifo_rd_ptr  <= {STREAM_FIFO_ADDR_WIDTH{1'b0}};
            stream_fifo_count   <= {(STREAM_FIFO_ADDR_WIDTH+1){1'b0}};
            stream_fifo_overflow<= 1'b0;
            d02_skip_remaining  <= 32'd0;
        end else begin
            if (stream_fifo_push) begin
                stream_fifo_wr_ptr <= stream_fifo_wr_ptr + 1'b1;
            end else if (cluster_byte_valid && stream_fifo_full) begin
                stream_fifo_overflow <= 1'b1;
            end
            if (stream_fifo_pop)
                stream_fifo_rd_ptr <= stream_fifo_rd_ptr + 1'b1;
            if (d02_skip_pop)
                d02_skip_remaining <= d02_skip_remaining - 1'b1;
            else if (d01_done && d01_header_valid)
                d02_skip_remaining <= (d01_pixel_offset > 32'd54) ?
                                      (d01_pixel_offset - 32'd54) : 32'd0;
            case ({stream_fifo_push, stream_fifo_pop})
                2'b10: stream_fifo_count <= stream_fifo_count + 1'b1;
                2'b01: stream_fifo_count <= stream_fifo_count - 1'b1;
                default: stream_fifo_count <= stream_fifo_count;
            endcase
        end
    end
    bmp_header_parser #(.TIMEOUT_CYCLES(32'h3FFF_FFFF)) u_bmp_header (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_img_n), .start(d01_start),
        .in_valid(d01_in_valid), .in_data(stream_fifo_head_data),
        .in_last(stream_fifo_head_last), .in_ready(d01_in_ready),
        .file_size_bytes(selected_bmp_size), .busy(), .done(d01_done),
        .header_valid(d01_header_valid), .error_code(d01_error),
        .bmp_file_size(), .pixel_data_offset(d01_pixel_offset),
        .dib_header_size(), .width_signed(), .height_signed(),
        .image_width(d01_width), .image_height(d01_height), .top_down(d01_top_down),
        .planes(), .bit_count(), .compression(), .size_image(),
        .row_stride(d01_row_stride)
    );

    wire d02_pixel_valid;
    wire [11:0] d02_pixel_x, d02_pixel_y;
    wire [15:0] d02_pixel_rgb565;
    wire d02_line_done, d02_image_done;
    wire [7:0] d02_error;
    bmp24_stream_decoder #(.TIMEOUT_CYCLES(32'h3FFF_FFFF)) u_bmp_decode (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_img_n), .start(d02_start),
        .abort(bmp_start_r),
        .header_valid(d01_header_valid), .image_width(d01_width),
        .image_height(d01_height), .top_down(d01_top_down),
        .row_stride(d01_row_stride), .in_valid(d02_in_valid),
        .in_data(stream_fifo_head_data), .in_last(stream_fifo_head_last),
        .in_ready(d02_in_ready), .busy(), .pixel_valid(d02_pixel_valid),
        .pixel_ready(d03_ready),
        .pixel_x(d02_pixel_x), .pixel_y(d02_pixel_y),
        .pixel_rgb565(d02_pixel_rgb565), .line_done(d02_line_done),
        .image_done(d02_image_done), .error_code(d02_error)
    );

    wire [7:0] d03_r8 = {d02_pixel_rgb565[15:11], d02_pixel_rgb565[15:13]};
    wire [7:0] d03_g8 = {d02_pixel_rgb565[10:5], d02_pixel_rgb565[10:9]};
    wire [7:0] d03_b8 = {d02_pixel_rgb565[4:0], d02_pixel_rgb565[4:2]};
    wire d03_valid;
    wire [15:0] d03_rgb565;
    wire [11:0] d03_x, d03_y;
    wire d03_last;
    wire frame_pixel_ready;
rgb888_to_rgb565 u_rgb565 (
        .clk_50m(ctrl_clk50), .rst_n(ctrl_rst_img_n),
        .in_valid(d02_pixel_valid), .in_ready(d03_ready),
        .in_bgr888({d03_b8, d03_g8, d03_r8}),
        .in_x(d02_pixel_x), .in_y(d02_pixel_y), .in_last(d02_image_done),
        .brightness_enable(1'b0), .brightness_level(8'hFF),
        .out_valid(d03_valid), .out_ready(frame_pixel_ready),
        .out_rgb565(d03_rgb565), .out_x(d03_x), .out_y(d03_y), .out_last(d03_last)
    );
    wire frame_load_start = d02_start;
    wire frame_load_busy;
    wire frame_load_done;
    // Hold-safe copies preserve logic values while giving the reported capture
    // paths enough routing delay for the slow clock-insertion corner.
    wire load_cycles_hold_n_8 /* synthesis keep=true */;
    wire load_cycles_hold_8 /* synthesis keep=true */;
    assign load_cycles_hold_n_8 = ~load_cycles_ctrl[8];
    assign load_cycles_hold_8 = ~load_cycles_hold_n_8;
    wire [31:0] last_load_cycles_capture = {
        load_cycles_ctrl[31:9],
        load_cycles_hold_8,
        load_cycles_ctrl[7:0]
    };
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            last_load_cycles_ctrl <= 0; load_cycles_ctrl <= 0; measuring_load_ctrl <= 0;
        end else if (load_start_ctrl) begin
            load_cycles_ctrl <= 0; measuring_load_ctrl <= 1;
        end else if (measuring_load_ctrl) begin
            load_cycles_ctrl <= load_cycles_ctrl + 1'b1;
            if (frame_load_done || req_error_ctrl) begin
                last_load_cycles_ctrl <= last_load_cycles_capture;
                measuring_load_ctrl <= 0;
            end
        end
    end
    wire frame_load_error;
    wire [7:0] frame_load_error_detail;
    wire frame_load_timeout;
    wire frame_load_conflict;
    wire frame_load_select;
    wire frame_show_select;
    wire [1:0] frame_ready;
    wire frame_swap_request;
    wire fade_done_pulse_ctrl;
    wire frame_boundary_pxl;
    wire frame_boundary_ctrl;
    wire frame_swap_ack;
    wire mem_wr_valid;
    wire mem_wr_ready;
    wire [20:0] mem_wr_addr_word;
    wire [31:0] mem_wr_data;
    wire [3:0] mem_wr_strb;
    wire mem_wr_done;
    wire mem_wr_error;
    wire mem_cdc_valid, mem_cdc_ready, mem_cdc_done, mem_cdc_error;
    wire [20:0] mem_cdc_addr_word;
    wire [31:0] mem_cdc_data;
    wire [3:0] mem_cdc_strb;

    frame_buffer_manager #(
        .FRAME_WIDTH(640), .FRAME_HEIGHT(480),
        .FRAME_A_BASE_WORD(FRAME_A_BASE_WORD),
        .FRAME_B_BASE_WORD(FRAME_B_BASE_WORD),
        .LOAD_TIMEOUT_CYCLES(32'h3FFF_FFFF),
        .INPUT_BOTTOM_UP(1)
    ) u_frame_mgr (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_img_n),
        .pixel_valid(d03_valid), .pixel_ready(frame_pixel_ready),
        .pixel_rgb565(d03_rgb565), .pixel_x(d03_x), .pixel_y(d03_y),
        .pixel_last(d03_last),
        .frame_width_i(d01_width), .frame_height_i(d01_height),
        .load_start(frame_load_start),
        .load_abort(bmp_start_r && frame_load_busy),
        .load_busy(frame_load_busy), .load_done(frame_load_done), .load_error(frame_load_error),
        .load_error_detail(frame_load_error_detail),
        .load_timeout(frame_load_timeout), .load_conflict(frame_load_conflict),
        .load_frame_select(frame_load_select), .show_frame_select(frame_show_select),
        .frame_ready(frame_ready), .swap_request(frame_swap_request),
        .frame_boundary(frame_boundary_ctrl), .swap_ack(frame_swap_ack),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_addr_word(mem_wr_addr_word), .mem_wr_data(mem_wr_data),
        .mem_wr_strb(mem_wr_strb), .mem_wr_done(mem_wr_done),
        .mem_wr_error(mem_wr_error)
    );

    // Latch the geometry of the newly loaded image and publish it only when
    // the frame actually swaps, so the displayed old frame keeps its own
    // scale/centering during the background load.
    reg [11:0] pending_w_ctrl, pending_h_ctrl;
    reg [11:0] active_w_ctrl, active_h_ctrl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_img_n) begin
        if (!ctrl_rst_img_n) begin
            pending_w_ctrl <= 12'd640;
            pending_h_ctrl <= 12'd480;
            active_w_ctrl  <= 12'd640;
            active_h_ctrl  <= 12'd480;
        end else begin
            if (d01_header_valid) begin
                pending_w_ctrl <= d01_width;
                pending_h_ctrl <= d01_height;
            end
            if (frame_swap_ack) begin
                active_w_ctrl <= pending_w_ctrl;
                active_h_ctrl <= pending_h_ctrl;
            end
        end
    end

    // E01 starts the visual transition with LOAD so button feedback is not
    // blocked by the complete back-frame read. SWAP is issued only after the
    // back frame is ready, and TRANSITION then waits for visual completion.
    wire [7:0] pipeline_error_code_ctrl =
        (cluster_error != 8'd0) ? cluster_error :
        (d01_error != 8'd0) ? d01_error :
        (d02_error != 8'd0) ? d02_error :
        stream_fifo_overflow ? 8'hE6 :
        frame_load_timeout ? 8'hE4 :
        (frame_load_error && (frame_load_error_detail != 8'd0)) ?
            (8'hD0 | frame_load_error_detail) :
        frame_load_error ? 8'hE5 : 8'd0;

    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if(!ctrl_rst_ctl_n) begin failed_was_load_ctrl<=0;failed_index_ctrl<=0;permanent_image_error_ctrl<=0;end
        else if(req_error_ctrl) begin
            failed_was_load_ctrl<=req_type_ctrl==2'd1;
            failed_index_ctrl<=load_index_ctrl;
            permanent_image_error_ctrl<=(d01_error != 0) || (d02_error != 0);
        end
    end
    media_failure_guard u_failure_guard (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_ctl_n), .error(error_ctrl), .error_code(error_code_ctrl),
        .fault_snapshot(fault_snapshot_ctrl), .media_ready(media_ready_ctrl && failed_was_load_ctrl && !program_enabled_ctrl),
        .media_count(media_count_ctrl), .failed_index(failed_index_ctrl),
        .permanent_error(permanent_image_error_ctrl), .index_commit(index_commit_ctrl),
        .user_navigation(key_pulse_debug_ctrl[9] || key_pulse_debug_ctrl[11]),
        .recover(recover_image_ctrl), .load_valid(recovery_load_ctrl), .load_index(recovery_index_ctrl),
        .load_accepted(recovery_load_ctrl && !busy_ctrl && !error_ctrl && !interrupt_active_ctrl),
        .diagnostic(recovery_snapshot_ctrl), .first_snapshot(recovery_first_ctrl)
    );

    e_media_request_ctrl #(
        .REQUEST_TIMEOUT_CYCLES(500000000),
        .LOAD_RETRY_MAX(4),
        .LOAD_RETRY_GAP_CYCLES(500000)
    ) u_media_request (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_ctl_n),
        .media_ready(media_ready_ctrl), .media_count(media_count_ctrl),
        .req_valid(req_valid_ctrl && !program_hold_swap_ctrl), .req_type(req_type_ctrl),
        .req_index(req_index_ctrl), .req_ready(req_ready_raw_ctrl),
        .req_done(req_done_ctrl), .req_error(req_error_ctrl),
        .req_error_code(req_error_code_ctrl),
        .load_start(load_start_ctrl), .load_index(load_index_ctrl),
        .swap_request(swap_request_ctrl),
        .load_done(frame_load_done), .load_error(frame_load_error),
        .permanent_media_error((d01_error != 0) || (d02_error != 0)),
        .load_timeout(frame_load_timeout), .swap_ack(frame_swap_ack),
        .transition_enable((FADE_ENABLE != 0) && !program_transaction_ctrl),
        .transition_done(fade_done_pulse_ctrl),
        .pipeline_error_code(pipeline_error_code_ctrl), .debug_status(request_debug_ctrl), .busy()
    );

    mem_write_cdc u_mem_write_cdc (
        .wr_clk(ctrl_clk50), .wr_rst_n(ctrl_rst_img_n),
        .wr_valid(mem_wr_valid), .wr_ready(mem_wr_ready),
        .wr_addr_word(mem_wr_addr_word), .wr_data(mem_wr_data), .wr_strb(mem_wr_strb),
        .wr_done(mem_wr_done), .wr_error(mem_wr_error),
        .rd_clk(sdram_ctrl_clk), .rd_rst_n(mem_rst_n),
        .rd_valid(mem_cdc_valid), .rd_ready(mem_cdc_ready),
        .rd_addr_word(mem_cdc_addr_word), .rd_data(mem_cdc_data), .rd_strb(mem_cdc_strb),
        .rd_done(mem_cdc_done), .rd_error(mem_cdc_error)
    );

    // Diagnostic stage latches: these wires are declared by the decoder/frame manager above.
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            d02_image_done_seen_ctrl <= 1'b0;
            frame_load_done_seen_ctrl <= 1'b0;
            frame_swap_ack_seen_ctrl <= 1'b0;
        end else begin
            if (d02_image_done) d02_image_done_seen_ctrl <= 1'b1;
            if (frame_load_done) frame_load_done_seen_ctrl <= 1'b1;
            if (frame_swap_ack) frame_swap_ack_seen_ctrl <= 1'b1;
        end
    end
    // ----------------------------------------------------------------------
    // D04 SDRAM + D06 line prefetch + D07/D08/D09/D10 video path.
    // ----------------------------------------------------------------------
    wire mem_rd_valid;
    wire mem_rd_ready;
    wire [20:0] mem_rd_addr_word;
    wire mem_rd_rsp_valid;
    wire [31:0] mem_rd_rsp_data;
    wire mem_rd_error;
    wire mem_burst_valid, mem_burst_ready;
    wire [20:0] mem_burst_addr_word;
    wire [3:0] mem_burst_len;
    wire mem_burst_rsp_valid, mem_burst_rsp_last, mem_burst_rsp_error;
    wire [31:0] mem_burst_rsp_data;
    wire phy_req_valid, phy_req_ready, phy_req_write;
    wire [20:0] phy_req_addr_word;
    wire [31:0] phy_req_wdata;
    wire [3:0] phy_req_wstrb;
    wire phy_rsp_valid;
    wire [31:0] phy_rsp_rdata;
    wire phy_rsp_error;
    wire phy_burst_valid, phy_burst_ready;
    wire [20:0] phy_burst_addr_word;
    wire [3:0] phy_burst_len;
    wire phy_burst_rsp_valid, phy_burst_rsp_last, phy_burst_rsp_error;
    wire [31:0] phy_burst_rsp_data;
    wire phy_init_done;
    wire arbiter_init_done;
    wire phy_timeout_error;
    wire sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire sdram_cke_delayed;
    // Add a real EG logic buffer on CKE; R11 post-route had -0.069 ns hold.
    EG_LOGIC_BUF u_sdram_cke_delay (.i(sdram_cke), .o(sdram_cke_delayed));
    wire [1:0] sdram_ba;
    wire [10:0] sdram_addr;
    wire [31:0] sdram_dq;
    wire [3:0] sdram_dqm;

    wire line_urgent_mem;
    sdram_arbiter #(
        .FRAME_A_BASE_WORD(FRAME_A_BASE_WORD),
        .FRAME_B_BASE_WORD(FRAME_B_BASE_WORD),
        .AUDIO_BUF_BASE_WORD(AUDIO_BUF_BASE_WORD)
    ) u_arbiter (
        .clk(sdram_ctrl_clk), .rst_n(mem_rst_n),
        .line_urgent(line_urgent_mem),
        .wr_valid(mem_cdc_valid), .wr_ready(mem_cdc_ready),
        .wr_addr_word(mem_cdc_addr_word), .wr_data(mem_cdc_data),
        .wr_strb(mem_cdc_strb), .wr_done(mem_cdc_done), .wr_error(mem_cdc_error),
        .rd_valid(mem_rd_valid), .rd_ready(mem_rd_ready),
        .rd_addr_word(mem_rd_addr_word), .rd_rsp_valid(mem_rd_rsp_valid),
        .rd_data(mem_rd_rsp_data), .rd_error(mem_rd_error),
        .burst_valid(mem_burst_valid), .burst_ready(mem_burst_ready),
        .burst_addr_word(mem_burst_addr_word), .burst_len(mem_burst_len),
        .burst_rsp_valid(mem_burst_rsp_valid), .burst_rsp_data(mem_burst_rsp_data),
        .burst_rsp_last(mem_burst_rsp_last), .burst_rsp_error(mem_burst_rsp_error),
        .sdram_init_done(arbiter_init_done), .busy(),
        .phy_req_valid(phy_req_valid), .phy_req_ready(phy_req_ready),
        .phy_req_write(phy_req_write), .phy_req_addr_word(phy_req_addr_word),
        .phy_req_wdata(phy_req_wdata), .phy_req_wstrb(phy_req_wstrb),
        .phy_rsp_valid(phy_rsp_valid), .phy_rsp_rdata(phy_rsp_rdata),
        .phy_rsp_error(phy_rsp_error), .phy_init_done(phy_init_done),
        .phy_burst_valid(phy_burst_valid), .phy_burst_ready(phy_burst_ready),
        .phy_burst_addr_word(phy_burst_addr_word), .phy_burst_len(phy_burst_len),
        .phy_burst_rsp_valid(phy_burst_rsp_valid), .phy_burst_rsp_data(phy_burst_rsp_data),
        .phy_burst_rsp_last(phy_burst_rsp_last), .phy_burst_rsp_error(phy_burst_rsp_error)
    );

    eg4_sdram_phy #(
        .INIT_WAIT_CYCLES(10000), .TRP_CYCLES(2), .TRCD_CYCLES(2),
        .CAS_LATENCY(3), .TRSC_CYCLES(2), .TRFC_CYCLES(7),
        .REFRESH_INTERVAL_CYCLES(390), .REQUEST_TIMEOUT_CYCLES(65535)
    ) u_phy (
        .clk(sdram_ctrl_clk), .rst_n(mem_rst_phy_n),
        .req_valid(phy_req_valid), .req_ready(phy_req_ready),
        .req_write(phy_req_write), .req_addr_word(phy_req_addr_word),
        .req_wdata(phy_req_wdata), .req_wstrb(phy_req_wstrb),
        .rsp_valid(phy_rsp_valid), .rsp_rdata(phy_rsp_rdata),
        .rsp_error(phy_rsp_error), .timeout_error(phy_timeout_error),
        .init_done(phy_init_done), .sdram_clk(sdram_clk),
        .burst_req_valid(phy_burst_valid), .burst_req_ready(phy_burst_ready),
        .burst_req_addr_word(phy_burst_addr_word), .burst_req_len(phy_burst_len),
        .burst_rsp_valid(phy_burst_rsp_valid), .burst_rsp_rdata(phy_burst_rsp_data),
        .burst_rsp_last(phy_burst_rsp_last), .burst_rsp_error(phy_burst_rsp_error),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba),
        .sdram_addr(sdram_addr), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );

    SDRAM u_eg4_sdram (
        .clk(sdram_phy_clk), .ras_n(sdram_ras_n), .cas_n(sdram_cas_n),
        .we_n(sdram_we_n), .addr(sdram_addr), .ba(sdram_ba), .dq(sdram_dq),
        .cs_n(sdram_cs_n), .dm0(sdram_dqm[0]), .dm1(sdram_dqm[1]),
        .dm2(sdram_dqm[2]), .dm3(sdram_dqm[3]), .cke(sdram_cke_delayed)
    );
    wire tpg_de, tpg_hs, tpg_vs;
    wire [23:0] unused_tpg_rgb;
    video_timing_720p u_timing (
        .clk(pxlclk_i), .rst_n(media_rst_n), .de(tpg_de), .hs(tpg_hs), .vs(tpg_vs)
    );

    reg de_d, vs_d, active_line_seen;
    reg [11:0] raster_x, raster_y;
    reg frame_boundary_toggle_pxl;
    reg frame_boundary_sync1_ctrl, frame_boundary_sync2_ctrl, frame_boundary_seen_ctrl;
    reg frame_swap_ack_sync1_pxl, frame_swap_ack_sync2_pxl;
    reg frame_swap_ack_seen_pxl;
    reg frame_swap_ack_toggle_ctrl;
    wire frame_swap_event_pxl = frame_swap_ack_sync2_pxl ^ frame_swap_ack_seen_pxl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_img_n) begin
        if (!ctrl_rst_img_n) frame_swap_ack_toggle_ctrl <= 0;
        else if (frame_swap_ack) frame_swap_ack_toggle_ctrl <= !frame_swap_ack_toggle_ctrl;
    end

    wire line_start = (!de_d && tpg_de);
    wire [11:0] line_start_y = raster_y;
    assign frame_boundary_pxl = vs_d && !tpg_vs;

    // Geometry and the displayed SDRAM base both change shortly after the raw
    // VS edge. Start the mapper well inside vertical blanking so the new frame
    // base and synchronized image dimensions are stable before line 0 is
    // requested. Thirty-two pixel clocks are negligible against the blanking
    // interval and remove the one-frame old-geometry window.
    reg [31:0] mapper_start_delay_pxl;
    reg       mapper_frame_start_pxl;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            mapper_start_delay_pxl <= 32'd0;
            mapper_frame_start_pxl <= 1'b0;
        end else begin
            mapper_start_delay_pxl <= {mapper_start_delay_pxl[30:0],
                                       frame_boundary_pxl};
            mapper_frame_start_pxl <= mapper_start_delay_pxl[31];
        end
    end

    // Event toggles are the CDC boundary for read-only telemetry. The monitor
    // synchronizes them into the 50 MHz control domain.
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            perf_frame_toggle_pxl <= 1'b0;
            perf_underflow_toggle_pxl <= 1'b0;
            perf_frame_underflow_seen_pxl <= 1'b0;
        end else begin
            if (bridge_pixel_error)
                perf_frame_underflow_seen_pxl <= 1'b1;
            if (frame_boundary_pxl) begin
                perf_frame_toggle_pxl <= ~perf_frame_toggle_pxl;
                // Count frames containing actual line-bridge underflow.
                // One event per frame is slow enough for the control CDC.
                if (perf_frame_underflow_seen_pxl)
                    perf_underflow_toggle_pxl <= ~perf_underflow_toggle_pxl;
                perf_frame_underflow_seen_pxl <= bridge_pixel_error;
            end
        end
    end
    assign frame_boundary_ctrl = frame_boundary_sync2_ctrl ^ frame_boundary_seen_ctrl;

    // Adaptive aspect mapping fills the 1280x960 content window as far as
    // possible while using one scale factor for both axes. Geometry is latched
    // after the blanking-synchronized mapper start and source rows are scheduled
    // into the proven two-bank line bridge without interpolation.
    wire [11:0] line_index_now = line_start_y;
    reg [11:0] active_w_s1, active_w_s2;
    reg [11:0] active_h_s1, active_h_s2;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            active_w_s1 <= 12'd640; active_w_s2 <= 12'd640;
            active_h_s1 <= 12'd480; active_h_s2 <= 12'd480;
        end else begin
            active_w_s1 <= active_w_ctrl;
            active_w_s2 <= active_w_s1;
            active_h_s1 <= active_h_ctrl;
            active_h_s2 <= active_h_s1;
        end
    end

    wire line_req_pulse_pxl;
    wire [11:0] line_req_y_pxl;
    wire bridge_pixel_req_valid;
    wire [11:0] bridge_pixel_req_x;
    wire [11:0] bridge_pixel_req_y;
    wire bridge_pixel_req_ready;
    wire bridge_pixel_valid;
    wire [15:0] bridge_pixel_data;
    wire bridge_line_ready_bank;
    wire [11:0] mapper_src_w_pxl, mapper_src_h_pxl;
    wire [12:0] mapper_dst_x0_pxl, mapper_dst_x1_pxl;
    wire [12:0] mapper_dst_y0_pxl, mapper_dst_y1_pxl;

    adaptive_aspect_raster_mapper #(
        .C_DST_HEIGHT(720),
        .C_CONTENT_LEFT(312),
        .C_CONTENT_TOP(16),
        .C_CONTENT_WIDTH(944),
        .C_CONTENT_HEIGHT(656)
    ) u_adaptive_mapper (
        .i_clk(pxlclk_i),
        .i_rstn(media_rst_n),
        .i_source_width(active_w_s2),
        .i_source_height(active_h_s2),
        .i_frame_start(mapper_frame_start_pxl),
        .i_line_start(line_start),
        .i_line_y(line_index_now),
        .i_raster_de(tpg_de),
        .i_raster_x(raster_x),
        .i_raster_y(raster_y),
        .i_line_ready(bridge_line_ready_pulse),
        .i_line_ready_y(bridge_line_ready_y),
        .o_source_width(mapper_src_w_pxl),
        .o_source_height(mapper_src_h_pxl),
        .o_dst_x0(mapper_dst_x0_pxl),
        .o_dst_x1(mapper_dst_x1_pxl),
        .o_dst_y0(mapper_dst_y0_pxl),
        .o_dst_y1(mapper_dst_y1_pxl),
        .o_line_req_pulse(line_req_pulse_pxl),
        .o_line_req_y(line_req_y_pxl),
        .o_pixel_req_valid(bridge_pixel_req_valid),
        .o_pixel_req_x(bridge_pixel_req_x),
        .o_pixel_req_y(bridge_pixel_req_y)
    );

    // Keep raster coordinate generation independent from the adaptive mapper so
    // line scheduling and pixel mapping observe one stable coordinate stream.
    always @(posedge pxlclk_i or negedge pxl_rst_n) begin
        if (!pxl_rst_n) begin
            de_d <= 1'b0; vs_d <= 1'b0; active_line_seen <= 1'b0;
            raster_x <= 12'd0; raster_y <= 12'd0;
            frame_boundary_toggle_pxl <= 1'b0;
            frame_swap_ack_sync1_pxl <= 1'b0; frame_swap_ack_sync2_pxl <= 1'b0; frame_swap_ack_seen_pxl <= 1'b0;
        end else begin
            de_d <= tpg_de; vs_d <= tpg_vs;
            frame_swap_ack_sync1_pxl <= frame_swap_ack_toggle_ctrl;
            frame_swap_ack_sync2_pxl <= frame_swap_ack_sync1_pxl;
            frame_swap_ack_seen_pxl <= frame_swap_ack_sync2_pxl;
            if (frame_boundary_pxl) begin
                frame_boundary_toggle_pxl <= ~frame_boundary_toggle_pxl;
                active_line_seen <= 1'b0; raster_x <= 12'd0; raster_y <= 12'd0;
            end else if (line_start) begin
                raster_x <= 12'd0;
                active_line_seen <= 1'b1;
            end else if (tpg_de) begin
                raster_x <= raster_x + 1'b1;
            end
            if (!frame_boundary_pxl && de_d && !tpg_de && active_line_seen)
                raster_y <= raster_y + 1'b1;
        end
    end

    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            frame_boundary_sync1_ctrl <= 1'b0;
            frame_boundary_sync2_ctrl <= 1'b0;
            frame_boundary_seen_ctrl <= 1'b0;
        end else begin
            frame_boundary_sync1_ctrl <= frame_boundary_toggle_pxl;
            frame_boundary_sync2_ctrl <= frame_boundary_sync1_ctrl;
            frame_boundary_seen_ctrl <= frame_boundary_sync2_ctrl;
        end
    end

    reg frame_show_mem1, frame_show_mem2;
    always @(posedge sdram_ctrl_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            frame_show_mem1 <= 1'b0;
            frame_show_mem2 <= 1'b0;
        end else begin
            frame_show_mem1 <= frame_show_select;
            frame_show_mem2 <= frame_show_mem1;
        end
    end
    wire [20:0] frame_base_word_mem = frame_show_mem2 ? FRAME_B_BASE_WORD : FRAME_A_BASE_WORD;

    // Front-frame metadata settles before the three-stage request mailbox.
    reg [11:0] width_meta_mem,width_sync_mem,height_meta_mem,height_sync_mem;
    reg [1:0] ready_meta_mem,ready_sync_mem;
    reg frame_select_meta_pxl,frame_select_sync_pxl;
    always @(posedge sdram_ctrl_clk or negedge mem_rst_bridge_n) begin
        if(!mem_rst_bridge_n)begin width_meta_mem<=640;width_sync_mem<=640;height_meta_mem<=480;height_sync_mem<=480;ready_meta_mem<=0;ready_sync_mem<=0;end
        else begin width_meta_mem<=active_w_ctrl;width_sync_mem<=width_meta_mem;height_meta_mem<=active_h_ctrl;height_sync_mem<=height_meta_mem;ready_meta_mem<=frame_ready;ready_sync_mem<=ready_meta_mem;end
    end
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if(!media_rst_n)begin frame_select_meta_pxl<=0;frame_select_sync_pxl<=0;end
        else begin frame_select_meta_pxl<=frame_show_select;frame_select_sync_pxl<=frame_select_meta_pxl;end
    end
    wire front_ready_mem=ready_sync_mem[frame_show_mem2];
    wire crc_line_start_mem,crc_line_done_mem,crc_word_valid_mem,crc_frame_mem;
    wire [8:0] crc_line_y_mem;
    wire [11:0] crc_width_mem,last_crc_error_y_mem;
    wire [31:0] crc_word_data_mem;
    wire crc_result_valid_mem,crc_result_ok_mem,line_error_event_mem;
    wire [15:0] expected_crc_mem,observed_crc_mem,crc_failure_count_mem;
    wire [15:0] verified_frame_count_mem;
    frame_line_crc u_frame_line_crc (
        .write_clk(ctrl_clk50),.write_rst_n(ctrl_rst_img_n),
        .pixel_valid(d03_valid),.pixel_ready(frame_pixel_ready),.pixel_rgb565(d03_rgb565),
        .pixel_x(d03_x),.pixel_y(d03_y),.image_width(d01_width),.write_frame_select(frame_load_select),
        .read_clk(sdram_ctrl_clk),.read_rst_n(mem_rst_bridge_n),
        .line_start(crc_line_start_mem),.read_frame_select(crc_frame_mem),.read_line_y(crc_line_y_mem),.read_width(crc_width_mem),
        .word_valid(crc_word_valid_mem),.word_data(crc_word_data_mem),.line_done(crc_line_done_mem),
        .result_valid(crc_result_valid_mem),.result_ok(crc_result_ok_mem),.expected_crc(expected_crc_mem),.observed_crc(observed_crc_mem)
    );
    reg [15:0] previous_crc_count_mem;
    reg first_crc_captured_mem;
    reg [31:0] first_crc_pair_mem;
    always @(posedge sdram_ctrl_clk or negedge mem_rst_bridge_n) begin
        if(!mem_rst_bridge_n)begin previous_crc_count_mem<=0;first_crc_captured_mem<=0;first_crc_pair_mem<=0;end
        else begin
            previous_crc_count_mem<=crc_failure_count_mem;
            if(!first_crc_captured_mem && crc_failure_count_mem!=previous_crc_count_mem) begin
                first_crc_pair_mem<={expected_crc_mem,observed_crc_mem};first_crc_captured_mem<=1;
            end
        end
    end
    wire [7:0] crc_count_saturated_mem=|crc_failure_count_mem[15:8] ? 8'hff : crc_failure_count_mem[7:0];
    wire [31:0] memory_health_mem={8'hc4,crc_count_saturated_mem,last_crc_error_y_mem[8:0],5'd0,front_ready_mem,line_error_event_mem};
    // Observation-only held diagnostics; they never grant ownership or alter playback.
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if(!ctrl_rst_ctl_n)begin memory_health_meta_ctrl<=0;memory_health_sync_ctrl<=0;memory_crc_meta_ctrl<=0;memory_crc_sync_ctrl<=0;memory_pass_meta_ctrl<=0;memory_pass_sync_ctrl<=0;end
        else begin memory_health_meta_ctrl<=memory_health_mem;memory_health_sync_ctrl<=memory_health_meta_ctrl;
            memory_crc_meta_ctrl<=first_crc_pair_mem;memory_crc_sync_ctrl<=memory_crc_meta_ctrl;
            memory_pass_meta_ctrl<={8'hc5,verified_frame_count_mem,8'd0};memory_pass_sync_ctrl<=memory_pass_meta_ctrl;end
    end

    // Cut the mapper DDA arithmetic from line-bank acceptance and BRAM address.
    // The raster sideband below carries the same additional pixel-clock delay.
    reg display_valid;
    reg bridge_pixel_req_valid_q;
    reg [11:0] bridge_pixel_req_x_q, bridge_pixel_req_y_q;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            bridge_pixel_req_valid_q <= 1'b0;
            bridge_pixel_req_x_q <= 12'd0;
            bridge_pixel_req_y_q <= 12'd0;
        end else begin
            // No displayed SDRAM frame exists before the first real swap ACK.
            // Suppress startup reads at the producer; later missing rows remain errors.
            bridge_pixel_req_valid_q <= bridge_pixel_req_valid && display_valid;
            bridge_pixel_req_x_q <= bridge_pixel_req_x;
            bridge_pixel_req_y_q <= bridge_pixel_req_y;
        end
    end

    direct_line_bridge_dp #(.FRAME_WIDTH(640), .FRAME_HEIGHT(480)) u_line_bridge (
        .ctrl_clk(sdram_ctrl_clk),
        .ctrl_rst_n(mem_rst_bridge_n),
        .pxl_clk(pxlclk_i),
        .pxl_rst_n(pxl_rst_n),
        .line_req_pulse_pxl(line_req_pulse_pxl),
        .line_req_y_pxl(line_req_y_pxl),
        .frame_base_word_ctrl(frame_base_word_mem),
        .line_urgent_ctrl(line_urgent_mem),
        .frame_changed_pxl(frame_swap_event_pxl),.front_frame_select_pxl(frame_select_sync_pxl),
        .raster_frame_start_pxl(mapper_frame_start_pxl),
        .front_ready_ctrl(front_ready_mem),.front_frame_select_ctrl(frame_show_mem2),.front_width_ctrl(width_sync_mem),
        .front_height_ctrl(height_sync_mem),.verified_frame_count_ctrl(verified_frame_count_mem),
        .crc_line_start_ctrl(crc_line_start_mem),.crc_frame_select_ctrl(crc_frame_mem),.crc_line_y_ctrl(crc_line_y_mem),
        .crc_width_ctrl(crc_width_mem),.crc_word_valid_ctrl(crc_word_valid_mem),.crc_word_data_ctrl(crc_word_data_mem),
        .crc_line_done_ctrl(crc_line_done_mem),.crc_result_valid_ctrl(crc_result_valid_mem),.crc_result_ok_ctrl(crc_result_ok_mem),
        .line_error_event_ctrl(line_error_event_mem),.crc_failure_count_ctrl(crc_failure_count_mem),.last_crc_error_y_ctrl(last_crc_error_y_mem),
        .line_ready_pulse_pxl(bridge_line_ready_pulse),
        .line_ready_y_pxl(bridge_line_ready_y),
        .line_ready_bank_pxl(bridge_line_ready_bank),
        .pixel_req_valid(bridge_pixel_req_valid_q),
        .pixel_req_x(bridge_pixel_req_x_q),
        .pixel_req_y(bridge_pixel_req_y_q),
        .pixel_req_ready(bridge_pixel_req_ready),
        .pixel_valid(bridge_pixel_valid),
        .pixel_data(bridge_pixel_data),
        .pixel_error(bridge_pixel_error),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_ready(mem_rd_ready),
        .mem_rd_addr_word(mem_rd_addr_word),
        .mem_rd_rsp_valid(mem_rd_rsp_valid),
        .mem_rd_rsp_data(mem_rd_rsp_data),
        .mem_rd_error(mem_rd_error),
         .mem_burst_valid(mem_burst_valid),
         .mem_burst_ready(mem_burst_ready),
         .mem_burst_addr_word(mem_burst_addr_word),
         .mem_burst_len(mem_burst_len),
         .mem_burst_rsp_valid(mem_burst_rsp_valid),
         .mem_burst_rsp_data(mem_burst_rsp_data),
         .mem_burst_rsp_last(mem_burst_rsp_last),
         .mem_burst_rsp_error(mem_burst_rsp_error)
    );

    // The selected line bridge returns its registered valid tag and BRAM data
    // one pixel after registered request acceptance. Two raster stages include
    // that BRAM response and the new request stage, preserving pixel alignment.
    reg        tpg_de_d1;
    reg        tpg_hs_d1;
    reg        tpg_vs_d1;
    reg [11:0] raster_x_d1;
    reg [11:0] raster_y_d1;
    reg tpg_de_d2, tpg_hs_d2, tpg_vs_d2;
    reg [11:0] raster_x_d2, raster_y_d2;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            tpg_de_d1   <= 1'b0;
            tpg_hs_d1   <= 1'b0;
            tpg_vs_d1   <= 1'b0;
            raster_x_d1 <= 12'd0;
            raster_y_d1 <= 12'd0;
            tpg_de_d2 <= 1'b0;
            tpg_hs_d2 <= 1'b0;
            tpg_vs_d2 <= 1'b0;
            raster_x_d2 <= 12'd0;
            raster_y_d2 <= 12'd0;
        end else begin
            tpg_de_d1   <= tpg_de;
            tpg_hs_d1   <= tpg_hs;
            tpg_vs_d1   <= tpg_vs;
            raster_x_d1 <= raster_x;
            raster_y_d1 <= raster_y;
            tpg_de_d2 <= tpg_de_d1;
            tpg_hs_d2 <= tpg_hs_d1;
            tpg_vs_d2 <= tpg_vs_d1;
            raster_x_d2 <= raster_x_d1;
            raster_y_d2 <= raster_y_d1;
        end
    end

    wire image_area_d2 = tpg_de_d2 &&
                         (raster_x_d2 >= mapper_dst_x0_pxl) &&
                         (raster_x_d2 < mapper_dst_x1_pxl) &&
                         (raster_y_d2 >= mapper_dst_y0_pxl) &&
                         (raster_y_d2 < mapper_dst_y1_pxl);
    // SDRAM contents are undefined until the first complete frame swap. The
    // earlier design registered this flag but never used it, allowing
    // uninitialized frame data to appear as a broken first image.
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n)
            display_valid <= 1'b0;
        else if (frame_swap_event_pxl)
            display_valid <= 1'b1;
    end
    // The line bridge registers its valid tag together with the synchronous
    // BRAM data. A missing/underflowed line therefore becomes a clean black
    // pixel instead of reusing stale BRAM output.
    wire [15:0] image_base_rgb565 = (display_valid &&
                                     image_area_d2 && bridge_pixel_valid) ?
                                    bridge_pixel_data : 16'h0000;

    reg video_underflow_latched;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n)
            video_underflow_latched <= 1'b0;
        else if (bridge_pixel_error)
            video_underflow_latched <= 1'b1;
    end

    // Register the raw image/border stream before the D10 blend. This breaks
    // the line-bank selection from the fade multiply/add path.
    reg [15:0] raw_rgb_q;
    reg        raw_de_q, raw_hs_q, raw_vs_q;
    reg [11:0] raw_x_q, raw_y_q;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            raw_rgb_q <= 16'd0;
            raw_de_q  <= 1'b0;
            raw_hs_q  <= 1'b0;
            raw_vs_q  <= 1'b0;
            raw_x_q   <= 12'd0;
            raw_y_q   <= 12'd0;
        end else begin
            raw_rgb_q <= image_base_rgb565;
            raw_de_q  <= tpg_de_d2;
            raw_hs_q  <= tpg_hs_d2;
            raw_vs_q  <= tpg_vs_d2;
            raw_x_q   <= raster_x_d2;
            raw_y_q   <= raster_y_d2;
        end
    end

    // Arm during LOAD and retain the complete old image until the new frame is
    // ready. An eased blue-gray curtain covers the image before the existing
    // frame-boundary swap, then moves off to reveal the new image. OSD mixing
    // remains downstream; SDRAM still supplies only one displayed frame.
    wire fade_enable = (FADE_ENABLE != 0);
    wire fade_swap_pending_ctrl;
    wire fade_swap_ready_sync2_ctrl;
    reg  playback_error_sync1_pxl, playback_error_sync2_pxl;
    reg  fade_done_toggle_pxl;
    reg  fade_done_sync1_ctrl, fade_done_sync2_ctrl, fade_done_seen_ctrl;
    reg  transition_reverse_sync1_pxl, transition_reverse_sync2_pxl;
    wire frame_ready_sync2_pxl;

    wire fade_start_request_pxl;
    wire fade_abort_pxl = playback_error_sync2_pxl;
    wire fade_swap_ready;
    wire fade_done_pxl;
    reg frame_swapped_token_pxl;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) frame_swapped_token_pxl <= 0;
        else if (fade_start_request_pxl || fade_abort_pxl || !fade_enable) frame_swapped_token_pxl <= 0;
        else if (frame_swap_event_pxl) frame_swapped_token_pxl <= 1;
    end
    // Diagnostic fields are observational only; no sampled state bus controls playback.
    assign live_snapshot_ctrl = {transaction_events_ctrl,
        pipeline_error_code_ctrl,
        fade_swap_pending_ctrl,curtain_debug_sync_ctrl,request_debug_ctrl,
        playback_state_ctrl,req_type_ctrl,req_valid_ctrl,req_ready_ctrl,req_done_ctrl};
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            curtain_debug_meta_ctrl<=0;curtain_debug_sync_ctrl<=0;
            transaction_events_ctrl<=0;fault_snapshot_ctrl<=0;previous_snapshot_ctrl<=0;fault_snapshot_taken_ctrl<=0;error_seen_debug_ctrl<=0;
        end else begin
            curtain_debug_meta_ctrl<=curtain_debug_pxl;curtain_debug_sync_ctrl<=curtain_debug_meta_ctrl;
            error_seen_debug_ctrl<=error_ctrl;
            previous_snapshot_ctrl<=live_snapshot_ctrl;
            if (transition_start_ctrl) fault_snapshot_taken_ctrl<=0;
            if (transition_start_ctrl) transaction_events_ctrl<=8'h01;
            else transaction_events_ctrl<=transaction_events_ctrl | {
                frame_load_done,pipeline_error_code_ctrl!=0,fade_swap_ready_sync2_ctrl,
                fade_done_pulse_ctrl,frame_swap_ack,frame_swap_request,swap_request_ctrl,1'b0};
            if ((req_error_ctrl || (error_ctrl && !error_seen_debug_ctrl)) && !fault_snapshot_taken_ctrl) begin
                fault_snapshot_ctrl<=req_error_ctrl ? previous_snapshot_ctrl : live_snapshot_ctrl;
                fault_snapshot_taken_ctrl<=1;
            end
        end
    end

    assign fade_done_pulse_ctrl = fade_done_sync2_ctrl ^ fade_done_seen_ctrl;
    // A completed-frame SWAP is retained until actual frame-manager acknowledgement.
    // The curtain accepts it locally; an early one-shot LOAD event is no longer required.
    curtain_request_bridge u_curtain_request (
        .clk_ctrl(ctrl_clk50), .rst_ctrl_n(ctrl_rst_ctl_n),
        .clk_pixel(pxlclk_i), .rst_pixel_n(media_rst_n),
        .enable(fade_enable), .program_transaction(program_transaction_ctrl),
        .swap_command_ctrl(swap_request_ctrl), .swap_ack_ctrl(frame_swap_ack),
        .request_error_ctrl(req_error_ctrl),
        .curtain_idle_pixel((curtain_debug_pxl==3'd0) || (curtain_debug_pxl==3'd5)),
        .curtain_abort_pixel(fade_abort_pxl), .curtain_ready_pixel(fade_swap_ready),
        .pending_ctrl(fade_swap_pending_ctrl), .ready_ctrl(fade_swap_ready_sync2_ctrl), .frame_swap_request_ctrl(frame_swap_request),
        .start_pixel(fade_start_request_pxl), .frame_ready_pixel(frame_ready_sync2_pxl)
    );
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            fade_done_sync1_ctrl          <= 1'b0;
            fade_done_sync2_ctrl          <= 1'b0;
            fade_done_seen_ctrl           <= 1'b0;
        end else begin
            fade_done_sync1_ctrl <= fade_done_toggle_pxl;
            fade_done_sync2_ctrl <= fade_done_sync1_ctrl;
            fade_done_seen_ctrl  <= fade_done_sync2_ctrl;
        end
    end

    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            playback_error_sync1_pxl  <= 1'b0;
            playback_error_sync2_pxl  <= 1'b0;
            fade_done_toggle_pxl      <= 1'b0;
            transition_reverse_sync1_pxl <= 1'b0;
            transition_reverse_sync2_pxl <= 1'b0;
        end else begin
            playback_error_sync1_pxl <= error_ctrl;
            playback_error_sync2_pxl <= playback_error_sync1_pxl;
            transition_reverse_sync1_pxl <= transition_reverse_ctrl;
            transition_reverse_sync2_pxl <= transition_reverse_sync1_pxl;
            if (fade_done_pxl)
                fade_done_toggle_pxl <= ~fade_done_toggle_pxl;
        end
    end

    wire fade_active;
    wire [7:0] fade_level;
    wire fade_error, fade_valid;
    wire [15:0] fade_rgb565;
    // VS falling edge occurs in vertical blank; register only the curtain event.
    reg curtain_frame_boundary_q;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) curtain_frame_boundary_q <= 1'b0;
        else curtain_frame_boundary_q <= frame_boundary_pxl;
    end
    page_curtain_transition #(
        .SCREEN_WIDTH(1280),
        .FRAME_TIMEOUT_CYCLES(32'd8000000),
        .SWAP_TIMEOUT_CYCLES(32'd3500000000)
    ) u_fade (
        .clk(pxlclk_i), .rst_n(media_rst_n), .enable(fade_enable),
        .start(fade_start_request_pxl),
        .reverse(transition_reverse_sync2_pxl),
        .frame_boundary(curtain_frame_boundary_q),
        .frame_swapped(frame_swapped_token_pxl),
        .frame_ready(frame_ready_sync2_pxl),
        .abort(fade_abort_pxl),
        .pixel_valid(raw_de_q),
        .pixel_x(raw_x_q),
        .in_rgb565(raw_rgb_q),
        .out_valid(fade_valid), .out_rgb565(fade_rgb565),
        .fade_active(fade_active), .fade_level(fade_level),
        .swap_ready(fade_swap_ready), .done(fade_done_pxl),
        .debug_state(curtain_debug_pxl), .fade_error(fade_error)
    );

    // Fade-through-black has exactly two pixel-clock output stages. Delay the
    // raster/OSD coordinates by the same amount so image and text remain
    // aligned and the existing downstream pipeline timing is preserved.
    reg        fade_de_q1, fade_de_q2;
    reg        fade_hs_q1, fade_hs_q2;
    reg        fade_vs_q1, fade_vs_q2;
    reg [11:0] fade_x_q1, fade_x_q2;
    reg [11:0] fade_y_q1, fade_y_q2;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            fade_de_q1 <= 1'b0;
            fade_de_q2 <= 1'b0;
            fade_hs_q1 <= 1'b0;
            fade_hs_q2 <= 1'b0;
            fade_vs_q1 <= 1'b0;
            fade_vs_q2 <= 1'b0;
            fade_x_q1  <= 12'd0;
            fade_x_q2  <= 12'd0;
            fade_y_q1  <= 12'd0;
            fade_y_q2  <= 12'd0;
        end else begin
            fade_de_q1 <= raw_de_q;
            fade_de_q2 <= fade_de_q1;
            fade_hs_q1 <= raw_hs_q;
            fade_hs_q2 <= fade_hs_q1;
            fade_vs_q1 <= raw_vs_q;
            fade_vs_q2 <= fade_vs_q1;
            fade_x_q1  <= raw_x_q;
            fade_x_q2  <= fade_x_q1;
            fade_y_q1  <= raw_y_q;
            fade_y_q2  <= fade_y_q1;
        end
    end

    // The fade module always returns the raw image in its idle/full-brightness
    // state. It has no path that can hold the output on black after an error or
    // a disabled transition.
    wire [15:0] presentation_rgb565 = fade_rgb565;

    // G04 fault aggregation. The PLL-unlock flag is latched in the always-on
    // 50 MHz reference domain and survives the PLL-induced design reset; the
    // watchdog is a 3 s busy-stall detector in the 50 MHz control domain.
    wire diag_pll_unlock_ctrl;
    wire diag_watchdog_ctrl;
    wire diag_timeout_ctrl;
    wire diag_retry_ctrl;
    wire [7:0] diag_retry_count;
    wire [7:0] diag_status_flags;
    wire diag_stable;

    fault_monitor #(
        .WATCHDOG_CYCLES(150000000)
    ) u_fault_monitor (
        .clk_ctrl(ctrl_clk50), .rst_ctrl_n(ctrl_rst_ctl_n),
        .clk_ref(FPGA_SYS_50M_CLK_P), .rst_ref_n(pll_reset_count[7]),
        .pll_locked(pll_locked),
        .no_card(sd_init_done && !sd_init_ok),
        .bad_bpb(bpb_done && !bpb_valid),
        .bad_bmp((d01_error != 8'd0) || (d02_error != 8'd0)),
        .bad_wav(audio_error),
        .timeout_event(frame_load_timeout ||
                       (error_ctrl && (error_code_ctrl == 8'hE4))),
        .retry_event(audio_retry_q || audio_resume_retry),
        .progress(sector_rsp_valid | cluster_byte_valid |
                  d02_pixel_valid | frame_boundary_ctrl),
        // ST_INIT/ST_RESET also assert playback busy while waiting for the
        // SD/FAT boot; the watchdog must only cover a stuck media load or
        // transition (ST_LOAD=5, ST_TRANSITION=6).
        .busy(busy_ctrl &&
              ((playback_state_ctrl == 3'd5) ||
               (playback_state_ctrl == 3'd6))),
        .pll_unlock_seen(),
        .pll_unlock_ctrl(diag_pll_unlock_ctrl),
        .watchdog_seen(diag_watchdog_ctrl),
        .timeout_seen(diag_timeout_ctrl),
        .retry_seen(diag_retry_ctrl),
        .retry_count(diag_retry_count),
        .status_flags(diag_status_flags),
        .stable(diag_stable)
    );

    reg diag_pll_unlock_sync1_pxl;
    reg diag_pll_unlock_sync2_pxl;
    reg diag_watchdog_sync1_pxl;
    reg diag_watchdog_sync2_pxl;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            diag_pll_unlock_sync1_pxl <= 1'b0;
            diag_pll_unlock_sync2_pxl <= 1'b0;
            diag_watchdog_sync1_pxl  <= 1'b0;
            diag_watchdog_sync2_pxl  <= 1'b0;
        end else begin
            diag_pll_unlock_sync1_pxl <= diag_pll_unlock_ctrl;
            diag_pll_unlock_sync2_pxl <= diag_pll_unlock_sync1_pxl;
            diag_watchdog_sync1_pxl <= diag_watchdog_ctrl;
            diag_watchdog_sync2_pxl <= diag_watchdog_sync1_pxl;
        end
    end

    wire osd_error_valid_i = diag_pll_unlock_sync2_pxl |
                             diag_watchdog_sync2_pxl |
                             audio_error_sync2_pxl |
                             |{sd_init_error, bpb_error, scan_error,
                               cluster_error, d01_error, d02_error,
                               frame_load_error, mem_wr_error, mem_rd_error,
                               video_underflow_latched, fade_error,
                               playback_error_pxl};
    // The legacy pipeline used 0x01 in all three media decoders. Encode the
    // source only for OSD display so one screen capture identifies the failing
    // stage without changing any control or data behavior.
    wire [7:0] cluster_error_diagnostic_code =
        (cluster_error == 8'h03) ? (8'h70 | cluster_error_detail[3:0]) :
        (8'h10 | cluster_error);
    wire [7:0] playback_error_diagnostic_code_pxl =
        (scan_error != 8'd0) ? (8'h60 | scan_error) :
        (cluster_error != 8'd0) ? cluster_error_diagnostic_code :
        (d01_error != 8'd0) ? (8'h20 | d01_error) :
        (d02_error != 8'd0) ? (8'h30 | d02_error) :
        playback_error_code_pxl;
    wire [7:0] osd_error_code_i =
        playback_error_pxl ? playback_error_diagnostic_code_pxl :
        (sd_init_error != 0) ? (8'h40 | sd_init_error) :
        (bpb_error != 0) ? (8'h50 | bpb_error) :
        (scan_error != 0) ? (8'h60 | scan_error) :
        (cluster_error != 0) ? cluster_error_diagnostic_code :
        (d01_error != 0) ? (8'h20 | d01_error) :
        (d02_error != 0) ? (8'h30 | d02_error) : 8'hFF;
    wire [7:0] osd_error_code_with_audio =
        (osd_error_code_i != 8'hFF) ? osd_error_code_i :
        (audio_error_sync2_pxl ? audio_error_code_sync2_pxl : 8'hFF);
    wire [7:0] osd_error_code_mux =
        diag_pll_unlock_sync2_pxl ? 8'hE7 :
        diag_watchdog_sync2_pxl ? 8'hE8 :
        (video_underflow_latched && (osd_error_code_with_audio == 8'hFF)) ?
        8'hEE : osd_error_code_with_audio;

    // Stage 1/2: OSD character decode and four overlay output stages.
    reg [15:0] osd_base_d1, osd_base_d2, osd_base_d3, osd_base_d4, osd_base_d5;
    reg        osd_de_d1, osd_de_d2, osd_de_d3, osd_de_d4, osd_de_d5;
    reg        osd_hs_d1, osd_hs_d2, osd_hs_d3, osd_hs_d4, osd_hs_d5;
    reg        osd_vs_d1, osd_vs_d2, osd_vs_d3, osd_vs_d4, osd_vs_d5;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            osd_base_d1 <= 16'd0;
            osd_base_d2 <= 16'd0;
            osd_base_d3 <= 16'd0;
            osd_base_d4 <= 16'd0;
            osd_base_d5 <= 16'd0;
            osd_de_d1   <= 1'b0;
            osd_de_d2   <= 1'b0;
            osd_de_d3   <= 1'b0;
            osd_de_d4   <= 1'b0;
            osd_de_d5   <= 1'b0;
            osd_hs_d1   <= 1'b0;
            osd_hs_d2   <= 1'b0;
            osd_hs_d3   <= 1'b0;
            osd_hs_d4   <= 1'b0;
            osd_hs_d5   <= 1'b0;
            osd_vs_d1   <= 1'b0;
            osd_vs_d2   <= 1'b0;
            osd_vs_d3   <= 1'b0;
            osd_vs_d4   <= 1'b0;
            osd_vs_d5   <= 1'b0;
        end else begin
            osd_base_d1 <= presentation_rgb565;
            osd_base_d2 <= osd_base_d1;
            osd_base_d3 <= osd_base_d2;
            osd_base_d4 <= osd_base_d3;
            osd_base_d5 <= osd_base_d4;
            osd_de_d1   <= fade_valid;
            osd_de_d2   <= osd_de_d1;
            osd_de_d3   <= osd_de_d2;
            osd_de_d4   <= osd_de_d3;
            osd_de_d5   <= osd_de_d4;
            osd_hs_d1   <= fade_hs_q2;
            osd_hs_d2   <= osd_hs_d1;
            osd_hs_d3   <= osd_hs_d2;
            osd_hs_d4   <= osd_hs_d3;
            osd_hs_d5   <= osd_hs_d4;
            osd_vs_d1   <= fade_vs_q2;
            osd_vs_d2   <= osd_vs_d1;
            osd_vs_d3   <= osd_vs_d2;
            osd_vs_d4   <= osd_vs_d3;
            osd_vs_d5   <= osd_vs_d4;
        end
    end

    // P2 overlay synchronization: the eight-band level bundle crosses into
    // the pixel domain with a toggle handshake so no 64-bit word is sampled
    // while its individual bytes are changing.
    reg spectrum_toggle_sync1_pxl;
    reg spectrum_toggle_sync2_pxl;
    reg spectrum_toggle_seen_pxl;
    reg [95:0] spectrum_bar_tops_pxl;
    reg       audio_line_switch_sync1_pxl;
    reg       audio_line_switch_sync2_pxl;
    reg       osd_switch_sync1_pxl;
    reg       osd_switch_sync2_pxl;
    reg       banner_switch_sync1_pxl;
    reg       banner_switch_sync2_pxl;
    reg [26:0] subtitle_div;
    reg [4:0]  subtitle_phase;
    reg [11:0] spec_x_d1, spec_x_d2, spec_x_d3;
    reg [11:0] spec_y_d1, spec_y_d2, spec_y_d3;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            spectrum_toggle_sync1_pxl <= 1'b0;
            spectrum_toggle_sync2_pxl <= 1'b0;
            spectrum_toggle_seen_pxl <= 1'b0;
            spectrum_bar_tops_pxl <= {8{12'd1008}};
            audio_line_switch_sync1_pxl <= 1'b0;
            audio_line_switch_sync2_pxl <= 1'b0;
            osd_switch_sync1_pxl <= 1'b0;
            osd_switch_sync2_pxl <= 1'b0;
            banner_switch_sync1_pxl <= 1'b0;
            banner_switch_sync2_pxl <= 1'b0;
            subtitle_div           <= 27'd0;
            subtitle_phase         <= 5'd0;
            spec_x_d1 <= 12'd0; spec_x_d2 <= 12'd0; spec_x_d3 <= 12'd0;
            spec_y_d1 <= 12'd0; spec_y_d2 <= 12'd0; spec_y_d3 <= 12'd0;
        end else begin
            spectrum_toggle_sync1_pxl <= spectrum_toggle_ctrl;
            spectrum_toggle_sync2_pxl <= spectrum_toggle_sync1_pxl;
            if (spectrum_toggle_sync2_pxl != spectrum_toggle_seen_pxl) begin
                spectrum_toggle_seen_pxl <= spectrum_toggle_sync2_pxl;
                spectrum_bar_tops_pxl <= spectrum_bar_tops_hold_ctrl;
            end
            audio_line_switch_sync1_pxl <= SW0;
            audio_line_switch_sync2_pxl <= audio_line_switch_sync1_pxl;
            osd_switch_sync1_pxl <= SW1;
            osd_switch_sync2_pxl <= osd_switch_sync1_pxl;
            banner_switch_sync1_pxl <= SW2;
            banner_switch_sync2_pxl <= banner_switch_sync1_pxl;

            if (subtitle_div == 27'd74_249_999) begin
                subtitle_div   <= 27'd0;
                subtitle_phase <= subtitle_phase + 1'b1;
            end else begin
                subtitle_div <= subtitle_div + 1'b1;
            end

            spec_x_d1 <= fade_x_q2;
            spec_x_d2 <= spec_x_d1;
            spec_x_d3 <= spec_x_d2;
            spec_y_d1 <= fade_y_q2;
            spec_y_d2 <= spec_y_d1;
            spec_y_d3 <= spec_y_d2;
        end
    end

    wire [7:0] waveform_sample, waveform_previous;
    wire waveform_column = (spec_x_d3 >= 12'd24) &&
                           (spec_x_d3 < 12'd280);
    wire [11:0] waveform_offset = waveform_column ?
                                  (spec_x_d3 - 12'd24) : 12'd0;
    wire [7:0] waveform_address = waveform_offset[7:0];
    audio_waveform_capture u_waveform (
        .ctrl_clk(ctrl_clk50), .ctrl_rst_n(ctrl_rst_play_n),
        .sample_valid(hdmi_pcm_valid_ctrl), .sample_pcm(hdmi_pcm_ctrl),
        .pixel_clk(pxlclk_i), .pixel_rst_n(media_rst_n), .frame_boundary(frame_boundary_pxl),
        .read_address(waveform_address),
        .sample_current(waveform_sample), .sample_previous(waveform_previous)
    );
    wire        spec_alpha;
    wire [15:0] spec_rgb565;
    audio_spectrum_overlay u_audio_spectrum_overlay (
        .clk(pxlclk_i), .rst_n(media_rst_n),
        .pixel_x(spec_x_d3), .pixel_y(spec_y_d3),
        .bar_tops(spectrum_bar_tops_pxl),
        .waveform_sample(waveform_sample), .waveform_previous(waveform_previous),
        .panel_enable(audio_line_switch_sync2_pxl),
        .alpha(spec_alpha), .rgb565(spec_rgb565)
    );

    // Match the five-stage base-video delay before composition. The overlay
    // module contributes two coordinate stages; these registers complete the
    // remaining three stages and keep the final color mux out of long paths.
    reg        spec_alpha_q;
    reg [15:0] spec_rgb565_q;
    reg        spec_alpha_q2, spec_alpha_q3;
    reg [15:0] spec_rgb565_q2, spec_rgb565_q3;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            spec_alpha_q   <= 1'b0;
            spec_rgb565_q  <= 16'd0;
            spec_alpha_q2  <= 1'b0;
            spec_alpha_q3  <= 1'b0;
            spec_rgb565_q2 <= 16'd0;
            spec_rgb565_q3 <= 16'd0;
        end else begin
            spec_alpha_q   <= spec_alpha;
            spec_rgb565_q  <= spec_rgb565;
            spec_alpha_q2  <= spec_alpha_q;
            spec_alpha_q3  <= spec_alpha_q2;
            spec_rgb565_q2 <= spec_rgb565_q;
            spec_rgb565_q3 <= spec_rgb565_q2;
        end
    end

    // Slow program status is published only after a stable payload edge. The
    // destination acknowledges capture; source holds data until ack returns.
    wire [3:0] program_seconds_tens = program_seconds_ctrl / 7'd10;
    wire [3:0] program_seconds_ones = program_seconds_ctrl % 7'd10;
    reg normal_autoplay_status_ctrl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) normal_autoplay_status_ctrl <= 1'b0;
        else if (playback_state_ctrl == 3'd3) normal_autoplay_status_ctrl <= 1'b1;
        else if ((playback_state_ctrl == 3'd2) || (playback_state_ctrl == 3'd4))
            normal_autoplay_status_ctrl <= 1'b0;
    end
    wire [20:0] program_status_ctrl = {normal_autoplay_status_ctrl,
        playback_state_ctrl, program_enabled_ctrl, program_priming_ctrl,
        program_paused_ctrl, program_stalled_ctrl, program_ended_ctrl,
        program_highlight_ctrl, program_caption_ctrl,
        program_seconds_tens, program_seconds_ones};
    reg [20:0] program_status_hold_ctrl;
    reg program_status_toggle_ctrl, program_status_publish_ctrl;
    reg program_status_ack_meta_ctrl, program_status_ack_sync_ctrl;
    reg program_status_meta_pxl, program_status_sync_pxl, program_status_seen_pxl;
    reg [20:0] program_status_bus_meta_pxl, program_status_bus_sync_pxl;
    reg [20:0] program_status_pending_pxl, program_status_pxl;
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            program_status_hold_ctrl <= 0;
            program_status_toggle_ctrl <= 0;
            program_status_publish_ctrl <= 0;
            program_status_ack_meta_ctrl <= 0;
            program_status_ack_sync_ctrl <= 0;
        end else begin
            program_status_ack_meta_ctrl <= program_status_seen_pxl;
            program_status_ack_sync_ctrl <= program_status_ack_meta_ctrl;
            if (program_status_publish_ctrl) begin
                program_status_toggle_ctrl <= !program_status_toggle_ctrl;
                program_status_publish_ctrl <= 0;
            end else if ((program_status_ack_sync_ctrl == program_status_toggle_ctrl) &&
                         (program_status_hold_ctrl != program_status_ctrl)) begin
                program_status_hold_ctrl <= program_status_ctrl;
                program_status_publish_ctrl <= 1;
            end
        end
    end
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            program_status_meta_pxl <= 0; program_status_sync_pxl <= 0;
            program_status_seen_pxl <= 0;
            program_status_bus_meta_pxl <= 0; program_status_bus_sync_pxl <= 0;
            program_status_pending_pxl <= 0; program_status_pxl <= 0;
        end else begin
            program_status_meta_pxl <= program_status_toggle_ctrl;
            program_status_sync_pxl <= program_status_meta_pxl;
            program_status_bus_meta_pxl <= program_status_hold_ctrl;
            program_status_bus_sync_pxl <= program_status_bus_meta_pxl;
            if (program_status_sync_pxl != program_status_seen_pxl) begin
                program_status_pending_pxl <= program_status_bus_sync_pxl;
                program_status_seen_pxl <= program_status_sync_pxl;
            end
            if (frame_boundary_pxl) program_status_pxl <= program_status_pending_pxl;
        end
    end

    wire osd_valid;
    wire [15:0] osd_layer_rgb565;
    wire osd_alpha, osd_active;
    subtitle_text_renderer u_text_renderer (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_ctl_n), .text_begin(text_begin_ctrl),
        .upload_in_progress(text_upload_ctrl), .upload_urgent(text_urgent_ctrl),
        .upload_length(text_length_ctrl), .upload_seconds(text_seconds_ctrl),
        .text_write(text_write_ctrl), .text_address(text_address_ctrl), .text_code(text_code_ctrl),
        .text_commit(text_commit_ctrl), .restore_default(text_restore_ctrl), .cancel_urgent(text_cancel_ctrl),
        .ready(text_ready_ctrl), .done(text_done_ctrl), .result(text_result_ctrl),
        .interrupt_active(interrupt_active_ctrl), .diagnostic(text_diagnostic_ctrl),
        .bitmap_ready(host_bitmap_ready), .bitmap_done(host_bitmap_done), .bitmap_scroll_done(host_bitmap_scroll_done), .bitmap_write(host_bitmap_write),
        .bitmap_address(host_bitmap_address), .bitmap_data(host_bitmap_data),
        .bitmap_width(host_bitmap_width), .bitmap_commit(host_bitmap_commit)
    );
    host_subtitle_plane u_host_subtitle (
        .ctrl_clk(ctrl_clk50), .ctrl_rst_n(ctrl_rst_ctl_n),
        .write_valid(host_bitmap_write), .write_address(host_bitmap_address), .write_data(host_bitmap_data), .write_width(host_bitmap_width),
        .commit(host_bitmap_commit), .hide(1'b0), .ready(host_bitmap_ready), .commit_done(host_bitmap_done), .scroll_done(host_bitmap_scroll_done),
        .pixel_clk(pxlclk_i), .pixel_rst_n(media_rst_n), .frame_boundary(frame_boundary_pxl),
        .pixel_valid(fade_valid), .display_enable(banner_switch_sync2_pxl), .pixel_x(fade_x_q2), .pixel_y(fade_y_q2),
        .subtitle_enabled(host_subtitle_enabled), .subtitle_alpha(host_subtitle_alpha), .subtitle_rgb(host_subtitle_rgb)
    );
    osd_engine_pxl_split #(
        .SCREEN_WIDTH(1280), .SCREEN_HEIGHT(720),
        .OSD_X(32), .OSD_Y(32), .OSD_COLUMNS(15)
    ) u_osd (
        .clk(pxlclk_i), .rst_n(media_rst_n),
        .pixel_valid(fade_valid),
        .pixel_x(fade_x_q2), .pixel_y(fade_y_q2),
        .base_rgb565(presentation_rgb565),
        .status_enable(osd_switch_sync2_pxl),
        .banner_enable(banner_switch_sync2_pxl),
        .image_index(media_ready_status_pxl ?
                     ({3'd0, active_index_pxl} + 8'd1) : 8'd0),
        .sd_ok(media_ready_status_pxl),
        .audio_ok(audio_ok_sync2_pxl),
        .error_valid(osd_error_valid_i),
        .error_code(osd_error_code_mux),
        .brightness_level(brightness_level_pxl),
        .speed_level({5'd0, speed_level_pxl}),
        .volume_level(volume_level_pxl),
        .subtitle_phase(subtitle_phase),
        .program_status(program_status_pxl[16:0]),
        .playback_status(program_status_pxl[20:17]),
        .diag_mode(diag_mode_sync2_pxl),
        .source_width(display_valid ? mapper_src_w_pxl : 12'd0),
        .source_height(display_valid ? mapper_src_h_pxl : 12'd0),
        .fps_value(perf_fps_pxl),
        .swap_count(perf_swap_count_pxl),
        .underflow_count(perf_underflow_count_pxl),
        .underrun_count(perf_underrun_count_pxl),
        .out_valid(osd_valid), .out_rgb565(),
        .osd_rgb565(osd_layer_rgb565), .osd_alpha(osd_alpha),
        .osd_active(osd_active)
    );

    // Stage 3: alpha-compose OSD over the faded image without brightness.
    wire layer_mix_valid;
    wire [15:0] layer_mix_rgb565;
    wire layer_mix_underflow;
    video_mixer u_layer_mixer (
        .pixel_valid(osd_de_d5), .base_rgb565(osd_base_d5),
        .transition_enable(1'b0), .transition_level(8'd0),
        .next_rgb565(16'd0),
        .osd_rgb565(host_subtitle_alpha ? host_subtitle_rgb : osd_layer_rgb565),
        .osd_alpha(osd_alpha || host_subtitle_alpha),
        // The line alpha is already gated by synchronized SW3. Keeping this
        // layer enable high prevents audio status from hiding a requested line.
        .spectrum_enable(1'b1),
        .spectrum_rgb565(spec_rgb565_q3),
        .spectrum_alpha(spec_alpha_q3),
        .brightness_enable(1'b0), .brightness_level(8'hFF),
        .out_valid(layer_mix_valid), .out_rgb565(layer_mix_rgb565),
        .out_underflow(layer_mix_underflow)
    );

    reg [15:0] layer_rgb_q;
    reg        layer_de_q, layer_hs_q, layer_vs_q;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            layer_rgb_q <= 16'd0;
            layer_de_q  <= 1'b0;
            layer_hs_q  <= 1'b0;
            layer_vs_q  <= 1'b0;
        end else begin
            layer_rgb_q <= layer_mix_rgb565;
            layer_de_q  <= osd_de_d5;
            layer_hs_q  <= osd_hs_d5;
            layer_vs_q  <= osd_vs_d5;
        end
    end

    // Stage 4: two-stage brightness gain, still in the pixel clock domain.
    wire [15:0] bright_rgb_comb;
    brightness_gain_pipelined u_brightness (
        .clk(pxlclk_i), .rst_n(media_rst_n),
        .brightness_enable(1'b1),
        .brightness_level(brightness_level_pxl),
        .in_rgb565(layer_rgb_q),
        .out_rgb565(bright_rgb_comb)
    );

    // Match the brightness module's two-cycle data latency with the timing
    // sideband before the final output register.
    reg bright_de_q, bright_hs_q, bright_vs_q;
    reg bright_de_qq, bright_hs_qq, bright_vs_qq;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            bright_de_q   <= 1'b0;
            bright_hs_q   <= 1'b0;
            bright_vs_q   <= 1'b0;
            bright_de_qq  <= 1'b0;
            bright_hs_qq  <= 1'b0;
            bright_vs_qq  <= 1'b0;
        end else begin
            bright_de_q  <= layer_de_q;
            bright_hs_q  <= layer_hs_q;
            bright_vs_q  <= layer_vs_q;
            bright_de_qq <= bright_de_q;
            bright_hs_qq <= bright_hs_q;
            bright_vs_qq <= bright_vs_q;
        end
    end

    reg [15:0] final_rgb_q;
    reg        final_de_q, final_hs_q, final_vs_q;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            final_rgb_q <= 16'd0;
            final_de_q  <= 1'b0;
            final_hs_q  <= 1'b0;
            final_vs_q  <= 1'b0;
        end else begin
            final_rgb_q <= bright_rgb_comb;
            final_de_q  <= bright_de_qq;
            final_hs_q  <= bright_hs_qq;
            final_vs_q  <= bright_vs_qq;
        end
    end

    // Match the extra pixel pipeline stage before hdmi_tx_adapter's own timing
    // delay so the image pixel and DE/HS/VS stay aligned.
    reg adapter_timing_hs_i, adapter_timing_vs_i, adapter_timing_de_i;
    reg adapter_timing_hs_ii, adapter_timing_vs_ii, adapter_timing_de_ii;
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            adapter_timing_hs_i  <= 1'b0;
            adapter_timing_vs_i  <= 1'b0;
            adapter_timing_de_i  <= 1'b0;
            adapter_timing_hs_ii <= 1'b0;
            adapter_timing_vs_ii <= 1'b0;
            adapter_timing_de_ii <= 1'b0;
        end else begin
            adapter_timing_hs_i  <= tpg_hs;
            adapter_timing_vs_i  <= tpg_vs;
            adapter_timing_de_i  <= tpg_de;
            adapter_timing_hs_ii <= adapter_timing_hs_i;
            adapter_timing_vs_ii <= adapter_timing_vs_i;
            adapter_timing_de_ii <= adapter_timing_de_i;
        end
    end

    wire adapter_hs, adapter_vs, adapter_de;
    wire [23:0] adapter_rgb;
    wire adapter_underflow_latched;
    hdmi_tx_adapter u_adapter (
        .pxlclk(pxlclk_i), .rst_n(media_rst_n), .timing_hs(final_hs_q),
        .timing_vs(final_vs_q), .timing_de(final_de_q), .timing_x(raster_x),
        .timing_y(raster_y), .pixel_rd_en(), .pixel_valid(final_de_q),
        .pixel_rgb565(final_rgb_q),
        .pixel_underflow(1'b0),
        .vga_hs(adapter_hs), .vga_vs(adapter_vs), .vga_de(adapter_de),
        .vga_rgb(adapter_rgb), .underflow_latched(adapter_underflow_latched),
        .underflow_event(adapter_underflow_event)
    );

    performance_monitor #(
        .CTRL_HZ(50000000)
    ) u_performance (
        .clk_ctrl(ctrl_clk50), .rst_ctrl_n(ctrl_rst_ctl_n),
        .audio_underrun_level(audio_underrun),
        .frame_toggle_pxl(perf_frame_toggle_pxl),
        .frame_swap_ack_ctrl(frame_swap_ack),
        .underflow_toggle_pxl(perf_underflow_toggle_pxl),
        .clk_pixel(pxlclk_i), .rst_pixel_n(media_rst_n),
        .fps_pxl(perf_fps_pxl),
        .swap_count_pxl(perf_swap_count_pxl),
        .underflow_count_pxl(perf_underflow_count_pxl),
        .underrun_count_pxl(perf_underrun_count_pxl)
    );

    wire [7:0] hdmi_packet_type_pxl;
    reg [7:0] hdmi_sample_count_pxl, hdmi_nonzero_count_pxl;
    reg [7:0] hdmi_acr_count_pxl, hdmi_asp_count_pxl;
    reg [7:0] hdmi_packet_previous_pxl;
    reg [31:0] audio_snapshot_meta_ctrl, audio_snapshot_sync_ctrl;
    wire audio_snapshot_hold_n_17 /* synthesis keep=true */;
    wire audio_snapshot_hold_17 /* synthesis keep=true */;
    assign audio_snapshot_hold_n_17 = ~audio_snapshot_meta_ctrl[17];
    assign audio_snapshot_hold_17 = ~audio_snapshot_hold_n_17;
    wire [31:0] audio_snapshot_capture = {
        audio_snapshot_meta_ctrl[31:18],
        audio_snapshot_hold_17,
        audio_snapshot_meta_ctrl[16:0]
    };
    always @(posedge pxlclk_i or negedge media_rst_n) begin
        if (!media_rst_n) begin
            hdmi_sample_count_pxl <= 0; hdmi_nonzero_count_pxl <= 0;
            hdmi_acr_count_pxl <= 0; hdmi_asp_count_pxl <= 0; hdmi_packet_previous_pxl <= 0;
        end else begin
            hdmi_packet_previous_pxl <= hdmi_packet_type_pxl;
            if (hdmi_pcm_strobe_pxl) begin
                hdmi_sample_count_pxl <= hdmi_sample_count_pxl + 1'b1;
                if (hdmi_pcm_pxl != 0) hdmi_nonzero_count_pxl <= hdmi_nonzero_count_pxl + 1'b1;
            end
            if (hdmi_packet_type_pxl != hdmi_packet_previous_pxl) begin
                if (hdmi_packet_type_pxl == 1) hdmi_acr_count_pxl <= hdmi_acr_count_pxl + 1'b1;
                if (hdmi_packet_type_pxl == 2) hdmi_asp_count_pxl <= hdmi_asp_count_pxl + 1'b1;
            end
        end
    end
    // Read-only progress counters, not control signals; a query may straddle a count.
    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin audio_snapshot_meta_ctrl <= 0; audio_snapshot_sync_ctrl <= 0; end
        else begin
            audio_snapshot_meta_ctrl <= {hdmi_asp_count_pxl,hdmi_acr_count_pxl,hdmi_nonzero_count_pxl,hdmi_sample_count_pxl};
            audio_snapshot_sync_ctrl <= audio_snapshot_capture;
        end
    end
    assign audio_snapshot_ctrl = audio_snapshot_sync_ctrl;
    hdmi_audio_tx u_hdmi_tx (
        .clk_pixel(pxlclk_i), .clk_pixel_x5(pxlclk_5x_i), .reset(!media_rst_n),
        .video_hs(adapter_hs), .video_vs(adapter_vs), .video_de(adapter_de),
        .video_rgb(adapter_rgb),
        .sample_strobe(hdmi_pcm_strobe_pxl),
        .audio_diagnostic_mode(audio_diagnostic_pxl[2:1]),
        .audio_sample_word_0(hdmi_pcm_pxl), .audio_sample_word_1(hdmi_pcm_pxl),
        .hdmi_clk_p(HDMI_CLK_P),
        .hdmi_d2_p(HDMI_D2_P), .hdmi_d1_p(HDMI_D1_P), .hdmi_d0_p(HDMI_D0_P),
        .debug_mode(), .debug_packet_type(hdmi_packet_type_pxl)
    );

    assign VGA_HS = adapter_hs;
    assign VGA_VS = adapter_vs;
    assign VGA_R = adapter_rgb[23:19];
    assign VGA_G = adapter_rgb[15:10];
    assign VGA_B = adapter_rgb[7:3];

    // R27 first-fault encoder (kept for diagnostics). LED0..LED5 report the
    // storage/video milestones; LED6 = audio active+OK, LED7 = video underflow
    // or audio error.
    reg       first_fault_valid;
    reg [4:0] first_fault_code;
    reg [4:0] fault_code_now;
    always @* begin
        fault_code_now = 5'd0;
        if (cluster_error != 8'd0) begin
            case (cluster_error)
                8'h01: fault_code_now = 5'd1;  // C06 invalid parameters
                8'h02: fault_code_now = 5'd2;  // C06 sector reader error
                8'h03: fault_code_now = 5'd3;  // C06 FAT lookup error
                8'h04: fault_code_now = 5'd4;  // C06 early FAT EOC
                8'h05: fault_code_now = 5'd5;  // C06 timeout
                default: fault_code_now = 5'd5;
            endcase
        end else if (d01_error != 8'd0) begin
            fault_code_now = (d01_error <= 8'd10) ? (5'd5 + d01_error[4:0]) : 5'd15;
        end else if (d02_error != 8'd0) begin
            fault_code_now = (d02_error <= 8'd6) ? (5'd15 + d02_error[4:0]) : 5'd21;
        end else if (stream_fifo_overflow) begin
            fault_code_now = 5'd22;
        end else if (frame_load_error) begin
            fault_code_now = 5'd23;
        end else if (frame_load_timeout) begin
            fault_code_now = 5'd24;
        end else if (mem_wr_error) begin
            fault_code_now = 5'd25;
        end else if (mem_rd_error) begin
            fault_code_now = 5'd26;
        end else if (bridge_pixel_error) begin
            fault_code_now = 5'd27;
        end else if (fade_error) begin
            fault_code_now = 5'd30;
        end
    end

    always @(posedge ctrl_clk50 or negedge ctrl_rst_ctl_n) begin
        if (!ctrl_rst_ctl_n) begin
            first_fault_valid <= 1'b0;
            first_fault_code  <= 5'd0;
        end else if (!first_fault_valid && (fault_code_now != 5'd0)) begin
            first_fault_valid <= 1'b1;
            first_fault_code  <= fault_code_now;
        end
    end

    // Board-visible diagnostic channel independent of HDMI. The seven-segment
    // display shows E### with the same decimal code used by the OSD.
    reg        board_diag_valid;
    reg [7:0]  board_diag_code;
    wire [7:0] cluster_error_board_code =
        (cluster_error == 8'h03) ? (8'h70 | cluster_error_detail[3:0]) :
        (8'h10 | cluster_error);
    always @* begin
        board_diag_valid = 1'b1;
        board_diag_code  = 8'hFF;
        if (sd_init_error != 8'd0)
            board_diag_code = 8'h40 | sd_init_error;
        else if ((bpb_error != 8'd0) && (first_sector_error_q != 8'd0))
            board_diag_code = sector_error_diag_code;
        else if (bpb_error != 8'd0)
            board_diag_code = 8'h50 | bpb_error;
        else if (scan_error != 8'd0)
            board_diag_code = 8'h60 | scan_error;
        else if (cluster_error != 8'd0)
            board_diag_code = cluster_error_board_code;
        else if (d01_error != 8'd0)
            board_diag_code = 8'h20 | d01_error;
        else if (d02_error != 8'd0)
            board_diag_code = 8'h30 | d02_error;
        else if (stream_fifo_overflow)
            board_diag_code = 8'hEF;
        else if (frame_load_error || frame_load_timeout)
            board_diag_code = (frame_load_error_detail != 8'd0) ?
                              (8'hD0 | frame_load_error_detail) : 8'hE5;
        else if (diag_watchdog_ctrl)
            board_diag_code = 8'hE8;
        else if (diag_pll_unlock_ctrl)
            board_diag_code = 8'hE7;
        else if (audio_error)
            board_diag_code = (audio_error_code != 8'd0) ?
                              audio_error_code : 8'hE9;
        else if (error_ctrl)
            board_diag_code = error_code_ctrl;
        else
            board_diag_valid = 1'b0;
    end

    seven_segment_diag u_board_diag (
        .clk_25m(ctrl_clk50),
        .rst_n(ctrl_rst_ctl_n),
        .error_valid(board_diag_valid),
        .error_code(board_diag_code),
        .digitron_cs(DigitronCS_Out),
        .digitron(Digitron_Out)
    );

    assign LED0 = sd_init_ok;
    assign LED1 = bpb_valid;
    assign LED2 = scan_done_seen;
    assign LED3 = d02_image_done_seen_ctrl;
    assign LED4 = frame_load_done_seen_ctrl;
    assign LED5 = frame_swap_ack_seen_ctrl;
    assign LED6 = audio_ok_sync2_pxl;
    assign LED7 = video_underflow_latched | audio_error_sync2_pxl;
endmodule









