// -----------------------------------------------------------------------------
// key_event.v
// B02: convert debounced key_down levels into one-shot and long-press events.
//
// key_pulse: one clk_50m pulse when a new non-zero key_down is observed.
// key_long : one clk_50m pulse after LONG_START_CYCLES of continuous hold and
//            then every LONG_REPEAT_CYCLES cycles while the same key remains.
//
// B01 guarantees at most one bit in key_down. If the input changes directly
// from one key to another, the new key is treated as a new press.
// -----------------------------------------------------------------------------
module key_event #(
    parameter integer LONG_START_CYCLES  = 25000000,
    parameter integer LONG_REPEAT_CYCLES = 5000000
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire [15:0] key_down,
    output reg  [15:0] key_pulse,
    output reg  [15:0] key_long
);

    reg [15:0] previous_key;
    reg [31:0] hold_count;
    reg [31:0] repeat_count;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            previous_key <= 16'h0000;
            hold_count   <= 32'd0;
            repeat_count <= 32'd0;
            key_pulse    <= 16'h0000;
            key_long     <= 16'h0000;
        end else begin
            // Both outputs are pulses, never levels.
            key_pulse <= 16'h0000;
            key_long  <= 16'h0000;

            if (key_down == 16'h0000) begin
                previous_key <= 16'h0000;
                hold_count   <= 32'd0;
                repeat_count <= 32'd0;
            end else if (key_down != previous_key) begin
                // New key press, including a direct key-to-key transition.
                previous_key <= key_down;
                hold_count   <= 32'd0;
                repeat_count <= 32'd0;
                key_pulse    <= key_down;
            end else if (LONG_START_CYCLES <= 1) begin
                // Parameter corner case: long repeat is enabled immediately.
                key_long <= key_down;
                if (LONG_REPEAT_CYCLES <= 1)
                    repeat_count <= 32'd0;
                else if (repeat_count >= LONG_REPEAT_CYCLES - 1)
                    repeat_count <= 32'd0;
                else
                    repeat_count <= repeat_count + 1'b1;
            end else if (hold_count < LONG_START_CYCLES - 1) begin
                hold_count <= hold_count + 1'b1;
            end else if (LONG_REPEAT_CYCLES <= 1) begin
                // Emit every cycle after the long-press threshold.
                key_long   <= key_down;
                hold_count <= hold_count;
            end else if (repeat_count >= LONG_REPEAT_CYCLES - 1) begin
                key_long     <= key_down;
                repeat_count <= 32'd0;
            end else begin
                repeat_count <= repeat_count + 1'b1;
            end
        end
    end

endmodule

