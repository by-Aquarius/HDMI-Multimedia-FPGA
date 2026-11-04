// SPDX-License-Identifier: MIT
// Ported from hdl-util/hdmi tmds_channel.sv and split into two pipeline stages
// for the 107.5 MHz EG4 implementation.
module hdmi_tmds_channel #(
    parameter CN = 0
) (
    input  wire       clk_pixel,
    input  wire       reset,
    input  wire [7:0] video_data,
    input  wire [3:0] data_island_data,
    input  wire [1:0] control_data,
    input  wire [2:0] mode,
    output reg  [9:0] tmds
);
    localparam [9:0] TMDS_IDLE = 10'b1101010100;

    reg signed [4:0] acc;
    reg        [7:0] video_stage;
    reg        [3:0] island_stage;
    reg        [1:0] control_stage;
    reg        [2:0] mode_stage;
    reg        [8:0] q_m_stage;
    reg        [4:0] n1q_stage;
    reg        [4:0] n0q_stage;

    reg        [8:0] q_m_comb;
    reg signed [4:0] acc_add_comb;
    reg        [9:0] q_out_comb;
    integer i;

    wire [3:0] n1d_comb = video_data[0] + video_data[1] + video_data[2] + video_data[3] +
                          video_data[4] + video_data[5] + video_data[6] + video_data[7];

    function [9:0] control_coding;
        input [1:0] value;
        begin
            case (value)
                2'b00: control_coding = 10'b1101010100;
                2'b01: control_coding = 10'b0010101011;
                2'b10: control_coding = 10'b0101010100;
                default: control_coding = 10'b1010101011;
            endcase
        end
    endfunction

    function [9:0] terc4_coding;
        input [3:0] value;
        begin
            case (value)
                4'b0000: terc4_coding = 10'b1010011100;
                4'b0001: terc4_coding = 10'b1001100011;
                4'b0010: terc4_coding = 10'b1011100100;
                4'b0011: terc4_coding = 10'b1011100010;
                4'b0100: terc4_coding = 10'b0101110001;
                4'b0101: terc4_coding = 10'b0100011110;
                4'b0110: terc4_coding = 10'b0110001110;
                4'b0111: terc4_coding = 10'b0100111100;
                4'b1000: terc4_coding = 10'b1011001100;
                4'b1001: terc4_coding = 10'b0100111001;
                4'b1010: terc4_coding = 10'b0110011100;
                4'b1011: terc4_coding = 10'b1011000110;
                4'b1100: terc4_coding = 10'b1010001110;
                4'b1101: terc4_coding = 10'b1001110001;
                4'b1110: terc4_coding = 10'b0101100011;
                default: terc4_coding = 10'b1011000011;
            endcase
        end
    endfunction

    always @(*) begin
        if (n1d_comb > 4'd4 || (n1d_comb == 4'd4 && video_data[0] == 1'b0)) begin
            q_m_comb[0] = video_data[0];
            for (i = 0; i < 7; i = i + 1)
                q_m_comb[i + 1] = q_m_comb[i] ~^ video_data[i + 1];
            q_m_comb[8] = 1'b0;
        end else begin
            q_m_comb[0] = video_data[0];
            for (i = 0; i < 7; i = i + 1)
                q_m_comb[i + 1] = q_m_comb[i] ^ video_data[i + 1];
            q_m_comb[8] = 1'b1;
        end
    end

    always @(posedge clk_pixel) begin
        if (reset) begin
            video_stage   <= 8'd0;
            island_stage  <= 4'd0;
            control_stage <= 2'd0;
            mode_stage    <= 3'd0;
            q_m_stage     <= 9'd0;
            n1q_stage     <= 5'd0;
            n0q_stage     <= 5'd8;
        end else begin
            video_stage   <= video_data;
            island_stage  <= data_island_data;
            control_stage <= control_data;
            mode_stage    <= mode;
            q_m_stage     <= q_m_comb;
            n1q_stage     <= q_m_comb[0] + q_m_comb[1] + q_m_comb[2] + q_m_comb[3] +
                             q_m_comb[4] + q_m_comb[5] + q_m_comb[6] + q_m_comb[7];
            n0q_stage     <= 5'd8 -
                             (q_m_comb[0] + q_m_comb[1] + q_m_comb[2] + q_m_comb[3] +
                              q_m_comb[4] + q_m_comb[5] + q_m_comb[6] + q_m_comb[7]);
        end
    end

    always @(*) begin
        if (acc == 5'sd0 || (n1q_stage == n0q_stage)) begin
            if (q_m_stage[8]) begin
                acc_add_comb = n1q_stage - n0q_stage;
                q_out_comb = {~q_m_stage[8], q_m_stage[8], q_m_stage[7:0]};
            end else begin
                acc_add_comb = n0q_stage - n1q_stage;
                q_out_comb = {~q_m_stage[8], q_m_stage[8], ~q_m_stage[7:0]};
            end
        end else if ((acc > 5'sd0 && n1q_stage > n0q_stage) ||
                     (acc < 5'sd0 && n1q_stage < n0q_stage)) begin
            q_out_comb = {1'b1, q_m_stage[8], ~q_m_stage[7:0]};
            acc_add_comb = (n0q_stage - n1q_stage) +
                           (q_m_stage[8] ? 5'sd2 : 5'sd0);
        end else begin
            q_out_comb = {1'b0, q_m_stage[8], q_m_stage[7:0]};
            acc_add_comb = (n1q_stage - n0q_stage) -
                           (~q_m_stage[8] ? 5'sd2 : 5'sd0);
        end
    end

    always @(posedge clk_pixel) begin
        if (reset) begin
            acc  <= 5'sd0;
            tmds <= TMDS_IDLE;
        end else begin
            acc <= (mode_stage != 3'd1) ? 5'sd0 : acc + acc_add_comb;
            case (mode_stage)
                3'd0: tmds <= control_coding(control_stage);
                3'd1: tmds <= q_out_comb;
                3'd2: tmds <= (CN == 0 || CN == 2) ?
                              10'b1011001100 : 10'b0100110011;
                3'd3: tmds <= terc4_coding(island_stage);
                3'd4: begin
                    if (CN == 1 || CN == 2)
                        tmds <= 10'b0100110011;
                    else
                        // HDMI blue data-island guard uses TERC4 1100..1111,
                        // with the two sync bits in the low positions.
                        tmds <= terc4_coding({2'b11, control_stage});
                end
                default: tmds <= TMDS_IDLE;
            endcase
        end
    end
endmodule
