`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// e_media_request_ctrl.v
// E-video integration request controller.
//
// Converts the unified E01 request bus into the R181 storage/frame operations:
//   LOAD       -> select one indexed BMP and wait for the back frame to finish
//   SWAP       -> request a frame-boundary swap and wait for its acknowledge
//   TRANSITION -> wait for the fade-through-black animation to finish
//
// The controller owns the request handshake only. It does not read the TF card,
// decode BMP data, write SDRAM, or alter HDMI timing.
// -----------------------------------------------------------------------------
module e_media_request_ctrl #(
    parameter integer REQUEST_TIMEOUT_CYCLES = 125000000,
    parameter integer LOAD_RETRY_MAX = 4,
    parameter integer LOAD_RETRY_GAP_CYCLES = 250000,
    parameter [1:0] REQ_LOAD      = 2'd1,
    parameter [1:0] REQ_SWAP      = 2'd2,
    parameter [1:0] REQ_TRANSITION = 2'd3,
    parameter [7:0] ERR_NO_MEDIA  = 8'hE1,
    parameter [7:0] ERR_BAD_INDEX = 8'hE2,
    parameter [7:0] ERR_REQUEST   = 8'hE3,
    parameter [7:0] ERR_TIMEOUT   = 8'hE4,
    parameter [7:0] ERR_PIPELINE  = 8'hE5
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        media_ready,
    input  wire [4:0]  media_count,

    input  wire        req_valid,
    input  wire [1:0]  req_type,
    input  wire [4:0]  req_index,
    output reg         req_ready,
    output reg         req_done,
    output reg         req_error,
    output reg  [7:0]  req_error_code,

    output reg         load_start,
    output reg  [4:0]  load_index,
    output reg         swap_request,

    input  wire        load_done,
    input  wire        load_error,
    input wire permanent_media_error,
    input  wire        load_timeout,
    input  wire        swap_ack,
    input  wire        transition_enable,
    input  wire        transition_done,
    input  wire [7:0]  pipeline_error_code,

    output wire [3:0] debug_status,
    output wire        busy
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_LOAD_START = 3'd1;
    localparam [2:0] ST_LOAD_WAIT = 3'd2;
    localparam [2:0] ST_SWAP_WAIT = 3'd3;
    localparam [2:0] ST_TRANSITION_WAIT = 3'd4;
    localparam [2:0] ST_LOAD_RETRY = 3'd5;

    reg [2:0]  state;
    reg [31:0] request_timer;
    reg [31:0] load_retry_timer;
    reg [3:0]  load_retry_count;
    reg [2:0]  error_ignore;
    reg        transition_complete;

    wire request_timeout_hit = (REQUEST_TIMEOUT_CYCLES > 0) &&
                               (request_timer >= REQUEST_TIMEOUT_CYCLES - 1);

    assign debug_status = {transition_complete,state};
    assign busy = (state != ST_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            request_timer    <= 32'd0;
            load_retry_timer <= 32'd0;
            load_retry_count <= 4'd0;
            error_ignore     <= 3'd0;
            transition_complete <= 1'b0;
            req_ready        <= 1'b1;
            req_done         <= 1'b0;
            req_error        <= 1'b0;
            req_error_code   <= 8'd0;
            load_start       <= 1'b0;
            load_index       <= 5'd0;
            swap_request     <= 1'b0;
        end else begin
            req_done     <= 1'b0;
            req_error    <= 1'b0;
            load_start   <= 1'b0;
            swap_request <= 1'b0;
            // Animation starts with LOAD. Preserve a completion that arrives
            // before its later request, and consume it only once.
            if (transition_done)
                transition_complete <= 1'b1;

            if (state == ST_IDLE) begin
                request_timer <= 32'd0;
                load_retry_timer <= 32'd0;
                load_retry_count <= 4'd0;
                error_ignore  <= 3'd0;
                req_ready     <= 1'b1;
                if (req_valid) begin
                    req_ready <= 1'b0;
                    if (!media_ready || (media_count == 5'd0)) begin
                        req_error      <= 1'b1;
                        req_error_code <= ERR_NO_MEDIA;
                    end else if (req_index >= media_count) begin
                        req_error      <= 1'b1;
                        req_error_code <= ERR_BAD_INDEX;
                    end else begin
                        case (req_type)
                            REQ_LOAD: begin
                                transition_complete <= 1'b0;
                                load_index <= req_index;
                                state      <= ST_LOAD_START;
                            end
                            REQ_SWAP: begin
                                swap_request <= 1'b1;
                                state        <= ST_SWAP_WAIT;
                            end
                            REQ_TRANSITION: begin
                                if (transition_enable &&
                                    !transition_complete && !transition_done)
                                    state <= ST_TRANSITION_WAIT;
                                else begin
                                    transition_complete <= 1'b0;
                                    req_done <= 1'b1;
                                    req_ready <= 1'b1;
                                end
                            end
                            default: begin
                                req_error      <= 1'b1;
                                req_error_code <= ERR_REQUEST;
                            end
                        endcase
                    end
                end
            end else begin
                req_ready     <= 1'b0;
                request_timer <= request_timer + 1'b1;

                case (state)
                    ST_LOAD_START: begin
                        load_start <= 1'b1;
                        error_ignore <= 3'd7;
                        state      <= ST_LOAD_WAIT;
                    end

                    ST_LOAD_WAIT: begin
                        if (error_ignore != 3'd0)
                            error_ignore <= error_ignore - 1'b1;
                        if (load_done && !load_error &&
                            ((pipeline_error_code == 8'd0) ||
                             (error_ignore != 3'd0))) begin
                            req_done <= 1'b1;
                            state    <= ST_IDLE;
                        end else if (load_error || load_timeout ||
                                     ((pipeline_error_code != 8'd0) &&
                                      (error_ignore == 3'd0))) begin
                            if (load_retry_count < LOAD_RETRY_MAX && !permanent_media_error) begin
                                load_retry_count <= load_retry_count + 1'b1;
                                load_retry_timer <= 32'd0;
                                request_timer    <= 32'd0;
                                state            <= ST_LOAD_RETRY;
                            end else begin
                                req_error      <= 1'b1;
                                req_error_code <= (pipeline_error_code != 8'd0) ?
                                                  pipeline_error_code : ERR_PIPELINE;
                                state          <= ST_IDLE;
                            end
                        end else if (request_timeout_hit) begin
                            if (load_retry_count < LOAD_RETRY_MAX && !permanent_media_error) begin
                                load_retry_count <= load_retry_count + 1'b1;
                                load_retry_timer <= 32'd0;
                                request_timer    <= 32'd0;
                                state            <= ST_LOAD_RETRY;
                            end else begin
                                req_error      <= 1'b1;
                                req_error_code <= ERR_TIMEOUT;
                                state          <= ST_IDLE;
                            end
                        end
                    end

                    ST_LOAD_RETRY: begin
                        load_retry_timer <= load_retry_timer + 1'b1;
                        request_timer    <= 32'd0;
                        if (load_retry_timer >= LOAD_RETRY_GAP_CYCLES - 1) begin
                            load_retry_timer <= 32'd0;
                            state            <= ST_LOAD_START;
                        end
                    end

                    ST_SWAP_WAIT: begin
                        if (swap_ack) begin
                            req_done <= 1'b1;
                            state    <= ST_IDLE;
                        end else if (request_timeout_hit) begin
                            req_error      <= 1'b1;
                            req_error_code <= ERR_TIMEOUT;
                            state          <= ST_IDLE;
                        end
                    end

                    ST_TRANSITION_WAIT: begin
                        if (transition_done || transition_complete) begin
                            transition_complete <= 1'b0;
                            req_done <= 1'b1;
                            state    <= ST_IDLE;
                        end else if (pipeline_error_code != 8'd0) begin
                            req_error      <= 1'b1;
                            req_error_code <= pipeline_error_code;
                            state          <= ST_IDLE;
                        end else if (request_timeout_hit) begin
                            req_error      <= 1'b1;
                            req_error_code <= ERR_TIMEOUT;
                            state          <= ST_IDLE;
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
