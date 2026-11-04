// -----------------------------------------------------------------------------
// key_matrix_scan.v
//
// Independent 4x4 matrix-key scanner for the DMZ_EG4S20 board.
//
// Electrical convention from the hardwood-classroom board:
//   * one row is driven LOW at a time;
//   * columns are pulled HIGH when no key is pressed;
//   * a pressed key pulls the selected column LOW.
//
// Canonical logical mapping:
//   key_row[0] = E10 -> raw_key[3:0]
//   key_row[1] = C10 -> raw_key[7:4]
//   key_row[2] = F9  -> raw_key[11:8]
//   key_row[3] = D9  -> raw_key[15:12]
//   key_col[0]..[3] map to the corresponding bit inside each 4-bit group.
//
// The module reports at most one key. If more than one column is LOW in the
// currently active row, the lowest logical column index wins. Once a key is
// latched, it remains the only reported key until that key is observed released.
// Debounce and key-event generation are intentionally outside this B01 module.
// -----------------------------------------------------------------------------
module key_matrix_scan #(
    parameter integer SCAN_DIV = 25000
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire [3:0]  key_col,
    output reg  [3:0]  key_row,
    output reg [15:0]  raw_key
);

    reg [31:0] div_count;
    reg [1:0]  row_index;
    reg        key_locked;
    reg        key_seen_in_frame;
    reg [1:0]  locked_row;
    reg [1:0]  locked_col;

    reg        candidate_valid;
    reg [1:0]  candidate_col;
    reg [15:0] candidate_mask;

    // Lowest column index has priority when more than one column is LOW.
    always @* begin
        candidate_valid = 1'b0;
        candidate_col   = 2'd0;

        if (!key_col[0]) begin
            candidate_valid = 1'b1;
            candidate_col   = 2'd0;
        end else if (!key_col[1]) begin
            candidate_valid = 1'b1;
            candidate_col   = 2'd1;
        end else if (!key_col[2]) begin
            candidate_valid = 1'b1;
            candidate_col   = 2'd2;
        end else if (!key_col[3]) begin
            candidate_valid = 1'b1;
            candidate_col   = 2'd3;
        end

        candidate_mask = 16'h0000;
        if (candidate_valid)
            candidate_mask = 16'h0001 << ({row_index, 2'b00} + candidate_col);
    end

    // One active-low row at a time. The row output remains stable for SCAN_DIV
    // input-clock cycles, giving the external matrix time to settle.
    always @* begin
        case (row_index)
            2'd0: key_row = 4'b1110;
            2'd1: key_row = 4'b1101;
            2'd2: key_row = 4'b1011;
            default: key_row = 4'b0111;
        endcase
    end

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            div_count          <= 32'd0;
            row_index          <= 2'd0;
            raw_key            <= 16'h0000;
            key_locked         <= 1'b0;
            key_seen_in_frame  <= 1'b0;
            locked_row         <= 2'd0;
            locked_col         <= 2'd0;
        end else begin
            if ((SCAN_DIV <= 1) || (div_count >= SCAN_DIV - 1)) begin
                div_count <= 32'd0;

                if (!key_locked) begin
                    if (candidate_valid) begin
                        key_locked        <= 1'b1;
                        key_seen_in_frame <= 1'b1;
                        locked_row        <= row_index;
                        locked_col        <= candidate_col;
                        raw_key           <= candidate_mask;
                    end else begin
                        raw_key <= 16'h0000;
                    end
                end else begin
                    // Only the latched key is considered while locked. This
                    // prevents multiple simultaneous keys from becoming a
                    // multi-bit raw_key and gives B02 a single-key input.
                    if ((row_index == locked_row) && !key_col[locked_col])
                        key_seen_in_frame <= 1'b1;

                    // At the end of a complete four-row frame, release the
                    // latch only if the latched key was not observed.
                    if (row_index == 2'd3) begin
                        if (key_seen_in_frame ||
                            ((row_index == locked_row) && !key_col[locked_col])) begin
                            key_seen_in_frame <= 1'b0;
                        end else begin
                            key_locked        <= 1'b0;
                            raw_key           <= 16'h0000;
                            key_seen_in_frame <= 1'b0;
                        end
                    end
                end

                if (row_index == 2'd3)
                    row_index <= 2'd0;
                else
                    row_index <= row_index + 1'b1;
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end

endmodule
