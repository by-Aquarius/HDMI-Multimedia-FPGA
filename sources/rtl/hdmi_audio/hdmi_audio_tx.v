`timescale 1ns / 1ps
// HDMI transmitter with audio Sample Packets. Video timing is supplied by the
// validated media pipeline; this module adds HDMI data islands in horizontal
// blanking without changing the 1280x1024@60 pixel timing.
module hdmi_audio_tx #(
    parameter [6:0] VIDEO_ID_CODE = 7'd4,
    parameter IT_CONTENT = 1'b1,
    parameter integer H_BLANK_PIXELS = 370,
    parameter integer H_TOTAL_PIXELS = 1650,
    parameter integer NUM_PACKETS_PER_LINE = 6,
    parameter [63:0] VENDOR_NAME = 64'h4650474100000000,
    parameter [127:0] PRODUCT_DESCRIPTION = 128'h4547345332302048444D4900000000,
    parameter [7:0] SOURCE_DEVICE_INFORMATION = 8'h09
) (
    input  wire        clk_pixel,
    input  wire        clk_pixel_x5,
    input  wire        reset,
    input  wire        video_hs,
    input  wire        video_vs,
    input  wire        video_de,
    input  wire [23:0] video_rgb,
    input  wire        sample_strobe,
    input wire [1:0] audio_diagnostic_mode,
    input  wire [15:0] audio_sample_word_0,
    input  wire [15:0] audio_sample_word_1,
    output wire        hdmi_clk_p,
    output wire        hdmi_d0_p,
    output wire        hdmi_d1_p,
    output wire        hdmi_d2_p,
    output wire [2:0]  debug_mode,
    output wire [7:0]  debug_packet_type
);
    localparam integer ISLAND_START = 14;
    localparam integer ISLAND_END = ISLAND_START + NUM_PACKETS_PER_LINE * 32;

    reg [11:0] backporch_count;
    reg        in_backporch;
    reg        video_hs_d;
    reg        video_vs_d;
    reg        video_de_d;
    reg [11:0] pixel_x;
    // Count the upcoming raster row after HS; DE reacquires the first active row.
    reg [10:0] next_line;
    wire next_line_active = next_line < 11'd720;
    always @(posedge clk_pixel) begin
        if(reset)next_line<=11'd749;
        else if(video_de && !video_de_d && next_line>=720)next_line<=0;
        else if(video_hs && !video_hs_d)next_line<=next_line==749 ? 0 : next_line+1'b1;
    end
    reg        data_island_guard;
    reg        data_island_preamble;
    reg        data_island_period;
    reg        video_preamble;
    reg        video_guard;
    reg [2:0]  mode;
    reg [23:0] video_data;
    reg [5:0]  control_data;
    reg [11:0] data_island_data;
    reg [2:0]  tx_mode_q /* synthesis keep=true */;
    reg [23:0] tx_video_data_q /* synthesis keep=true */;
    reg [5:0]  tx_control_data_q /* synthesis keep=true */;
    reg [11:0] tx_data_island_data_q /* synthesis keep=true */;
    wire       data_island_period_instantaneous;
    wire       packet_enable;
    wire       video_preamble_now;
    wire       video_guard_now;

    wire video_field_end = video_vs ^ video_vs_d;
    wire [23:0] pkt_header;
    wire [55:0] pkt_sub_0;
    wire [55:0] pkt_sub_1;
    wire [55:0] pkt_sub_2;
    wire [55:0] pkt_sub_3;
    wire [4:0] packet_pixel_counter;
    wire [8:0] packet_data;
    wire [9:0] tmds_internal_0;
    wire [9:0] tmds_internal_1;
    wire [9:0] tmds_internal_2;

    always @(posedge clk_pixel) begin
        if (reset) begin
            backporch_count <= 12'd0;
            in_backporch <= 1'b0;
            video_hs_d <= 1'b0;
            video_vs_d <= 1'b0;
            video_de_d <= 1'b0;
            pixel_x <= 12'd0;
            data_island_guard <= 1'b0;
            data_island_preamble <= 1'b0;
            data_island_period <= 1'b0;
            video_preamble <= 1'b0;
            video_guard <= 1'b0;
        end else begin
            video_hs_d <= video_hs;
            video_vs_d <= video_vs;
            video_de_d <= video_de;

            if (video_de && !video_de_d) begin
                pixel_x <= 12'd0;
            end else if (pixel_x >= (H_TOTAL_PIXELS - 1)) begin
                pixel_x <= 12'd0;
            end else begin
                pixel_x <= pixel_x + 1'b1;
            end

            if (video_de) begin
                in_backporch   <= 1'b0;
                backporch_count <= 12'd0;
            end else if (video_hs && !video_hs_d) begin
                in_backporch   <= 1'b1;
                backporch_count <= 12'd0;
            end else if (in_backporch) begin
                backporch_count <= backporch_count + 1'b1;
            end

            data_island_preamble <= in_backporch &&
                                    (backporch_count >= 12'd4) &&
                                    (backporch_count < 12'd12);
            data_island_guard <= in_backporch &&
                                 (((backporch_count >= 12'd12) &&
                                   (backporch_count < ISLAND_START)) ||
                                  ((backporch_count >= ISLAND_END) &&
                                   (backporch_count < ISLAND_END + 2)));
            data_island_period <= data_island_period_instantaneous;
            video_preamble <= video_preamble_now;
            video_guard <= video_guard_now;
        end
    end

    assign video_preamble_now =
        next_line_active && (pixel_x >= (H_TOTAL_PIXELS - 12)) &&
        (pixel_x <  (H_TOTAL_PIXELS - 4));
    assign video_guard_now =
        next_line_active && (pixel_x >= (H_TOTAL_PIXELS - 4)) &&
        (pixel_x <  (H_TOTAL_PIXELS - 2));

    assign data_island_period_instantaneous =
        in_backporch &&
        (backporch_count >= ISLAND_START) &&
        (backporch_count < ISLAND_END);
    assign packet_enable = data_island_period_instantaneous &&
                           (((backporch_count + 12'd18) & 5'h1f) == 5'd0);

    hdmi_packet_picker #(
        .VIDEO_ID_CODE(VIDEO_ID_CODE),
        .IT_CONTENT(IT_CONTENT),
        .AUDIO_BIT_WIDTH(16)
    ) u_packet_picker (
        .clk_pixel(clk_pixel),
        .sample_strobe(sample_strobe),
        .audio_diagnostic_mode(audio_diagnostic_mode),
        .reset(reset),
        .video_field_end(video_field_end),
        .packet_enable(packet_enable),
        .packet_pixel_counter(packet_pixel_counter),
        .audio_sample_word_0(audio_sample_word_0),
        .audio_sample_word_1(audio_sample_word_1),
        .header(pkt_header),
        .sub_0(pkt_sub_0), .sub_1(pkt_sub_1),
        .sub_2(pkt_sub_2), .sub_3(pkt_sub_3),
        .current_packet_type(debug_packet_type)
    );

    hdmi_packet_assembler u_packet_assembler (
        .clk_pixel(clk_pixel),
        .reset(reset),
        .data_island_period(data_island_period),
        .header(pkt_header),
        .sub_0(pkt_sub_0), .sub_1(pkt_sub_1),
        .sub_2(pkt_sub_2), .sub_3(pkt_sub_3),
        .packet_data(packet_data),
        .counter(packet_pixel_counter)
    );

    always @(posedge clk_pixel) begin
        if (reset) begin
            mode             <= 3'd0;
            video_data       <= 24'd0;
            control_data     <= 6'd0;
            data_island_data <= 12'd0;
        end else begin
            mode <= data_island_guard ? 3'd4 :
                    data_island_period ? 3'd3 :
                    video_guard ? 3'd2 :
                    video_de ? 3'd1 : 3'd0;
            video_data <= video_rgb;
            control_data <= {
                1'b0, data_island_preamble,
                1'b0, video_preamble || data_island_preamble,
                video_vs, video_hs
            };
            data_island_data[11:4] <= packet_data[8:1];
            data_island_data[3] <= 1'b1;
            data_island_data[2] <= packet_data[0];
            data_island_data[1:0] <= {video_vs, video_hs};
        end
    end

    always @(posedge clk_pixel) begin
        if (reset) begin
            tx_mode_q             <= 3'd0;
            tx_video_data_q       <= 24'd0;
            tx_control_data_q     <= 6'd0;
            tx_data_island_data_q <= 12'd0;
        end else begin
            tx_mode_q             <= mode;
            tx_video_data_q       <= video_data;
            tx_control_data_q     <= control_data;
            tx_data_island_data_q <= data_island_data;
        end
    end

    assign debug_mode = tx_mode_q;

    hdmi_tmds_channel #(.CN(0)) u_tmds_b (
        .clk_pixel(clk_pixel), .reset(reset), .video_data(tx_video_data_q[7:0]),
        .data_island_data(tx_data_island_data_q[3:0]),
        .control_data(tx_control_data_q[1:0]), .mode(tx_mode_q), .tmds(tmds_internal_0)
    );
    hdmi_tmds_channel #(.CN(1)) u_tmds_g (
        .clk_pixel(clk_pixel), .reset(reset), .video_data(tx_video_data_q[15:8]),
        .data_island_data(tx_data_island_data_q[7:4]),
        .control_data(tx_control_data_q[3:2]), .mode(tx_mode_q), .tmds(tmds_internal_1)
    );
    hdmi_tmds_channel #(.CN(2)) u_tmds_r (
        .clk_pixel(clk_pixel), .reset(reset), .video_data(tx_video_data_q[23:16]),
        .data_island_data(tx_data_island_data_q[11:8]),
        .control_data(tx_control_data_q[5:4]), .mode(tx_mode_q), .tmds(tmds_internal_2)
    );

    hdmi_serializer_eg4 u_serializer (
        .clk_pixel(clk_pixel), .clk_serial(clk_pixel_x5), .reset(reset),
        .tmds_internal_0(tmds_internal_0),
        .tmds_internal_1(tmds_internal_1),
        .tmds_internal_2(tmds_internal_2),
        .hdmi_clk_p(hdmi_clk_p), .hdmi_d0_p(hdmi_d0_p),
        .hdmi_d1_p(hdmi_d1_p), .hdmi_d2_p(hdmi_d2_p)
    );
endmodule
