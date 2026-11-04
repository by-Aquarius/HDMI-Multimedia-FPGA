`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// wav_header_parser.v
// F01: streaming RIFF/WAVE header parser for the C06 read-only byte stream.
//
// Accepted format:
//   RIFF/WAVE, PCM (format=1), mono, 16-bit, 48 kHz.
//
// The C06 byte stream has no reverse-ready signal. Every asserted in_valid
// byte is consumed in that cycle. Unknown RIFF chunks (including JUNK/LIST)
// are skipped using their little-endian size and, when required, one pad byte.
// -----------------------------------------------------------------------------
module wav_header_parser (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_last,

    output wire        busy,
    output reg         done,
    output reg         error,
    output reg  [7:0]  error_code,
    output reg         header_done,

    output reg  [31:0] riff_size,
    output reg  [31:0] data_offset,
    output reg  [31:0] data_size,
    output reg  [31:0] sample_rate,
    output reg  [15:0] channels,
    output reg  [15:0] bits_per_sample,
    output reg  [31:0] byte_rate,
    output reg  [15:0] block_align,

    output wire        pcm_valid,
    output wire [7:0]  pcm_data,
    output wire        pcm_last
);

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_RIFF_ID    = 4'd1;
    localparam [3:0] ST_RIFF_SIZE  = 4'd2;
    localparam [3:0] ST_WAVE_ID    = 4'd3;
    localparam [3:0] ST_CHUNK_ID   = 4'd4;
    localparam [3:0] ST_CHUNK_SIZE = 4'd5;
    localparam [3:0] ST_FMT_CORE   = 4'd6;
    localparam [3:0] ST_SKIP       = 4'd7;
    localparam [3:0] ST_SKIP_PAD   = 4'd8;
    localparam [3:0] ST_DATA       = 4'd9;
    localparam [3:0] ST_DONE       = 4'd10;
    localparam [3:0] ST_ERROR      = 4'd11;

    // Little-endian numeric values of the four-byte chunk identifiers.
    localparam [31:0] RIFF_ID = 32'h46464952;
    localparam [31:0] WAVE_ID = 32'h45564157;
    localparam [31:0] FMT_ID  = 32'h20746D66;
    localparam [31:0] DATA_ID = 32'h61746164;

    localparam [7:0] ERR_RIFF        = 8'h01;
    localparam [7:0] ERR_WAVE        = 8'h02;
    localparam [7:0] ERR_RIFF_SIZE   = 8'h03;
    localparam [7:0] ERR_CHUNK       = 8'h04;
    localparam [7:0] ERR_FMT_MISSING = 8'h05;
    localparam [7:0] ERR_FMT_SIZE    = 8'h06;
    localparam [7:0] ERR_FORMAT      = 8'h07;
    localparam [7:0] ERR_CHANNELS    = 8'h08;
    localparam [7:0] ERR_RATE        = 8'h09;
    localparam [7:0] ERR_WIDTH       = 8'h0A;
    localparam [7:0] ERR_BYTE_RATE   = 8'h0B;
    localparam [7:0] ERR_BLOCK_ALIGN = 8'h0C;
    localparam [7:0] ERR_DATA_SIZE   = 8'h0D;
    localparam [7:0] ERR_DATA_RANGE  = 8'h0E;
    localparam [7:0] ERR_EARLY_EOF   = 8'h0F;

    reg [3:0]  state;
    reg [3:0]  field_index;
    reg [4:0]  fmt_index;
    reg [31:0] byte_count;
    reg [31:0] field_value;
    reg [31:0] chunk_size_q;
    reg [31:0] chunk_remaining;
    reg [31:0] data_remaining;
    reg        in_valid_q;
    reg [7:0]  in_data_q;
    reg        in_last_q;
    reg        chunk_odd;
    reg        chunk_is_fmt;
    reg        chunk_is_data;
    reg        fmt_seen;

    reg [15:0] fmt_format_q;
    reg [15:0] fmt_channels_q;
    reg [31:0] fmt_sample_rate_q;
    reg [31:0] fmt_byte_rate_q;
    reg [15:0] fmt_block_align_q;
    reg [15:0] fmt_bits_q;

    wire [31:0] field_next = {in_data_q, field_value[31:8]};
    wire data_is_last_byte = (data_remaining == 32'd1);
    wire pcm_byte_allowed = in_valid_q && (state == ST_DATA) &&
                            !(in_last_q && !data_is_last_byte);

    assign busy = (state != ST_IDLE) &&
                  (state != ST_DONE) &&
                  (state != ST_ERROR);
    assign pcm_valid = pcm_byte_allowed;
    assign pcm_data  = in_data_q;
    assign pcm_last  = pcm_byte_allowed && data_is_last_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            field_index       <= 4'd0;
            fmt_index         <= 5'd0;
            byte_count        <= 32'd0;
            field_value       <= 32'd0;
            chunk_size_q      <= 32'd0;
            chunk_remaining   <= 32'd0;
            data_remaining    <= 32'd0;
            in_valid_q        <= 1'b0;
            in_data_q         <= 8'd0;
            in_last_q         <= 1'b0;
            chunk_odd         <= 1'b0;
            chunk_is_fmt      <= 1'b0;
            chunk_is_data     <= 1'b0;
            fmt_seen          <= 1'b0;
            fmt_format_q      <= 16'd0;
            fmt_channels_q    <= 16'd0;
            fmt_sample_rate_q <= 32'd0;
            fmt_byte_rate_q   <= 32'd0;
            fmt_block_align_q <= 16'd0;
            fmt_bits_q        <= 16'd0;
            done              <= 1'b0;
            error             <= 1'b0;
            error_code        <= 8'd0;
            header_done       <= 1'b0;
            riff_size         <= 32'd0;
            data_offset       <= 32'd0;
            data_size         <= 32'd0;
            sample_rate       <= 32'd0;
            channels          <= 16'd0;
            bits_per_sample   <= 16'd0;
            byte_rate         <= 32'd0;
            block_align       <= 16'd0;
        end else begin
            done        <= 1'b0;
            header_done <= 1'b0;
            in_valid_q  <= in_valid;
            in_data_q   <= in_data;
            in_last_q   <= in_last;

            if ((state == ST_IDLE) || (state == ST_DONE) ||
                (state == ST_ERROR)) begin
                if (start) begin
                    state             <= ST_RIFF_ID;
                    field_index       <= 4'd0;
                    fmt_index         <= 5'd0;
                    byte_count        <= 32'd0;
                    field_value       <= 32'd0;
                    chunk_size_q      <= 32'd0;
                    chunk_remaining   <= 32'd0;
                    data_remaining    <= 32'd0;
                    chunk_odd         <= 1'b0;
                    chunk_is_fmt      <= 1'b0;
                    chunk_is_data     <= 1'b0;
                    fmt_seen          <= 1'b0;
                    fmt_format_q      <= 16'd0;
                    fmt_channels_q    <= 16'd0;
                    fmt_sample_rate_q <= 32'd0;
                    fmt_byte_rate_q   <= 32'd0;
                    fmt_block_align_q <= 16'd0;
                    fmt_bits_q        <= 16'd0;
                    error             <= 1'b0;
                    error_code        <= 8'd0;
                    riff_size         <= 32'd0;
                    data_offset       <= 32'd0;
                    data_size         <= 32'd0;
                    sample_rate       <= 32'd0;
                    channels          <= 16'd0;
                    bits_per_sample   <= 16'd0;
                    byte_rate         <= 32'd0;
                    block_align       <= 16'd0;
                end
            end else if (in_valid_q) begin
                byte_count <= byte_count + 1'b1;

                if (in_last_q &&
                    ((state != ST_DATA) || !data_is_last_byte)) begin
                    state      <= ST_ERROR;
                    error      <= 1'b1;
                    error_code <= ERR_EARLY_EOF;
                end else begin
                    case (state)
                        ST_RIFF_ID: begin
                            field_value <= field_next;
                            if (field_index == 4'd3) begin
                                field_index <= 4'd0;
                                field_value <= 32'd0;
                                if (field_next != RIFF_ID) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_RIFF;
                                end else begin
                                    state <= ST_RIFF_SIZE;
                                end
                            end else begin
                                field_index <= field_index + 1'b1;
                            end
                        end

                        ST_RIFF_SIZE: begin
                            field_value <= field_next;
                            if (field_index == 4'd3) begin
                                field_index <= 4'd0;
                                field_value <= 32'd0;
                                if (field_next < 32'd36) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_RIFF_SIZE;
                                end else begin
                                    riff_size <= field_next;
                                    state     <= ST_WAVE_ID;
                                end
                            end else begin
                                field_index <= field_index + 1'b1;
                            end
                        end

                        ST_WAVE_ID: begin
                            field_value <= field_next;
                            if (field_index == 4'd3) begin
                                field_index <= 4'd0;
                                field_value <= 32'd0;
                                if (field_next != WAVE_ID) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_WAVE;
                                end else begin
                                    state <= ST_CHUNK_ID;
                                end
                            end else begin
                                field_index <= field_index + 1'b1;
                            end
                        end

                        ST_CHUNK_ID: begin
                            field_value <= field_next;
                            if (field_index == 4'd3) begin
                                field_index <= 4'd0;
                                field_value <= 32'd0;
                                chunk_is_fmt  <= (field_next == FMT_ID);
                                chunk_is_data <= (field_next == DATA_ID);
                                state <= ST_CHUNK_SIZE;
                            end else begin
                                field_index <= field_index + 1'b1;
                            end
                        end

                        ST_CHUNK_SIZE: begin
                            field_value <= field_next;
                            if (field_index == 4'd3) begin
                                field_index <= 4'd0;
                                field_value <= 32'd0;
                                if (chunk_is_fmt) begin
                                    if (field_next < 32'd16) begin
                                        state      <= ST_ERROR;
                                        error      <= 1'b1;
                                        error_code <= ERR_FMT_SIZE;
                                    end else begin
                                        chunk_size_q <= field_next;
                                        chunk_odd    <= field_next[0];
                                        fmt_index    <= 5'd0;
                                        state        <= ST_FMT_CORE;
                                    end
                                end else if (chunk_is_data) begin
                                    if (!fmt_seen) begin
                                        state      <= ST_ERROR;
                                        error      <= 1'b1;
                                        error_code <= ERR_FMT_MISSING;
                                    end else if ((field_next == 32'd0) ||
                                                 field_next[0]) begin
                                        state      <= ST_ERROR;
                                        error      <= 1'b1;
                                        error_code <= ERR_DATA_SIZE;
                                    end else if (({1'b0, byte_count} + 33'd1 +
                                                  {1'b0, field_next}) >
                                                 ({1'b0, riff_size} + 33'd8)) begin
                                        state      <= ST_ERROR;
                                        error      <= 1'b1;
                                        error_code <= ERR_DATA_RANGE;
                                    end else begin
                                        data_offset    <= byte_count + 1'b1;
                                        data_size      <= field_next;
                                        data_remaining <= field_next;
                                        header_done    <= 1'b1;
                                        state          <= ST_DATA;
                                    end
                                end else if (field_next == 32'd0) begin
                                    state <= ST_CHUNK_ID;
                                end else begin
                                    chunk_remaining <= field_next;
                                    chunk_odd       <= field_next[0];
                                    state           <= ST_SKIP;
                                end
                            end else begin
                                field_index <= field_index + 1'b1;
                            end
                        end

                        ST_FMT_CORE: begin
                            case (fmt_index)
                                5'd0:  fmt_format_q[7:0]      <= in_data_q;
                                5'd1:  fmt_format_q[15:8]     <= in_data_q;
                                5'd2:  fmt_channels_q[7:0]    <= in_data_q;
                                5'd3:  fmt_channels_q[15:8]   <= in_data_q;
                                5'd4:  fmt_sample_rate_q[7:0] <= in_data_q;
                                5'd5:  fmt_sample_rate_q[15:8]<= in_data_q;
                                5'd6:  fmt_sample_rate_q[23:16]<= in_data_q;
                                5'd7:  fmt_sample_rate_q[31:24]<= in_data_q;
                                5'd8:  fmt_byte_rate_q[7:0]   <= in_data_q;
                                5'd9:  fmt_byte_rate_q[15:8]  <= in_data_q;
                                5'd10: fmt_byte_rate_q[23:16] <= in_data_q;
                                5'd11: fmt_byte_rate_q[31:24] <= in_data_q;
                                5'd12: fmt_block_align_q[7:0] <= in_data_q;
                                5'd13: fmt_block_align_q[15:8]<= in_data_q;
                                5'd14: fmt_bits_q[7:0]        <= in_data_q;
                                5'd15: fmt_bits_q[15:8]       <= in_data_q;
                                default: ;
                            endcase

                            if (fmt_index == 5'd15) begin
                                fmt_index <= 5'd0;
                                if (fmt_format_q != 16'd1) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_FORMAT;
                                end else if (fmt_channels_q != 16'd1) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_CHANNELS;
                                end else if (fmt_sample_rate_q != 32'd48000) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_RATE;
                                end else if ({in_data_q, fmt_bits_q[7:0]} !=
                                             16'd16) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_WIDTH;
                                end else if (fmt_byte_rate_q != 32'd96000) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_BYTE_RATE;
                                end else if (fmt_block_align_q != 16'd2) begin
                                    state      <= ST_ERROR;
                                    error      <= 1'b1;
                                    error_code <= ERR_BLOCK_ALIGN;
                                end else begin
                                    fmt_seen <= 1'b1;
                                    sample_rate     <= fmt_sample_rate_q;
                                    channels        <= fmt_channels_q;
                                    bits_per_sample <= {in_data_q, fmt_bits_q[7:0]};
                                    byte_rate       <= fmt_byte_rate_q;
                                    block_align     <= fmt_block_align_q;
                                    if (chunk_size_q > 32'd16) begin
                                        chunk_remaining <= chunk_size_q - 32'd16;
                                        state           <= ST_SKIP;
                                    end else begin
                                        state <= ST_CHUNK_ID;
                                    end
                                end
                            end else begin
                                fmt_index <= fmt_index + 1'b1;
                            end
                        end

                        ST_SKIP: begin
                            if (chunk_remaining == 32'd1) begin
                                chunk_remaining <= 32'd0;
                                if (chunk_odd)
                                    state <= ST_SKIP_PAD;
                                else
                                    state <= ST_CHUNK_ID;
                            end else begin
                                chunk_remaining <= chunk_remaining - 1'b1;
                            end
                        end

                        ST_SKIP_PAD: begin
                            state <= ST_CHUNK_ID;
                        end

                        ST_DATA: begin
                            if (data_remaining == 32'd1) begin
                                data_remaining <= 32'd0;
                                done           <= 1'b1;
                                state          <= ST_DONE;
                            end else begin
                                data_remaining <= data_remaining - 1'b1;
                            end
                        end

                        default: begin
                            state      <= ST_ERROR;
                            error      <= 1'b1;
                            error_code <= ERR_CHUNK;
                        end
                    endcase
                end
            end
        end
    end

endmodule
