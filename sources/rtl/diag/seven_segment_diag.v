`timescale 1ns / 1ps

// Multiplexed four-digit diagnostic display. Segment and digit-select
// polarities match the EG4S20 core board: segments are active-high and
// digit-select outputs are active-low.
module seven_segment_diag #(
    parameter integer SCAN_DIV = 25000
) (
    input  wire       clk_25m,
    input  wire       rst_n,
    input  wire       error_valid,
    input  wire [7:0] error_code,
    output reg  [3:0] digitron_cs,
    output reg  [7:0] digitron
);
    localparam [7:0] SEG_0 = 8'h3F;
    localparam [7:0] SEG_1 = 8'h06;
    localparam [7:0] SEG_2 = 8'h5B;
    localparam [7:0] SEG_3 = 8'h4F;
    localparam [7:0] SEG_4 = 8'h66;
    localparam [7:0] SEG_5 = 8'h6D;
    localparam [7:0] SEG_6 = 8'h7D;
    localparam [7:0] SEG_7 = 8'h07;
    localparam [7:0] SEG_8 = 8'h7F;
    localparam [7:0] SEG_9 = 8'h6F;
    localparam [7:0] SEG_E = 8'h79;
    localparam [7:0] SEG_DASH = 8'h40;

    reg [16:0] scan_count;
    reg [1:0]  digit_sel;
    reg [3:0]  hundreds;
    reg [3:0]  tens;
    reg [3:0]  ones;
    reg [7:0]  binary_work;
    integer    bit_index;

    always @(posedge clk_25m or negedge rst_n) begin
        if (!rst_n) begin
            scan_count <= 17'd0;
            digit_sel  <= 2'd0;
        end else if (scan_count >= SCAN_DIV - 1) begin
            scan_count <= 17'd0;
            digit_sel  <= digit_sel + 1'b1;
        end else begin
            scan_count <= scan_count + 1'b1;
        end
    end

    // Double-dabble conversion from 8-bit binary to three decimal digits.
    always @* begin
        hundreds    = 4'd0;
        tens        = 4'd0;
        ones        = 4'd0;
        binary_work = error_code;
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            if (hundreds >= 4'd5)
                hundreds = hundreds + 4'd3;
            if (tens >= 4'd5)
                tens = tens + 4'd3;
            if (ones >= 4'd5)
                ones = ones + 4'd3;
            hundreds = {hundreds[2:0], tens[3]};
            tens     = {tens[2:0], ones[3]};
            ones     = {ones[2:0], binary_work[7]};
            binary_work = {binary_work[6:0], 1'b0};
        end
    end

    always @* begin
        digitron_cs = 4'b1111;
        case (digit_sel)
            2'd0: digitron_cs = 4'b1110;
            2'd1: digitron_cs = 4'b1101;
            2'd2: digitron_cs = 4'b1011;
            default: digitron_cs = 4'b0111;
        endcase
    end

    always @* begin
        digitron = SEG_DASH;
        if (!error_valid) begin
            case (digit_sel)
                2'd3: digitron = SEG_DASH;
                default: digitron = 8'h00;
            endcase
        end else begin
            case (digit_sel)
                2'd3: digitron = SEG_E;
                2'd2: digitron = digit_to_segment(hundreds);
                2'd1: digitron = digit_to_segment(tens);
                default: digitron = digit_to_segment(ones);
            endcase
        end
    end

    function [7:0] digit_to_segment;
        input [3:0] digit;
        begin
            case (digit)
                4'd0: digit_to_segment = SEG_0;
                4'd1: digit_to_segment = SEG_1;
                4'd2: digit_to_segment = SEG_2;
                4'd3: digit_to_segment = SEG_3;
                4'd4: digit_to_segment = SEG_4;
                4'd5: digit_to_segment = SEG_5;
                4'd6: digit_to_segment = SEG_6;
                4'd7: digit_to_segment = SEG_7;
                4'd8: digit_to_segment = SEG_8;
                4'd9: digit_to_segment = SEG_9;
                default: digit_to_segment = 8'h00;
            endcase
        end
    endfunction
endmodule
