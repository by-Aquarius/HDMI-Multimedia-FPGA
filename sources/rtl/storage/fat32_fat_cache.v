// -----------------------------------------------------------------------------
// fat32_fat_cache.v
// C06: read-only FAT32 FAT-entry lookup.
//
// A FAT32 entry occupies four bytes. With 512-byte sectors, cluster N is in
// FAT sector (N >> 7), at byte offset ((N & 7'h7f) << 2).
// No FAT write/erase command exists in this module.
// -----------------------------------------------------------------------------
module fat32_fat_cache #(
    // Control-clock cycles, not SPI bytes. One 512-byte block at the selected
    // SD clock plus command, token and CRC overhead must fit in this window.
    parameter integer RESPONSE_TIMEOUT_CYCLES = 262144
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        lookup_start,
    input  wire [31:0] lookup_cluster,
    input  wire [31:0] first_fat_lba,
    input  wire [31:0] fat_size_sectors,

    output wire        lookup_busy,
    output reg         lookup_done,
    output reg         lookup_ok,
    output reg         lookup_eof,
    output reg  [31:0] next_cluster,
    output reg  [7:0]  error_code,
    output reg  [7:0]  reader_error_code,

    output wire        reader_req_valid,
    output reg  [31:0] reader_req_lba,
    output reg  [15:0] reader_req_count,
    input  wire        reader_req_ready,
    input  wire        reader_rsp_valid,
    input  wire [7:0]  reader_rsp_data,
    input  wire        reader_rsp_last,
    input  wire [7:0]  reader_rsp_error
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_REQ   = 3'd1;
    localparam [2:0] ST_DATA  = 3'd2;
    localparam [2:0] ST_DONE  = 3'd3;
    localparam [2:0] ST_ERROR = 3'd4;

    localparam [7:0] ERR_PARAMS    = 8'h01;
    localparam [7:0] ERR_READER    = 8'h02;
    localparam [7:0] ERR_MALFORMED = 8'h03;
    localparam [7:0] ERR_BAD_CLUSTER = 8'h04;
    localparam [7:0] ERR_TIMEOUT   = 8'h05;

    reg [2:0] state;
    reg [31:0] lookup_cluster_reg;
    reg [8:0]  entry_offset;
    reg [8:0]  sector_byte_index;
    reg [31:0] fat_value;
    reg [31:0] wait_count;
    wire [31:0] fat_value_complete = {reader_rsp_data, fat_value[23:0]};
    // When the fourth FAT-entry byte is also the last byte of the sector,
    // evaluate the newly presented byte in the same cycle instead of waiting
    // for its nonblocking register update.
    wire [31:0] fat_value_eval =
        (sector_byte_index == entry_offset + 2'b11) ?
        fat_value_complete : fat_value;
    // FAT32 allocates 28 bits per entry. The upper four bits are reserved and
    // must not affect end-of-chain or cluster validation.
    wire [27:0] fat_entry_value = fat_value_eval[27:0];

    assign reader_req_valid = (state == ST_REQ);
    assign lookup_busy = (state == ST_REQ) || (state == ST_DATA);

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            lookup_cluster_reg<= 32'd0;
            entry_offset      <= 9'd0;
            sector_byte_index <= 9'd0;
            fat_value         <= 32'd0;
            wait_count        <= 32'd0;
            reader_req_lba    <= 32'd0;
            reader_req_count  <= 16'd0;
            lookup_done       <= 1'b0;
            lookup_ok         <= 1'b0;
            lookup_eof        <= 1'b0;
            next_cluster      <= 32'd0;
            error_code        <= 8'd0;
            reader_error_code <= 8'd0;
        end else begin
            lookup_done <= 1'b0;
            case (state)
                ST_IDLE, ST_DONE, ST_ERROR: begin
                    if (lookup_start) begin
                        lookup_ok          <= 1'b0;
                        lookup_eof         <= 1'b0;
                        error_code         <= 8'd0;
                        reader_error_code  <= 8'd0;
                        next_cluster       <= 32'd0;
                        lookup_cluster_reg <= lookup_cluster;
                        entry_offset       <= {lookup_cluster[6:0], 2'b00};
                        sector_byte_index  <= 9'd0;
                        fat_value          <= 32'd0;
                        wait_count         <= 32'd0;
                        if ((lookup_cluster < 32'd2) ||
                            (fat_size_sectors == 32'd0) ||
                            ((lookup_cluster >> 7) >= fat_size_sectors)) begin
                            error_code <= ERR_PARAMS;
                            state      <= ST_ERROR;
                            lookup_done<= 1'b1;
                        end else begin
                            reader_req_lba   <= first_fat_lba + (lookup_cluster >> 7);
                            reader_req_count <= 16'd1;
                            state            <= ST_REQ;
                        end
                    end
                end

                ST_REQ: begin
                    if (reader_req_ready) begin
                        sector_byte_index <= 9'd0;
                        wait_count        <= 32'd0;
                        state             <= ST_DATA;
                    end else if (wait_count >= RESPONSE_TIMEOUT_CYCLES - 1) begin
                        error_code  <= ERR_TIMEOUT;
                        state       <= ST_ERROR;
                        lookup_done <= 1'b1;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_DATA: begin
                    if (reader_rsp_error != 8'd0) begin
                        reader_error_code <= reader_rsp_error;
                        error_code  <= ERR_READER;
                        state       <= ST_ERROR;
                        lookup_done <= 1'b1;
                    end else if (reader_rsp_valid) begin
                        wait_count <= 32'd0;
                        if (sector_byte_index == entry_offset)
                            fat_value[7:0] <= reader_rsp_data;
                        if (sector_byte_index == entry_offset + 1'b1)
                            fat_value[15:8] <= reader_rsp_data;
                        if (sector_byte_index == entry_offset + 2'b10)
                            fat_value[23:16] <= reader_rsp_data;
                        if (sector_byte_index == entry_offset + 2'b11)
                            fat_value[31:24] <= reader_rsp_data;

                        if (reader_rsp_last) begin
                            if (sector_byte_index != 9'd511) begin
                                error_code  <= ERR_MALFORMED;
                                state       <= ST_ERROR;
                                lookup_done <= 1'b1;
                            end else if (fat_entry_value >= 28'hFFFFFF8) begin
                                lookup_eof  <= 1'b1;
                                lookup_ok   <= 1'b1;
                                lookup_done <= 1'b1;
                                state       <= ST_DONE;
                            end else if (fat_entry_value == 28'hFFFFFF7) begin
                                error_code  <= ERR_BAD_CLUSTER;
                                state       <= ST_ERROR;
                                lookup_done <= 1'b1;
                            end else if ((fat_entry_value < 28'd2) ||
                                         (fat_entry_value > 28'hFFFFFEF)) begin
                                error_code  <= ERR_BAD_CLUSTER;
                                state       <= ST_ERROR;
                                lookup_done <= 1'b1;
                            end else begin
                                next_cluster <= {4'd0, fat_entry_value};
                                lookup_ok    <= 1'b1;
                                lookup_done  <= 1'b1;
                                state        <= ST_DONE;
                            end
                        end else if (sector_byte_index != 9'd511) begin
                            sector_byte_index <= sector_byte_index + 1'b1;
                        end
                end else if (wait_count >= RESPONSE_TIMEOUT_CYCLES - 1) begin
                        error_code  <= ERR_TIMEOUT;
                        state       <= ST_ERROR;
                        lookup_done <= 1'b1;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                default: begin
                    state <= ST_ERROR;
                end
            endcase
        end
    end
endmodule
