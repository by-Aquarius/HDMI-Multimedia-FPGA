// -----------------------------------------------------------------------------
// playback_fsm.v
// E01: media playback state machine and unified downstream request handshake.
//
// Request protocol:
//   req_valid/req_type/req_index -> req_ready (accept) -> req_done/req_error
//   LOAD is sent first, then SWAP, then TRANSITION. The requester holds valid
//   until ready, drops valid after acceptance, and waits for exactly one
//   completion or error pulse.
//
// Key priority: PLAY/PAUSE > PREV > NEXT. A command received while LOAD or
// TRANSITION is active is kept in a one-entry queue and applied after the
// transition returns to READY/PLAY/PAUSE. A request that never completes is
// converted into ERROR by REQUEST_TIMEOUT_CYCLES.
// A NEXT/PREV command received in ERROR clears the latched request error and
// is applied after the controller returns to a recoverable state. This keeps a
// transient media error from permanently locking the visible image.
// -----------------------------------------------------------------------------
module playback_fsm #(
    parameter [31:0] REQUEST_TIMEOUT_CYCLES = 32'd1000000,
    parameter integer AUTO_LOAD_FIRST_IMAGE = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    // B03 one-clock command pulses.
    input  wire        cmd_prev,
    input  wire        cmd_next,
    input  wire        cmd_play_pause,

    // C05 media context.
    input  wire        media_ready,
    input  wire        media_error,
    input  wire [7:0]  media_error_code,
    input  wire [4:0]  media_count,

    // E02 optional explicit load request.
    input  wire        load_request,
    input  wire [4:0]  load_request_index,
    input  wire        request_hold,

    // D05/D10 unified request bus.
    output reg         req_valid,
    output reg  [1:0]  req_type,
    output reg  [4:0]  req_index,
    input  wire        req_ready,
    input  wire        req_done,
    input  wire        req_error,
    input  wire [7:0]  req_error_code,

    // Transition policy and error recovery.
    input  wire        transition_enable,
    input  wire        recover,

    // Status for OSD, E02 and E03.
    output wire [2:0]  state,
    output reg         playing,
    output reg         paused,
    output reg         busy,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         hold_frame,
    output reg  [4:0]  active_index,
    output reg         index_commit,
    output reg         transition_reverse,
    output reg         transition_start
);

    localparam [2:0] ST_RESET      = 3'd0;
    localparam [2:0] ST_INIT       = 3'd1;
    localparam [2:0] ST_READY      = 3'd2;
    localparam [2:0] ST_PLAY       = 3'd3;
    localparam [2:0] ST_PAUSE      = 3'd4;
    localparam [2:0] ST_LOAD       = 3'd5;
    localparam [2:0] ST_TRANSITION = 3'd6;
    localparam [2:0] ST_ERROR      = 3'd7;

    localparam [1:0] REQ_NONE       = 2'd0;
    localparam [1:0] REQ_LOAD       = 2'd1;
    localparam [1:0] REQ_SWAP       = 2'd2;
    localparam [1:0] REQ_TRANSITION = 2'd3;

    localparam [1:0] CMD_NONE       = 2'd0;
    localparam [1:0] CMD_NEXT       = 2'd1;
    localparam [1:0] CMD_PREV       = 2'd2;
    localparam [1:0] CMD_PLAY_PAUSE = 2'd3;

    localparam [2:0] RET_READY      = ST_READY;
    localparam [2:0] RET_PLAY       = ST_PLAY;
    localparam [2:0] RET_PAUSE      = ST_PAUSE;

    localparam [7:0] ERR_NO_MEDIA   = 8'hE1;
    localparam [7:0] ERR_BAD_INDEX  = 8'hE2;
    localparam [7:0] ERR_REQUEST    = 8'hE3;
    localparam [7:0] ERR_TIMEOUT    = 8'hE4;
    localparam [7:0] ERR_MEDIA      = 8'hE5;

    reg [2:0]  state_next;
    reg [2:0]  state_current;
    reg [4:0]  target_index;
    reg [4:0]  target_index_next;
    reg [2:0]  return_state;
    reg [2:0]  return_state_next;
    reg [1:0]  pending_cmd;
    reg        transition_phase;
    reg        req_accepted;
    reg        frame_loaded;
    reg [31:0] req_timer;

    reg        start_load;
    reg        trap_error;
    reg [7:0]  trap_code;
    reg        advance_phase;
    reg        commit;

    wire [1:0] cmd_now;
    wire [1:0] cmd_effective;
    wire [2:0] state_return;
    wire [4:0] prev_index;
    wire [4:0] next_index;
    wire [5:0] next_index_wide;
    wire request_timeout_hit;

    assign state = state_current;
    assign cmd_now =
        cmd_play_pause ? CMD_PLAY_PAUSE :
        cmd_prev       ? CMD_PREV :
        cmd_next       ? CMD_NEXT : CMD_NONE;
    assign cmd_effective =
        ((state_current == ST_READY) || (state_current == ST_PLAY) ||
         (state_current == ST_PAUSE)) ?
        ((cmd_now >= pending_cmd) ? cmd_now : pending_cmd) : CMD_NONE;
    assign state_return =
        (state_current == ST_PLAY) ? RET_PLAY :
        (state_current == ST_PAUSE) ? RET_PAUSE : RET_READY;
    assign prev_index =
        (active_index == 5'd0) ? (media_count - 5'd1) :
        (active_index - 5'd1);
    assign next_index_wide = {1'b0, active_index} + 6'd1;
    assign next_index =
        (next_index_wide >= {1'b0, media_count}) ? 5'd0 :
        next_index_wide[4:0];
    assign request_timeout_hit =
        (REQUEST_TIMEOUT_CYCLES > 0) &&
        (req_timer >= (REQUEST_TIMEOUT_CYCLES - 1));

    // State register and auxiliary state. This is the only process that
    // writes state, active_index, target_index, error_code and the request
    // bookkeeping registers.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_current    <= ST_RESET;
            active_index     <= 5'd0;
            target_index     <= 5'd0;
            return_state     <= RET_READY;
            pending_cmd      <= CMD_NONE;
            transition_phase <= 1'b0;
            req_accepted     <= 1'b0;
            frame_loaded     <= 1'b0;
            req_timer        <= 32'd0;
            error_code       <= 8'd0;
            index_commit     <= 1'b0;
            transition_reverse <= 1'b0;
            transition_start   <= 1'b0;
        end else begin
            state_current <= state_next;
            index_commit <= commit;
            transition_start <= 1'b0;

            if (start_load) begin
                target_index     <= target_index_next;
                return_state     <= return_state_next;
                pending_cmd      <= CMD_NONE;
                transition_phase <= 1'b0;
                transition_start <= 1'b1;
                transition_reverse <=
                    (cmd_effective == CMD_NEXT) ||
                    (load_request && (cmd_effective == CMD_NONE));
            end
            if (commit) begin
                active_index <= target_index;
                frame_loaded <= 1'b1;
                transition_phase <= 1'b0;
            end
            if (trap_error) begin
                pending_cmd <= CMD_NONE;
                error_code  <= trap_code;
            end else if (recover ||
                         ((state_current == ST_ERROR) &&
                          (cmd_now != CMD_NONE))) begin
                error_code <= 8'd0;
            end

            if (start_load || trap_error || commit || advance_phase ||
                (state_next != state_current)) begin
                req_accepted <= 1'b0;
                req_timer    <= 32'd0;
            end else if ((state_current == ST_LOAD) ||
                         (state_current == ST_TRANSITION)) begin
                if (req_valid && req_ready)
                    req_accepted <= 1'b1;
                // A scheduled SWAP can intentionally wait through a long pause.
                // LOAD still times out; integration asserts hold only for an
                // unaccepted SWAP, with ready and downstream valid both gated.
                if (!request_hold) req_timer <= req_timer + 1'b1;
            end

            if (advance_phase)
                transition_phase <= 1'b1;

            if ((state_current == ST_LOAD) ||
                (state_current == ST_TRANSITION)) begin
                if ((cmd_now != CMD_NONE) && (cmd_now > pending_cmd))
                    pending_cmd <= cmd_now;
            end else if (state_current == ST_ERROR) begin
                if (cmd_now != CMD_NONE)
                    pending_cmd <= cmd_now;
            end else if ((state_current == ST_READY) ||
                         (state_current == ST_PLAY) ||
                         (state_current == ST_PAUSE)) begin
                if ((cmd_effective != CMD_NONE) || load_request)
                    pending_cmd <= CMD_NONE;
            end
        end
    end

    // Procedural next-state logic. All branches default to the current state,
    // and the case has an explicit default.
    always @(*) begin
        state_next       = state_current;
        start_load       = 1'b0;
        target_index_next = active_index;
        return_state_next = state_return;
        trap_error       = 1'b0;
        trap_code        = ERR_REQUEST;
        advance_phase    = 1'b0;
        commit           = 1'b0;

        case (state_current)
            ST_RESET: begin
                state_next = ST_INIT;
            end

            ST_INIT: begin
                if (media_error) begin
                    state_next = ST_ERROR;
                    trap_error = 1'b1;
                    trap_code  = (media_error_code != 8'd0) ?
                                 media_error_code : ERR_MEDIA;
                end else if (media_ready) begin
                    if (media_count == 5'd0) begin
                        state_next = ST_ERROR;
                        trap_error = 1'b1;
                        trap_code  = ERR_NO_MEDIA;
                    end else if (AUTO_LOAD_FIRST_IMAGE != 0) begin
                        // Present the first image after boot without requiring
                        // the user to press PLAY. Playback remains paused after
                        // the frame is loaded.
                        state_next        = ST_LOAD;
                        start_load        = 1'b1;
                        target_index_next = 5'd0;
                        return_state_next = RET_READY;
                    end else begin
                        state_next = ST_READY;
                    end
                end
            end

            ST_READY, ST_PLAY, ST_PAUSE: begin
                if (cmd_effective == CMD_PLAY_PAUSE) begin
                    if (state_current == ST_PLAY) begin
                        state_next = ST_PAUSE;
                    end else if (state_current == ST_PAUSE) begin
                        state_next = ST_PLAY;
                    end else if (frame_loaded) begin
                        state_next = ST_PLAY;
                    end else if (media_count == 5'd0) begin
                        state_next = ST_ERROR;
                        trap_error = 1'b1;
                        trap_code  = ERR_NO_MEDIA;
                    end else begin
                        state_next        = ST_LOAD;
                        start_load        = 1'b1;
                        target_index_next = active_index;
                        return_state_next = RET_PLAY;
                    end
                end else if ((cmd_effective == CMD_PREV) ||
                             (cmd_effective == CMD_NEXT)) begin
                    if (media_count == 5'd0) begin
                        state_next = ST_ERROR;
                        trap_error = 1'b1;
                        trap_code  = ERR_NO_MEDIA;
                    end else begin
                        state_next        = ST_LOAD;
                        start_load        = 1'b1;
                        target_index_next = (cmd_effective == CMD_PREV) ?
                                            prev_index : next_index;
                        return_state_next = state_return;
                    end
                end else if (load_request) begin
                    if (media_count == 5'd0) begin
                        state_next = ST_ERROR;
                        trap_error = 1'b1;
                        trap_code  = ERR_NO_MEDIA;
                    end else if (load_request_index >= media_count) begin
                        state_next = ST_ERROR;
                        trap_error = 1'b1;
                        trap_code  = ERR_BAD_INDEX;
                    end else begin
                        state_next        = ST_LOAD;
                        start_load        = 1'b1;
                        target_index_next = load_request_index;
                        return_state_next = state_return;
                    end
                end
            end

            ST_LOAD: begin
                if (request_timeout_hit) begin
                    state_next = ST_ERROR;
                    trap_error = 1'b1;
                    trap_code  = ERR_TIMEOUT;
                end else if (req_accepted || (req_valid && req_ready)) begin
                    if (req_error) begin
                        state_next = ST_ERROR;
                        trap_error = 1'b1;
                        trap_code  = (req_error_code != 8'd0) ?
                                     req_error_code : ERR_REQUEST;
                    end else if (req_done) begin
                        state_next = ST_TRANSITION;
                    end
                end
            end

            ST_TRANSITION: begin
                if (request_timeout_hit) begin
                    state_next = ST_ERROR;
                    trap_error = 1'b1;
                    trap_code  = ERR_TIMEOUT;
                end else if (req_accepted || (req_valid && req_ready)) begin
                    if (req_error) begin
                        state_next = ST_ERROR;
                        trap_error = 1'b1;
                        trap_code  = (req_error_code != 8'd0) ?
                                     req_error_code : ERR_REQUEST;
                    end else if (req_done) begin
                        if (transition_phase == 1'b0) begin
                            if (transition_enable) begin
                                state_next    = ST_TRANSITION;
                                advance_phase = 1'b1;
                            end else begin
                                state_next = return_state;
                                commit     = 1'b1;
                            end
                        end else begin
                            state_next = return_state;
                            commit     = 1'b1;
                        end
                    end
                end
            end

            ST_ERROR: begin
                if (recover ||
                    ((cmd_now != CMD_NONE) &&
                     media_ready && (media_count != 5'd0))) begin
                    if (media_ready && (media_count != 5'd0))
                        state_next = recover ? return_state : ST_READY;
                    else
                        state_next = ST_INIT;
                end
            end

            default: begin
                state_next = ST_RESET;
            end
        endcase
    end

    // State-driven outputs. The request bus is held valid until the target
    // asserts ready; after acceptance it drops valid and waits for done/error.
    always @(*) begin
        req_valid  = 1'b0;
        req_type   = REQ_NONE;
        req_index  = 5'd0;
        playing    = 1'b0;
        paused     = 1'b0;
        busy       = 1'b0;
        error      = 1'b0;
        hold_frame = 1'b0;

        case (state_current)
            ST_RESET: begin
                busy = 1'b1;
            end
            ST_INIT: begin
                busy       = 1'b1;
                hold_frame = frame_loaded;
            end
            ST_READY: begin
                paused = 1'b1;
            end
            ST_PLAY: begin
                playing = 1'b1;
            end
            ST_PAUSE: begin
                paused = 1'b1;
            end
            ST_LOAD: begin
                busy       = 1'b1;
                hold_frame = 1'b1;
                req_type   = REQ_LOAD;
                req_index  = target_index;
                req_valid  = !req_accepted;
            end
            ST_TRANSITION: begin
                busy       = 1'b1;
                hold_frame = 1'b1;
                req_type   = transition_phase ? REQ_TRANSITION : REQ_SWAP;
                req_valid  = !req_accepted;
            end
            ST_ERROR: begin
                error      = 1'b1;
                paused     = 1'b1;
                hold_frame = 1'b1;
            end
            default: begin
                busy = 1'b1;
            end
        endcase
    end

endmodule
