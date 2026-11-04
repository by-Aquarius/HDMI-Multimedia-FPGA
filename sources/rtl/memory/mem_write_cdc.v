`timescale 1ns/1ps
// One-entry, lossless write mailbox from the 25 MHz media/control domain to
// the dedicated 100 MHz SDRAM controller domain. Completion returns through
// a toggle, so frame_buffer_manager never advances until SDRAM acknowledges.
module mem_write_cdc (
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        wr_valid,
    output wire        wr_ready,
    input  wire [20:0] wr_addr_word,
    input  wire [31:0] wr_data,
    input  wire [3:0]  wr_strb,
    output reg         wr_done,
    output reg         wr_error,

    input  wire        rd_clk,
    input  wire        rd_rst_n,
    output wire        rd_valid,
    input  wire        rd_ready,
    output wire [20:0] rd_addr_word,
    output wire [31:0] rd_data,
    output wire [3:0]  rd_strb,
    input  wire        rd_done,
    input  wire        rd_error
);
    reg        req_toggle_wr;
    reg        wr_busy;
    reg [20:0] wr_addr_hold;
    reg [31:0] wr_data_hold;
    reg [3:0]  wr_strb_hold;

    reg req_sync1_rd, req_sync2_rd, req_seen_rd;
    reg rd_active;
    reg rd_issued;
    reg [20:0] rd_addr_hold;
    reg [31:0] rd_data_hold;
    reg [3:0]  rd_strb_hold;
    reg ack_toggle_rd;
    reg ack_error_rd;

    reg ack_sync1_wr, ack_sync2_wr, ack_seen_wr;
    reg ack_error_sync1_wr, ack_error_sync2_wr;

    assign wr_ready    = !wr_busy;
    assign rd_valid    = rd_active && !rd_issued;
    assign rd_addr_word = rd_addr_hold;
    assign rd_data      = rd_data_hold;
    assign rd_strb      = rd_strb_hold;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            req_toggle_wr    <= 1'b0;
            wr_busy          <= 1'b0;
            wr_addr_hold     <= 21'd0;
            wr_data_hold     <= 32'd0;
            wr_strb_hold     <= 4'd0;
            ack_sync1_wr     <= 1'b0;
            ack_sync2_wr     <= 1'b0;
            ack_seen_wr      <= 1'b0;
            ack_error_sync1_wr <= 1'b0;
            ack_error_sync2_wr <= 1'b0;
            wr_done          <= 1'b0;
            wr_error         <= 1'b0;
        end else begin
            ack_sync1_wr       <= ack_toggle_rd;
            ack_sync2_wr       <= ack_sync1_wr;
            ack_error_sync1_wr <= ack_error_rd;
            ack_error_sync2_wr <= ack_error_sync1_wr;
            wr_done            <= 1'b0;
            wr_error           <= 1'b0;

            if (wr_valid && wr_ready) begin
                wr_busy       <= 1'b1;
                wr_addr_hold  <= wr_addr_word;
                wr_data_hold  <= wr_data;
                wr_strb_hold  <= wr_strb;
                req_toggle_wr <= ~req_toggle_wr;
            end

            if (ack_sync2_wr != ack_seen_wr) begin
                ack_seen_wr <= ack_sync2_wr;
                wr_busy     <= 1'b0;
                wr_done     <= 1'b1;
                wr_error    <= ack_error_sync2_wr;
            end
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            req_sync1_rd <= 1'b0;
            req_sync2_rd <= 1'b0;
            req_seen_rd  <= 1'b0;
            rd_active    <= 1'b0;
            rd_issued    <= 1'b0;
            rd_addr_hold <= 21'd0;
            rd_data_hold <= 32'd0;
            rd_strb_hold <= 4'd0;
            ack_toggle_rd <= 1'b0;
            ack_error_rd  <= 1'b0;
        end else begin
            req_sync1_rd <= req_toggle_wr;
            req_sync2_rd <= req_sync1_rd;
            ack_error_rd <= ack_error_rd;

            if (!rd_active && (req_sync2_rd != req_seen_rd)) begin
                req_seen_rd <= req_sync2_rd;
                rd_active   <= 1'b1;
                rd_issued   <= 1'b0;
                rd_addr_hold <= wr_addr_hold;
                rd_data_hold <= wr_data_hold;
                rd_strb_hold <= wr_strb_hold;
            end

            if (rd_active && !rd_issued && rd_ready) begin
                rd_issued <= 1'b1;
                if (rd_done) begin
                    rd_active <= 1'b0;
                    rd_issued <= 1'b0;
                    ack_error_rd <= rd_error;
                    ack_toggle_rd <= ~ack_toggle_rd;
                end
            end

            if (rd_active && rd_issued && rd_done) begin
                rd_active    <= 1'b0;
                rd_issued    <= 1'b0;
                ack_error_rd <= rd_error;
                ack_toggle_rd <= ~ack_toggle_rd;
            end
        end
    end
endmodule
