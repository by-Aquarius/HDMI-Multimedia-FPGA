// -----------------------------------------------------------------------------
// timer_ms.v
// E02: programmable millisecond one-shot timer.
//
// The period is sampled only when restart is pulsed. Disabling enable freezes
// elapsed_ms and the cycle counter, which gives pause/resume semantics without
// resetting the remaining slideshow interval.
// -----------------------------------------------------------------------------
module timer_ms #(
    parameter integer CLK_HZ = 50000000,
    parameter integer TICK_HZ = 1000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        restart,
    input  wire [31:0] period_ms,
    output reg         busy,
    output reg         done,
    output reg  [31:0] elapsed_ms
);

    localparam integer CYCLES_PER_MS = (TICK_HZ > 0) ?
                                       ((CLK_HZ + TICK_HZ - 1) / TICK_HZ) : 1;

    reg [31:0] cycle_count;
    reg [31:0] period_latched;
    wire       ms_tick = (cycle_count >= (CYCLES_PER_MS - 1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            elapsed_ms     <= 32'd0;
            cycle_count    <= 32'd0;
            period_latched <= 32'd0;
        end else if (restart) begin
            busy           <= 1'b1;
            done           <= 1'b0;
            elapsed_ms     <= 32'd0;
            cycle_count    <= 32'd0;
            period_latched <= period_ms;
        end else begin
            done <= 1'b0;
            if (enable && busy) begin
                if (ms_tick) begin
                    cycle_count <= 32'd0;
                    if ((elapsed_ms + 32'd1) >= period_latched) begin
                        elapsed_ms <= period_latched;
                        done       <= 1'b1;
                        busy       <= 1'b0;
                    end else begin
                        elapsed_ms <= elapsed_ms + 32'd1;
                    end
                end else begin
                    cycle_count <= cycle_count + 32'd1;
                end
            end
        end
    end

endmodule
