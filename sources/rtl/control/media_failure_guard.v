`timescale 1ns / 1ps
// Image failure containment / 图片故障隔离。One bounded retry, then skip a bad image.
module media_failure_guard #(
    parameter integer RECOVERY_DELAY = 500000,
    parameter integer MAX_AUTOMATIC_ATTEMPTS = 2
) (
    input wire clk,
    input wire rst_n,
    input wire error,
    input wire [7:0] error_code,
    input wire [31:0] fault_snapshot,
    input wire media_ready,
    input wire [4:0] media_count,
    input wire [4:0] failed_index,
    input wire index_commit,
    input wire permanent_error,
    input wire user_navigation,
    output wire recover,
    output wire load_valid,
    output wire [4:0] load_index,
    input wire load_accepted,
    output wire [31:0] diagnostic,
    output wire [31:0] first_snapshot
);
    localparam [1:0] IDLE = 0, WAIT_ERROR = 1, CLEAR_ERROR = 2, RELOAD = 3;
    reg [1:0] state_q, state_d;
    reg [31:0] delay_q;
    reg [7:0] error_count_q, recovery_count_q, first_error_q;
    reg [31:0] first_snapshot_q;
    reg [1:0] attempts_q;
    reg [4:0] target_q;
    reg seen_q;
    wire eligible = media_ready && media_count != 0 && attempts_q < MAX_AUTOMATIC_ATTEMPTS;
    assign recover = state_q == CLEAR_ERROR;
    assign load_valid = state_q == RELOAD && !error;
    assign load_index = target_q;
    assign diagnostic = {first_error_q,error_count_q,recovery_count_q,4'd0,attempts_q,state_q};
    assign first_snapshot = first_snapshot_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= IDLE;
        else state_q <= state_d;
    end
    always @(*) begin
        state_d = state_q;
        case (state_q)
            IDLE: if (error && !seen_q && eligible) state_d = WAIT_ERROR;
            WAIT_ERROR: if (!error) state_d = IDLE;
                        else if (delay_q >= RECOVERY_DELAY-1) state_d = CLEAR_ERROR;
            CLEAR_ERROR: state_d = RELOAD;
            RELOAD: if (load_accepted || error || user_navigation) state_d = IDLE;
            default: state_d = IDLE;
        endcase
        if (!media_ready || user_navigation) state_d = IDLE;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delay_q <= 0; error_count_q <= 0; recovery_count_q <= 0;
            first_error_q <= 0; first_snapshot_q <= 0; attempts_q <= 0;
            target_q <= 0; seen_q <= 0;
        end else begin
            seen_q <= error;
            if (state_q == WAIT_ERROR) delay_q <= delay_q + 1'b1;
            else delay_q <= 0;
            if (index_commit || user_navigation) attempts_q <= 0;
            if (error && !seen_q) begin
                if (error_count_q != 255) error_count_q <= error_count_q + 1'b1;
                if (first_error_q == 0) begin
                    first_error_q <= error_code;
                    first_snapshot_q <= fault_snapshot;
                end
                if (eligible) begin
                    // Retry once. A second failure skips to the following indexed image.
                    target_q <= attempts_q == 0 && !permanent_error ? failed_index :
                        (failed_index + 5'd1 >= media_count ? 5'd0 : failed_index + 5'd1);
                    attempts_q <= attempts_q + 1'b1;
                end
            end
            if (load_valid && load_accepted && recovery_count_q != 255)
                recovery_count_q <= recovery_count_q + 1'b1;
        end
    end
endmodule
