`timescale 1ns/1ps
// Sample-driven program scheduler. Control and PCM observations share 50 MHz.
// Actual frame commits acknowledge explicit loads; no image data crosses here.
module program_timeline #(
    parameter integer SAMPLE_HZ = 48000
) (
    input wire clk,
    input wire rst_n,
    input wire mode_key,
    input wire suspend,
    input wire pause_key,
    input wire manual_key,
    input wire media_ready,
    input wire [4:0] media_count,
    input wire [4:0] audio_count,
    input wire media_busy,
    input wire media_error,
    input wire index_commit,
    input wire prefetch_ready,
    input wire pcm_valid,
    input wire pcm_underrun,
    input wire track_done,
    input wire audio_error,
    output wire enabled,
    output wire priming,
    output wire paused,
    output wire stalled,
    output wire ended,
    output wire load_valid,
    output wire [4:0] load_index,
    output wire swap_allowed,
    output wire audio_restart,
    output wire [1:0] scene,
    output wire [2:0] caption,
    output wire highlight,
    output wire [6:0] seconds
);
    localparam [2:0] ST_OFF = 3'd0;
    localparam [2:0] ST_START = 3'd1;
    localparam [2:0] ST_FIRST = 3'd2;
    localparam [2:0] ST_PLAY = 3'd3;
    localparam [2:0] ST_NEXT = 3'd4;
    localparam [2:0] ST_DONE = 3'd5;

    reg [2:0] state_q;
    reg [2:0] state_d;
    reg paused_q;
    reg [1:0] scene_q;
    reg [6:0] seconds_q;
    reg [15:0] fraction_q;
    reg [6:0] next_cue_q;
    reg prefetch_complete_q;
    wire enter_allowed = media_ready && !media_busy && !media_error &&
                         (media_count != 0) && (audio_count != 0);
    wire more_images = (scene_q != 3) && ({3'd0, scene_q} + 5'd1 < media_count);
    wire cue_due = (seconds_q >= next_cue_q);
    wire active_time = (state_q == ST_PLAY) || (state_q == ST_NEXT);
    // The request valid drops after SWAP acceptance. Remember loaded data so
    // the normal wait for vertical blank never pauses a continuous soundtrack.
    wire waiting_data = (state_q == ST_NEXT) && cue_due &&
                        !prefetch_ready && !prefetch_complete_q;
    wire finish_now = active_time && (track_done || audio_error);
    wire [6:0] caption_midpoint = {2'd0, scene_q, 3'b100};
    wire [6:0] emphasis_start = {2'd0, scene_q, 3'b110};

    assign enabled = (state_q != ST_OFF);
    assign priming = (state_q == ST_START) || (state_q == ST_FIRST);
    assign paused = paused_q;
    assign stalled = waiting_data;
    assign ended = (state_q == ST_DONE);
    assign load_valid = ((state_q == ST_START) ||
                         ((state_q == ST_PLAY) && more_images)) &&
                        !media_busy && !media_error && !finish_now && !suspend;
    assign load_index = (state_q == ST_START) ? 5'd0 : {3'd0, scene_q} + 5'd1;
    assign swap_allowed = !suspend && (priming ||
                          ((state_q == ST_NEXT) && cue_due && !paused_q && !finish_now));
    assign audio_restart = (state_q == ST_FIRST) && index_commit;
    assign scene = scene_q;
    assign caption = {scene_q, (seconds_q >= caption_midpoint)};
    assign highlight = active_time && (seconds_q >= emphasis_start);
    assign seconds = seconds_q;

    // State register: mode changes never reset or fabricate a frame transaction.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= ST_OFF;
        else state_q <= state_d;
    end

    // An explicit load is accepted by the idle media controller on this edge.
    always @(*) begin
        state_d = state_q;
        case (state_q)
            ST_OFF: if (mode_key && enter_allowed) state_d = ST_START;
            ST_START: if (load_valid) state_d = ST_FIRST;
            ST_FIRST: if (index_commit) state_d = ST_PLAY;
            ST_PLAY: if (load_valid) state_d = ST_NEXT;
            ST_NEXT: if (index_commit) state_d = ST_PLAY;
            ST_DONE: state_d = ST_DONE;
            default: state_d = ST_OFF;
        endcase
        if (enabled && (mode_key || manual_key)) state_d = ST_OFF;
        else if (enabled && (media_error || !media_ready || finish_now)) state_d = ST_DONE;
    end

    // PCM consumption is the master clock: volume and wall-clock pauses do not
    // move the schedule. Underrun silence is excluded from source-media time.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            paused_q <= 1'b0;
            scene_q <= 0;
            seconds_q <= 0;
            fraction_q <= 0;
            next_cue_q <= 7'd8;
            prefetch_complete_q <= 1'b0;
        end else if (state_q == ST_OFF) begin
            paused_q <= 1'b0;
            scene_q <= 0;
            seconds_q <= 0;
            fraction_q <= 0;
            next_cue_q <= 7'd8;
            prefetch_complete_q <= 1'b0;
        end else begin
            if (state_q == ST_PLAY) prefetch_complete_q <= 1'b0;
            else if ((state_q == ST_NEXT) && prefetch_ready) prefetch_complete_q <= 1'b1;
            if (pause_key) paused_q <= !paused_q;
            if ((state_q == ST_NEXT) && index_commit) begin
                scene_q <= scene_q + 1'b1;
                next_cue_q <= next_cue_q + 7'd8;
            end
            if (active_time && pcm_valid && !pcm_underrun &&
                !paused_q && !waiting_data && !finish_now && !suspend) begin
                if (fraction_q == SAMPLE_HZ - 1) begin
                    fraction_q <= 0;
                    if (seconds_q < 99) seconds_q <= seconds_q + 1'b1;
                end else fraction_q <= fraction_q + 1'b1;
            end
        end
    end
endmodule
