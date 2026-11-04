`timescale 1ns / 1ps
// Supervises the first FAT32 BPB transaction after SD-card initialization.
// A failed or stalled read resets only the C03 reader and BPB parser, leaves
// CS high for a recovery gap, and retries from sector zero. It never writes
// the card.
module media_boot_retry #(
    parameter integer BPB_TIMEOUT_CYCLES = 5000000,
    parameter integer READER_RESET_CYCLES = 32,
    parameter integer RETRY_GAP_CYCLES = 4096,
    parameter integer MAX_ATTEMPTS = 4
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sd_init_done,
    input  wire       sd_init_ok,
    input  wire       bpb_done,
    input  wire       bpb_valid,
    output reg        bpb_start,
    output reg        reader_reset,
    output reg        terminal_error,
    output reg  [2:0] attempt_count
);
    localparam [2:0] ST_WAIT_SD     = 3'd0;
    localparam [2:0] ST_REQ_BPB     = 3'd1;
    localparam [2:0] ST_WAIT_BPB    = 3'd2;
    localparam [2:0] ST_RESET_READER= 3'd3;
    localparam [2:0] ST_RETRY_GAP   = 3'd4;
    localparam [2:0] ST_DONE        = 3'd5;
    localparam [2:0] ST_ERROR       = 3'd6;

    reg [2:0]  state;
    reg [22:0] wait_count;
    reg [5:0]  reset_count;
    reg [15:0] gap_count;
    reg [2:0]  failures;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_WAIT_SD;
            wait_count     <= 23'd0;
            reset_count    <= 6'd0;
            gap_count      <= 16'd0;
            failures       <= 3'd0;
            bpb_start      <= 1'b0;
            reader_reset   <= 1'b0;
            terminal_error <= 1'b0;
            attempt_count  <= 3'd0;
        end else begin
            bpb_start <= 1'b0;

            case (state)
                ST_WAIT_SD: begin
                    wait_count <= 23'd0;
                    if (sd_init_done) begin
                        if (sd_init_ok) begin
                            attempt_count <= 3'd1;
                            state <= ST_REQ_BPB;
                        end else begin
                            terminal_error <= 1'b1;
                            state <= ST_ERROR;
                        end
                    end
                end

                ST_REQ_BPB: begin
                    bpb_start  <= 1'b1;
                    wait_count <= 23'd0;
                    state      <= ST_WAIT_BPB;
                end

                ST_WAIT_BPB: begin
                    wait_count <= wait_count + 1'b1;
                    if (bpb_done && bpb_valid) begin
                        state <= ST_DONE;
                    end else if (bpb_done ||
                                 (wait_count >= BPB_TIMEOUT_CYCLES - 1)) begin
                        failures <= failures + 1'b1;
                        if ((failures + 1'b1) >= MAX_ATTEMPTS) begin
                            terminal_error <= 1'b1;
                            state <= ST_ERROR;
                        end else begin
                            reader_reset <= 1'b1;
                            reset_count  <= READER_RESET_CYCLES - 1;
                            state        <= ST_RESET_READER;
                        end
                    end
                end

                ST_RESET_READER: begin
                    if (reset_count == 6'd0) begin
                        reader_reset <= 1'b0;
                        gap_count    <= 16'd0;
                        state        <= ST_RETRY_GAP;
                    end else begin
                        reset_count <= reset_count - 1'b1;
                    end
                end

                ST_RETRY_GAP: begin
                    gap_count <= gap_count + 1'b1;
                    if (gap_count >= RETRY_GAP_CYCLES - 1) begin
                        attempt_count <= attempt_count + 1'b1;
                        state <= ST_REQ_BPB;
                    end
                end

                ST_DONE: begin
                    reader_reset <= 1'b0;
                end

                ST_ERROR: begin
                    reader_reset   <= 1'b0;
                    terminal_error <= 1'b1;
                end

                default: state <= ST_WAIT_SD;
            endcase
        end
    end
endmodule
