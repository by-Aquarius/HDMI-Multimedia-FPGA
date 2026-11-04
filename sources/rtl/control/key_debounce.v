// -----------------------------------------------------------------------------
// key_debounce.v
// B02: debounce the one-hot raw_key level produced by B01.
//
// The entire 16-bit vector is debounced as one state. This preserves B01's
// single-key contract and prevents a changing scan result from creating a
// false key event. The output changes only after raw_key has remained unchanged
// for STABLE_CYCLES consecutive clk_50m cycles.
// -----------------------------------------------------------------------------
module key_debounce #(
    parameter integer STABLE_CYCLES = 1000000
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire [15:0] raw_key,
    output reg  [15:0] key_down
);

    reg [15:0] candidate_key;
    reg [31:0] stable_count;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            candidate_key <= 16'h0000;
            stable_count  <= 32'd0;
            key_down      <= 16'h0000;
        end else begin
            if (raw_key != candidate_key) begin
                // A new raw state starts a fresh qualification interval.
                candidate_key <= raw_key;
                stable_count  <= 32'd0;
            end else if (candidate_key == key_down) begin
                // Already-qualified state: no further work is required.
                stable_count <= 32'd0;
            end else if (STABLE_CYCLES <= 1) begin
                key_down     <= candidate_key;
                stable_count <= 32'd0;
            end else if (stable_count >= STABLE_CYCLES - 1) begin
                key_down     <= candidate_key;
                stable_count <= 32'd0;
            end else begin
                stable_count <= stable_count + 1'b1;
            end
        end
    end

endmodule

