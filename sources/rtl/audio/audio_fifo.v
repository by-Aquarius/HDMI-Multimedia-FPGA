`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// audio_fifo.v
// F02: PCM byte pairing, signed 16-bit mono FIFO, low-water and underrun.
// -----------------------------------------------------------------------------
module audio_fifo #(
    parameter integer DEPTH = 2048,
    parameter integer LOW_WATER = 512
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,

    input  wire        pcm_valid,
    input  wire [7:0]  pcm_data,
    input  wire        pcm_last,

    input  wire        sample_tick,
    output reg  [15:0] sample_out,
    output reg         sample_valid,
    output reg         underrun,

    output wire        low_water,
    output wire        full,
    output reg         overflow,
    output reg         format_error,
    output reg         stream_done,
    output wire [11:0] fill_level
);

    reg [10:0] write_ptr;
    reg [10:0] read_ptr;
    reg [11:0] count;
    reg        low_byte_valid;
    reg [7:0]  low_byte_data;
    // Forward the latest committed word across the BRAM read-during-write edge.
    reg        recent_write_valid;
    reg [10:0] recent_write_address;
    reg [15:0] recent_write_sample;

    wire word_write = pcm_valid && low_byte_valid;
    wire accept_write = word_write && !full && !flush;
    wire do_read = sample_tick && (count != 12'd0) && !flush;
    wire [15:0] pcm_bram_dout;
    wire recent_read_match = recent_write_valid && (recent_write_address == read_ptr);

    // 2048x16 = 32 kbit. A single EG_LOGIC_BRAM 32K block replaces the
    // previous distributed-RAM inference, freeing about 2.5k LUTs and
    // improving placement/timing margin. DEPTH may be smaller in testbenches;
    // the extra BRAM addresses are simply unused.
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(11), .DATA_DEPTH_A(2048),
        .DATA_WIDTH_B(16), .ADDR_WIDTH_B(11), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .FILL_ALL("NONE")
    ) u_pcm_bram (
        .dia({pcm_data, low_byte_data}), .dib(16'd0),
        .addra(write_ptr), .addrb(read_ptr),
        .cea(accept_write), .ceb(1'b1),
        .wea(accept_write), .web(1'b0),
        .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk),
        .bea(1'b1), .beb(1'b0),
        .rsta(!rst_n), .rstb(!rst_n),
        .doa(), .dob(pcm_bram_dout)
    );

    assign full      = (count == DEPTH);
    assign low_water = (count <= LOW_WATER);
    assign fill_level = count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr      <= 11'd0;
            read_ptr       <= 11'd0;
            count          <= 12'd0;
            low_byte_valid <= 1'b0;
            low_byte_data  <= 8'd0;
            sample_out     <= 16'd0;
            sample_valid   <= 1'b0;
            underrun       <= 1'b0;
            overflow       <= 1'b0;
            format_error   <= 1'b0;
            stream_done    <= 1'b0;
            recent_write_valid   <= 1'b0;
            recent_write_address <= 11'd0;
            recent_write_sample  <= 16'd0;
        end else if (flush) begin
            write_ptr      <= 11'd0;
            read_ptr       <= 11'd0;
            count          <= 12'd0;
            low_byte_valid <= 1'b0;
            low_byte_data  <= 8'd0;
            sample_out     <= 16'd0;
            sample_valid   <= 1'b0;
            underrun       <= 1'b0;
            overflow       <= 1'b0;
            format_error   <= 1'b0;
            stream_done    <= 1'b0;
            recent_write_valid   <= 1'b0;
            recent_write_address <= 11'd0;
            recent_write_sample  <= 16'd0;
        end else begin
            sample_valid <= sample_tick;
            recent_write_valid <= accept_write;
            if (accept_write) begin
                recent_write_address <= write_ptr;
                recent_write_sample <= {pcm_data, low_byte_data};
            end

            if (do_read) begin
                // A write on the preceding clock may leave old data at dob.
                // Forward that complete sample without delaying sample_valid.
                sample_out <= recent_read_match ? recent_write_sample : pcm_bram_dout;
                read_ptr   <= read_ptr + 1'b1;
                underrun   <= 1'b0;
            end else if (sample_tick) begin
                sample_out <= 16'd0;
                underrun   <= 1'b1;
            end

            if (accept_write) begin
                write_ptr <= write_ptr + 1'b1;
            end else if (word_write && full) begin
                overflow <= 1'b1;
            end

            if (pcm_valid) begin
                if (!low_byte_valid) begin
                    low_byte_data <= pcm_data;
                    low_byte_valid <= 1'b1;
                    if (pcm_last) begin
                        low_byte_valid <= 1'b0;
                        format_error   <= 1'b1;
                    end
                end else begin
                    low_byte_valid <= 1'b0;
                    if (pcm_last)
                        stream_done <= 1'b1;
                end
            end

            if (do_read && !accept_write)
                count <= count - 1'b1;
            else if (!do_read && accept_write)
                count <= count + 1'b1;
        end
    end

endmodule
