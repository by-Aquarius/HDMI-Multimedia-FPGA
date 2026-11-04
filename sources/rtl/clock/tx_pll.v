`timescale 1ns/1ps
// Exact CEA720p clocks / 标准720p时钟树。
// 50 -> 27 MHz (VCO675), then 27 -> 74.25/371.25 MHz (VCO742.5).
// Both phase detectors stay above the device's 10 MHz lower limit.
module tx_pll (
    input wire refclk,
    input wire reset,
    output wire extlock,
    output wire clk0_out,
    output wire clk1_out,
    output wire clk2_out,
    output wire [1:0] clock_locks
);
    wire reference_clock,feedback_reference,feedback_video_raw,feedback_video;
    wire reference_locked,video_locked;
    wire [2:0] reference_unused;
    wire [1:0] video_unused;
    reg reference_meta,reference_sync;
    reg [5:0] reference_stable;
    wire video_reset=reset || !reference_locked || !reference_stable[5];
    assign extlock=reference_locked && video_locked;
    assign clock_locks={video_locked,reference_locked};
    EG_LOGIC_BUFG reference_feedback_buffer(.i(feedback_reference),.o(clk0_out));
    EG_LOGIC_BUFG video_feedback_buffer(.i(feedback_video_raw),.o(feedback_video));
    always @(posedge refclk or posedge reset) begin
        if(reset)begin reference_meta<=0;reference_sync<=0;reference_stable<=0;end
        else begin
            reference_meta<=reference_locked;reference_sync<=reference_meta;
            if(!reference_sync)reference_stable<=0;
            else if(!reference_stable[5])reference_stable<=reference_stable+1'b1;
        end
    end
    EG_PHY_PLL #(
        .FIN("50.000"),.REFCLK_DIV(2),.FBCLK_DIV(1),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),
        .PLLRST_ENA("ENABLE"),.STDBY_ENABLE("DISABLE"),
        .DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),
        .SYNC_ENABLE("DISABLE"),.DERIVE_PLL_CLOCKS("DISABLE"),.GEN_BASIC_CLOCK("DISABLE"),
        .GMC_GAIN(2),.ICP_CURRENT(9),.KVCO(2),.LPF_CAPACITOR(1),.LPF_RESISTOR(8),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(27),.CLKC0_CPHASE(26),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(25),.CLKC1_CPHASE(24),.CLKC1_FPHASE(0)
    ) reference_pll (
        .refclk(refclk),.reset(reset),.stdby(1'b0),.fbclk(clk0_out),
        .extlock(reference_locked),.clkc({reference_unused,reference_clock,feedback_reference}),
        .load_reg(1'b0),.psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'd0),.psdone(),
        .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'd0),.daddr(6'd0),.do()
    );
    EG_PHY_PLL #(
        .FIN("27.000"),.REFCLK_DIV(2),.FBCLK_DIV(5),
        .FEEDBK_MODE("NORMAL"),.FEEDBK_PATH("CLKC0_EXT"),
        .PLLRST_ENA("ENABLE"),.STDBY_ENABLE("DISABLE"),
        .DPHASE_SOURCE("DISABLE"),.DYNCFG("DISABLE"),
        .SYNC_ENABLE("DISABLE"),.DERIVE_PLL_CLOCKS("DISABLE"),.GEN_BASIC_CLOCK("DISABLE"),
        .GMC_GAIN(2),.ICP_CURRENT(9),.KVCO(2),.LPF_CAPACITOR(1),.LPF_RESISTOR(8),
        .CLKC0_ENABLE("ENABLE"),.CLKC0_DIV(11),.CLKC0_CPHASE(10),.CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),.CLKC1_DIV(10),.CLKC1_CPHASE(9),.CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),.CLKC2_DIV(2),.CLKC2_CPHASE(1),.CLKC2_FPHASE(0)
    ) video_pll (
        .refclk(reference_clock),.reset(video_reset),.stdby(1'b0),.fbclk(feedback_video),
        .extlock(video_locked),.clkc({video_unused,clk2_out,clk1_out,feedback_video_raw}),
        .load_reg(1'b0),.psclk(1'b0),.psdown(1'b0),.psstep(1'b0),.psclksel(3'd0),.psdone(),
        .dclk(1'b0),.dcs(1'b0),.dwe(1'b0),.di(8'd0),.daddr(6'd0),.do()
    );
endmodule
