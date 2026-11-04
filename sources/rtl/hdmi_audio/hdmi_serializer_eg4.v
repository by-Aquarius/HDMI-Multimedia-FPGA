`timescale 1ns / 1ps
// EG4 10:1 TMDS serializer. The fabric shifts two bits per 5x pixel clock and
// the output PAD DDR register produces the final 10x TMDS bit rate.
module hdmi_serializer_eg4 (
    input  wire clk_pixel,
    input  wire clk_serial,
    input  wire reset,
    input  wire [9:0] tmds_internal_0,
    input  wire [9:0] tmds_internal_1,
    input  wire [9:0] tmds_internal_2,
    output wire hdmi_clk_p,
    output wire hdmi_d0_p,
    output wire hdmi_d1_p,
    output wire hdmi_d2_p
);
    reg [9:0] tmds_shift_0;
    reg [9:0] tmds_shift_1;
    reg [9:0] tmds_shift_2;
    reg [9:0] shift_clock;
    reg       pixel_clk_sync1;
    reg       pixel_clk_sync2;
    reg       serial_reset_meta = 1'b1;
    reg       serial_reset_sync = 1'b1;
    reg       phase_locked;
    reg       marker_armed;
    reg [3:0] acquire_settle;
    reg       acquire_pulse;
    reg [4:0] pair_phase;
    wire      pixel_clk_edge = pixel_clk_sync1 & ~pixel_clk_sync2;
    wire      pixel_clk_load = pair_phase[0];

    // Assert reset immediately, then release it on this domain's own edges.
    always @(posedge clk_serial or posedge reset) begin
        if (reset) begin
            serial_reset_meta <= 1'b1;
            serial_reset_sync <= 1'b1;
        end else begin
            serial_reset_meta <= 1'b0;
            serial_reset_sync <= serial_reset_meta;
        end
    end

    always @(posedge clk_serial) begin
        if (serial_reset_sync) begin
            pixel_clk_sync1 <= 1'b0;
            pixel_clk_sync2 <= 1'b0;
        end else begin
            pixel_clk_sync1 <= clk_pixel;
            pixel_clk_sync2 <= pixel_clk_sync1;
        end
    end

    // Register marker qualification separately from phase seeding. Each fast
    // control path then has one LUT or less. A one-hot ring fixes every later
    // character boundary independently of marker jitter.
    always @(posedge clk_serial) begin
        if (serial_reset_sync) begin
            phase_locked <= 1'b0;
            marker_armed <= 1'b0;
            acquire_settle <= 4'b0000;
            acquire_pulse <= 1'b0;
            pair_phase <= 5'b00000;
        end else begin
            acquire_settle <= {acquire_settle[2:0], 1'b1};
            marker_armed <= marker_armed || (acquire_settle[3] && !pixel_clk_sync2);
            acquire_pulse <= marker_armed && pixel_clk_edge;
            phase_locked <= phase_locked || acquire_pulse;
            pair_phase[0] <= phase_locked ? pair_phase[4] : acquire_pulse;
            pair_phase[4:1] <= pair_phase[3:0];
        end
    end

    // EG_LOGIC_ODDR samples both d0 and d1 on the rising edge, then emits d0
    // during the high phase and d1 during the low phase. Because both inputs
    // are sampled before this nonblocking shift advances, they always represent
    // one stable two-bit pair from the same TMDS word.
    always @(posedge clk_serial) begin
        if (serial_reset_sync) begin
            tmds_shift_0 <= 10'd0;
            tmds_shift_1 <= 10'd0;
            tmds_shift_2 <= 10'd0;
            shift_clock <= 10'd0;
        end else begin
            tmds_shift_0 <= pixel_clk_load ? tmds_internal_0 : tmds_shift_0[9:2];
            tmds_shift_1 <= pixel_clk_load ? tmds_internal_1 : tmds_shift_1[9:2];
            tmds_shift_2 <= pixel_clk_load ? tmds_internal_2 : tmds_shift_2[9:2];
            shift_clock  <= pixel_clk_load ? 10'h3e0 : shift_clock[9:2];
        end
    end

    EG_LOGIC_ODDR oddr_clk (
        .q(hdmi_clk_p), .clk(clk_serial),
        .d1(shift_clock[1]), .d0(shift_clock[0]), .rst(1'b0)
    );
    EG_LOGIC_ODDR oddr_d0 (
        .q(hdmi_d0_p), .clk(clk_serial),
        .d1(tmds_shift_0[1]), .d0(tmds_shift_0[0]), .rst(1'b0)
    );
    EG_LOGIC_ODDR oddr_d1 (
        .q(hdmi_d1_p), .clk(clk_serial),
        .d1(tmds_shift_1[1]), .d0(tmds_shift_1[0]), .rst(1'b0)
    );
    EG_LOGIC_ODDR oddr_d2 (
        .q(hdmi_d2_p), .clk(clk_serial),
        .d1(tmds_shift_2[1]), .d0(tmds_shift_2[0]), .rst(1'b0)
    );
endmodule
