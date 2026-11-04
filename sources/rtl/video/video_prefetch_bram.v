// -----------------------------------------------------------------------------
// video_prefetch.v
// D06: one-line SDRAM read prefetcher and RGB565 pixel interface.
//
// Address contract:
//   req_frame_base_word and mem_rd_addr_word are 21-bit EG4 SDRAM WORD
//   addresses. One returned 32-bit word contains two row-major RGB565 pixels:
//       returned_word[15:0]  = even-x pixel
//       returned_word[31:16] = odd-x pixel
//   line_y selects the source line and the module adds
//       ((line_y * FRAME_WIDTH) >> 1) words.
//
// Protocol:
//   line_req/line_req_ready requests one complete source line. The requester
//   must wait for line_ready before asserting pixel_rd_en. One pixel is popped
//   per pixel_rd_en. line_done pulses after FRAME_WIDTH pixels are consumed.
//   A pixel request before line_ready or after the FIFO is empty produces a
//   one-cycle line_underflow pulse and sets underflow_latched.
//
// The prefetcher intentionally does not generate HDMI timing or access the
// pixel clock directly. The caller schedules line_req during blanking/early
// enough to meet the active-line deadline.
// -----------------------------------------------------------------------------
module video_prefetch_bram #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter integer LINE_FIFO_DEPTH = 1024
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        line_req,
    output wire        line_req_ready,
    input  wire [11:0] req_line_y,
    input  wire [20:0] req_frame_base_word,

    output reg         line_ready,
    input  wire        pixel_rd_en,
    output reg         line_pixel_valid,
    output reg  [15:0] line_pixel_data,
    output reg         line_done,
    output reg         line_error,
    output reg         line_underflow,
    output reg         underflow_latched,
    output wire        busy,

    // D04-compatible single-word SDRAM read client.
    output wire        mem_rd_valid,
    input  wire        mem_rd_ready,
    output wire [20:0] mem_rd_addr_word,
    input  wire        mem_rd_rsp_valid,
    input  wire [31:0] mem_rd_rsp_data,
    input  wire        mem_rd_error,
    output wire        mem_burst_valid,
    input  wire        mem_burst_ready,
    output wire [20:0] mem_burst_addr_word,
    output wire [3:0]  mem_burst_len,
    input  wire        mem_burst_rsp_valid,
    input  wire [31:0] mem_burst_rsp_data,
    input  wire        mem_burst_rsp_last,
    input  wire        mem_burst_rsp_error
);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_REQ  = 3'd1;
    localparam [2:0] ST_WAIT = 3'd2;
    localparam [2:0] ST_CONS = 3'd3;

    localparam integer WORDS_PER_LINE = FRAME_WIDTH / 2;
    reg [2:0] state;
    reg [31:0] line_base_word;
    reg [15:0] request_word_index;
    reg [15:0] write_pixel_index;
    reg [15:0] read_pixel_index;
    reg [15:0] fifo_count;
    reg [8:0]  cons_word_addr;
    reg        cons_phase;
    reg        cons_pair_valid;
    reg [15:0] cons_even_q;
    reg [15:0] cons_odd_q;
    reg [31:0] wait_timer;

    wire line_fifo_empty = (fifo_count == 0);
    wire line_fifo_full = (fifo_count >= FRAME_WIDTH);

    wire [8:0] ram_wr_addr = write_pixel_index[9:1];
    // NOREG removes the optional output register; the RAM address is still
    // sampled synchronously. Keep an explicit word pipeline so each 32-bit
    // SDRAM word is emitted exactly once as an even/odd pixel pair.
    wire [8:0] ram_rd_addr = cons_word_addr;
    // Fixed 640x480 rows contain 320 words; with the aligned FRAME_B base,
    // each line start and SDRAM row boundary are 8-word aligned.
    localparam [3:0] BURST_WORDS = 4'd8;
    wire ram_wr_en = (state == ST_WAIT) && mem_burst_rsp_valid && !mem_burst_rsp_error && !line_fifo_full;
    wire [31:0] ram_wr_data = mem_burst_rsp_data;

    // Two true dual-port BRAM banks: port A writes SDRAM refill pixels,
    // port B reads the FIFO pixel address during line consumption.
    wire [15:0] ram_even_data;
    wire [15:0] ram_odd_data;
    // True dual-port line RAM: port A writes the SDRAM refill, port B reads
    // the requested pixel address. The previous SP version reused addra for
    // both operations and therefore returned the last write address.
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(9), .DATA_DEPTH_A(512),
        .DATA_WIDTH_B(16), .ADDR_WIDTH_B(9), .DATA_DEPTH_B(512),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"), .FILL_ALL("NONE") )
    line_ram_even (
        .dia(ram_wr_data[15:0]), .dib(16'd0),
        .addra(ram_wr_addr), .addrb(ram_rd_addr),
        .cea(ram_wr_en), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(ram_wr_en), .web(1'b0),
        .bea(1'b1), .beb(1'b0), .rsta(!rst_n), .rstb(!rst_n),
        .doa(), .dob(ram_even_data) );

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(9), .DATA_DEPTH_A(512),
        .DATA_WIDTH_B(16), .ADDR_WIDTH_B(9), .DATA_DEPTH_B(512),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"), .FILL_ALL("NONE") )
    line_ram_odd (
        .dia(ram_wr_data[31:16]), .dib(16'd0),
        .addra(ram_wr_addr), .addrb(ram_rd_addr),
        .cea(ram_wr_en), .ceb(1'b1), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(ram_wr_en), .web(1'b0),
        .bea(1'b1), .beb(1'b0), .rsta(!rst_n), .rstb(!rst_n),
        .doa(), .dob(ram_odd_data) );
    wire [31:0] requested_line_offset =
                 ((req_line_y * FRAME_WIDTH) >> 1);
    wire [20:0] current_mem_addr =
                 line_base_word[20:0] + request_word_index;
    wire request_last_word = (request_word_index == WORDS_PER_LINE - 1);
    assign line_req_ready = (state == ST_IDLE);
    assign busy = (state != ST_IDLE);
    assign mem_rd_valid = 1'b0;
    assign mem_rd_addr_word = current_mem_addr;
    assign mem_burst_valid = (state == ST_REQ);
    assign mem_burst_addr_word = current_mem_addr;
    assign mem_burst_len = BURST_WORDS;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            line_base_word    <= 32'd0;
            request_word_index <= 16'd0;
            write_pixel_index  <= 16'd0;
            read_pixel_index   <= 16'd0;
            fifo_count         <= 16'd0;
            cons_word_addr     <= 9'd0;
            cons_phase         <= 1'b0;
            cons_pair_valid    <= 1'b0;
            cons_even_q        <= 16'd0;
            cons_odd_q         <= 16'd0;
            wait_timer         <= 32'd0;
            line_ready         <= 1'b0;
            line_pixel_valid   <= 1'b0;
            line_pixel_data    <= 16'd0;
            line_done          <= 1'b0;
            line_error         <= 1'b0;
            line_underflow     <= 1'b0;
            underflow_latched  <= 1'b0;
        end else begin
            line_pixel_valid <= 1'b0;
            line_done        <= 1'b0;
            line_error       <= 1'b0;
            line_underflow   <= 1'b0;

            if (state == ST_WAIT)
                wait_timer <= wait_timer + 1'b1;
            else
                wait_timer <= 32'd0;

            // Underflow is observable even if the requester starts consuming
            // before the requested line has arrived.
            if (pixel_rd_en && (!line_ready || line_fifo_empty)) begin
                line_underflow    <= 1'b1;
                underflow_latched <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    line_ready        <= 1'b0;
                    fifo_count        <= 16'd0;
                    cons_word_addr    <= 9'd0;
                    cons_phase        <= 1'b0;
                    cons_pair_valid   <= 1'b0;
                    write_pixel_index <= 16'd0;
                    read_pixel_index  <= 16'd0;
                    request_word_index <= 16'd0;
                    if (line_req) begin
                        if (req_line_y >= FRAME_HEIGHT) begin
                            line_error <= 1'b1;
                        end else begin
                            line_base_word <= req_frame_base_word + requested_line_offset;
                            state <= ST_REQ;
                        end
                    end
                end

                ST_REQ: begin
                    if (mem_burst_ready) begin
                        state <= ST_WAIT;
                        wait_timer <= 32'd0;
                    end
                end

                ST_WAIT: begin
                    if (mem_burst_rsp_valid) begin
                        if (mem_burst_rsp_error || line_fifo_full) begin
                            line_error <= 1'b1;
                            line_ready <= 1'b0;
                            state <= ST_IDLE;
                        end else begin
                            // Low half is even x; high half is odd x.
                            write_pixel_index <= write_pixel_index + 2;
                            fifo_count <= fifo_count + 2;
                            if (mem_burst_rsp_last) begin
                                if (request_word_index == WORDS_PER_LINE - BURST_WORDS) begin
                                    line_ready <= 1'b1;
                                    cons_word_addr <= 9'd0;
                                    cons_phase <= 1'b0;
                                    cons_pair_valid <= 1'b0;
                                    state <= ST_CONS;
                                end else begin
                                    request_word_index <= request_word_index + BURST_WORDS;
                                    state <= ST_REQ;
                                end
                            end
                            // For non-last burst beats, remain in ST_WAIT so
                            // every returned word is written into the line BRAM.
                        end
                    end else if (wait_timer >= 32'h00FF_FFFF) begin
                        line_error <= 1'b1;
                        line_ready <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                ST_CONS: begin
                    if (!cons_pair_valid) begin
                        // Word 0 is already present on the BRAM read outputs.
                        // Capture it, then start the next word address.
                        cons_even_q     <= ram_even_data;
                        cons_odd_q      <= ram_odd_data;
                        cons_pair_valid <= 1'b1;
                        cons_word_addr  <= 9'd1;
                    end else if (pixel_rd_en && line_ready && !line_fifo_empty) begin
                        if (!cons_phase) begin
                            // Emit the even pixel and launch the next word read.
                            line_pixel_data  <= cons_even_q;
                            line_pixel_valid <= 1'b1;
                            cons_word_addr   <= cons_word_addr + 1'b1;
                            cons_phase       <= 1'b1;
                        end else begin
                            // Emit the odd pixel and capture the next word that
                            // became available during the previous clock.
                            line_pixel_data  <= cons_odd_q;
                            line_pixel_valid <= 1'b1;
                            cons_even_q      <= ram_even_data;
                            cons_odd_q       <= ram_odd_data;
                            cons_phase       <= 1'b0;
                        end

                        fifo_count       <= fifo_count - 1'b1;
                        read_pixel_index <= read_pixel_index + 1'b1;
                        if (read_pixel_index == FRAME_WIDTH - 1) begin
                            line_ready <= 1'b0;
                            line_done  <= 1'b1;
                            state      <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

