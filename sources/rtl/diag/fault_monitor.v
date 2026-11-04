`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// fault_monitor.v
// G04 status aggregator: no-card / bad BPB / bad BMP / bad WAV / timeout /
// retry / watchdog / PLL-unlock status.
//
// The PLL-unlock sticky flag lives in the always-running 50 MHz reference
// domain and is reset only by rst_ref_n (the power-on counter), so it survives
// the PLL-induced design reset and is visible after the design re-locks.
// -----------------------------------------------------------------------------
module fault_monitor #(
    parameter integer WATCHDOG_CYCLES = 75000000  // 3 s at 25 MHz
) (
    input  wire        clk_ctrl,
    input  wire        rst_ctrl_n,
    input  wire        clk_ref,
    input  wire        rst_ref_n,
    input  wire        pll_locked,

    input  wire        no_card,
    input  wire        bad_bpb,
    input  wire        bad_bmp,
    input  wire        bad_wav,
    input  wire        timeout_event,
    input  wire        retry_event,
    input  wire        busy,
    input  wire        progress,

    output reg         pll_unlock_seen,   // reference-domain sticky
    output wire        pll_unlock_ctrl,   // synchronized into the ctrl domain
    output reg         watchdog_seen,
    output reg         timeout_seen,
    output reg         retry_seen,
    output reg  [7:0]  retry_count,
    output wire [7:0]  status_flags,
    output wire        stable
);

    // -------------------------------------------------------------------------
    // PLL monitor: reference clock is always running while the FPGA is
    // configured. rst_ref_n is the power-on counter, not pll_locked.
    // -------------------------------------------------------------------------
    reg pll_locked_s1;
    reg pll_locked_s2;
    reg pll_locked_high;

    always @(posedge clk_ref or negedge rst_ref_n) begin
        if (!rst_ref_n) begin
            pll_locked_s1   <= 1'b0;
            pll_locked_s2   <= 1'b0;
            pll_locked_high <= 1'b0;
            pll_unlock_seen <= 1'b0;
        end else begin
            pll_locked_s1 <= pll_locked;
            pll_locked_s2 <= pll_locked_s1;
            if (pll_locked_s2)
                pll_locked_high <= 1'b1;
            else if (pll_locked_high)
                pll_unlock_seen <= 1'b1;
        end
    end

    // Synchronize the sticky reference-domain flag into the control domain.
    reg pll_unlock_s1;
    reg pll_unlock_s2;

    always @(posedge clk_ctrl or negedge rst_ctrl_n) begin
        if (!rst_ctrl_n) begin
            pll_unlock_s1 <= 1'b0;
            pll_unlock_s2 <= 1'b0;
        end else begin
            pll_unlock_s1 <= pll_unlock_seen;
            pll_unlock_s2 <= pll_unlock_s1;
        end
    end

    assign pll_unlock_ctrl = pll_unlock_s2;

    // -------------------------------------------------------------------------
    // Timeout / retry / watchdog status in the control domain.
    // -------------------------------------------------------------------------
    reg [31:0] watchdog_count;

    always @(posedge clk_ctrl or negedge rst_ctrl_n) begin
        if (!rst_ctrl_n) begin
            watchdog_seen  <= 1'b0;
            watchdog_count <= 32'd0;
            timeout_seen   <= 1'b0;
            retry_seen     <= 1'b0;
            retry_count    <= 8'd0;
        end else begin
            if (timeout_event)
                timeout_seen <= 1'b1;

            if (retry_event) begin
                retry_seen <= 1'b1;
                if (retry_count != 8'hFF)
                    retry_count <= retry_count + 1'b1;
            end

            // The watchdog is a no-progress detector. Slow SD reads are valid
            // as long as sectors, bytes or pixels continue to advance.
            if (progress) begin
                watchdog_count <= 32'd0;
            end else if (busy) begin
                if (watchdog_count >= WATCHDOG_CYCLES - 1) begin
                    watchdog_seen  <= 1'b1;
                    watchdog_count <= 32'd0;
                end else begin
                    watchdog_count <= watchdog_count + 1'b1;
                end
            end else begin
                watchdog_count <= 32'd0;
            end
        end
    end

    // Bit 7: PLL unlock, 6: watchdog, 5: timeout, 4: retry,
    // 3: bad WAV, 2: bad BMP, 1: bad BPB, 0: no card.
    assign status_flags = {pll_unlock_s2, watchdog_seen, timeout_seen,
                           retry_seen, bad_wav, bad_bmp, bad_bpb, no_card};

    // A bad WAV or a bad image does not stop the HDMI main path; PLL unlock
    // and a watchdog timeout do.
    assign stable = !(pll_unlock_s2 | watchdog_seen);

endmodule
