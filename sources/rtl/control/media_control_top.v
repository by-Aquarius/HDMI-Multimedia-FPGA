// -----------------------------------------------------------------------------
// media_control_top.v
// E03: single control path from the physical 4x4 matrix to playback, playlist
// timing, brightness/speed parameters, and the D05/D10 request bus.
//
// B01/B02/B03 produce one key event stream. B03 maps only K9/K10/K11/K12/K13/
// K14/K15; K0..K8 remain reserved. E01 owns playback state and the unified
// downstream request bus. E02 owns the slideshow interval and issues load
// requests back to E01. B04 owns brightness and speed registers.
// -----------------------------------------------------------------------------
module media_control_top #(
    parameter integer SCAN_DIV             = 25000,
    parameter integer DEBOUNCE_CYCLES      = 1000000,
    parameter integer LONG_START_CYCLES    = 25000000,
    parameter integer LONG_REPEAT_CYCLES   = 5000000,
    parameter integer TIMER_CLK_HZ         = 50000000,
    parameter integer TIMER_TICK_HZ        = 1000,
    parameter [31:0] REQUEST_TIMEOUT_CYCLES = 32'd1000000,
    parameter integer AUTO_LOAD_FIRST_IMAGE = 0
) (
    input  wire        clk_50m,
    input  wire        rst_n,

    // Physical 4x4 matrix.
    input  wire [3:0]  key_col,
    input  wire [15:0] remote_key_pulse,
    output wire [3:0]  key_row,

    // C05 media context.
    input  wire        media_ready,
    input  wire        media_error,
    input  wire [7:0]  media_error_code,
    input  wire [4:0]  media_count,

    // D05/D10 unified request bus.
    output wire        req_valid,
    output wire [1:0]  req_type,
    output wire [4:0]  req_index,
    input  wire        req_ready,
    input  wire        req_done,
    input  wire        req_error,
    input  wire [7:0]  req_error_code,

    // Policy and recovery inputs from E03/G01.
    input  wire        transition_enable,
    input  wire        recover,
    input  wire        program_enable,
    input wire external_hold,
    input wire recovery_load,
    input wire [4:0] recovery_index,
    input  wire        program_load,
    input  wire [4:0]  program_load_index,
    input  wire        program_hold_swap,
    output wire        index_commit_debug,

    // D09/OSD control and status outputs.
    output wire [7:0]  brightness_level,
    output wire [2:0]  speed_level,
    output wire [2:0]  playback_state,
    output wire [4:0]  active_index,
    output wire        playing,
    output wire        paused,
    output wire        busy,
    output wire        error,
    output wire [7:0]  error_code,
    output wire        hold_frame,
    output wire        transition_reverse,
    output wire        transition_start,
    output wire [4:0]  next_index,
    output wire [31:0] period_ms,
    output wire [31:0] elapsed_ms,
    output wire        timer_busy,
    output wire        wrap_event,
    output wire [15:0] key_pulse_debug
);

    wire [15:0] raw_key;
    wire [15:0] key_down;
    wire [15:0] key_pulse_physical;
    wire [15:0] key_pulse = key_pulse_physical | remote_key_pulse;
    wire [15:0] key_long_unused;
    wire        cmd_prev;
    wire        cmd_next;
    wire        cmd_play_pause;
    wire        cmd_bright_dec;
    wire        cmd_bright_inc;
    wire        cmd_speed_dec;
    wire        cmd_speed_inc;
    wire        cmd_any_unused;
    wire        load_request;
    wire [4:0]  load_request_index;
    wire        index_commit;

    key_matrix_scan #(.SCAN_DIV(SCAN_DIV)) u_key_scan (
        .clk_50m(clk_50m), .rst_n(rst_n),
        .key_col(key_col), .key_row(key_row), .raw_key(raw_key)
    );

    key_debounce #(.STABLE_CYCLES(DEBOUNCE_CYCLES)) u_key_debounce (
        .clk_50m(clk_50m), .rst_n(rst_n),
        .raw_key(raw_key), .key_down(key_down)
    );

    key_event #(
        .LONG_START_CYCLES(LONG_START_CYCLES),
        .LONG_REPEAT_CYCLES(LONG_REPEAT_CYCLES)
    ) u_key_event (
        .clk_50m(clk_50m), .rst_n(rst_n),
        .key_down(key_down), .key_pulse(key_pulse_physical),
        .key_long(key_long_unused)
    );

    key_command_mapper u_key_mapper (
        .key_pulse(key_pulse),
        .cmd_prev(cmd_prev), .cmd_next(cmd_next),
        .cmd_play_pause(cmd_play_pause),
        .cmd_bright_dec(cmd_bright_dec),
        .cmd_bright_inc(cmd_bright_inc),
        .cmd_speed_dec(cmd_speed_dec),
        .cmd_speed_inc(cmd_speed_inc),
        .cmd_any(cmd_any_unused)
    );

    parameter_ctrl u_parameters (
        .clk_50m(clk_50m), .rst_n(rst_n),
        .cmd_bright_dec(cmd_bright_dec),
        .cmd_bright_inc(cmd_bright_inc),
        .cmd_speed_dec(cmd_speed_dec),
        .cmd_speed_inc(cmd_speed_inc),
        .brightness_level(brightness_level),
        .speed_level(speed_level)
    );

    playback_fsm #(
        .REQUEST_TIMEOUT_CYCLES(REQUEST_TIMEOUT_CYCLES),
        .AUTO_LOAD_FIRST_IMAGE(AUTO_LOAD_FIRST_IMAGE)
    ) u_playback (
        .clk(clk_50m), .rst_n(rst_n),
        .cmd_prev(cmd_prev && !external_hold), .cmd_next(cmd_next && !external_hold),
        .cmd_play_pause(cmd_play_pause && !program_enable && !external_hold),
        .media_ready(media_ready), .media_error(media_error),
        .media_error_code(media_error_code), .media_count(media_count),
        .load_request(recovery_load || (!external_hold && (program_enable ? program_load : load_request))),
        .load_request_index(recovery_load ? recovery_index : (program_enable ? program_load_index : load_request_index)),
        .request_hold(program_hold_swap),
        .req_valid(req_valid), .req_type(req_type), .req_index(req_index),
        .req_ready(req_ready), .req_done(req_done), .req_error(req_error),
        .req_error_code(req_error_code),
        .transition_enable(transition_enable), .recover(recover),
        .state(playback_state), .playing(playing), .paused(paused),
        .busy(busy), .error(error), .error_code(error_code),
        .hold_frame(hold_frame), .active_index(active_index),
        .index_commit(index_commit),
        .transition_reverse(transition_reverse),
        .transition_start(transition_start)
    );

    playlist_ctrl #(
        .CLK_HZ(TIMER_CLK_HZ),
        .TICK_HZ(TIMER_TICK_HZ)
    ) u_playlist (
        .clk(clk_50m), .rst_n(rst_n),
        .media_ready(media_ready), .media_count(media_count),
        .speed_level(speed_level),
        .active_index(active_index), .index_commit(index_commit),
        .playing(playing && !program_enable && !external_hold), .paused(paused || external_hold),
        .e01_busy(busy), .e01_error(error),
        .load_request(load_request),
        .load_request_index(load_request_index),
        .wrap_event(wrap_event),
        .next_index(next_index), .period_ms(period_ms),
        .elapsed_ms(elapsed_ms), .timer_busy(timer_busy)
    );

    assign key_pulse_debug = key_pulse;
    assign index_commit_debug = index_commit;

endmodule
