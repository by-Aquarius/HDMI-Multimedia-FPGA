// -----------------------------------------------------------------------------
// fat32_dir_scanner.v
// C05: FAT32 root-directory scanner, read-only.
//
// Scope:
//   * Scan exactly one root-directory cluster returned by C04.
//   * Parse FAT32 32-byte directory entries.
//   * Accept only 8.3 short names with BMP or WAV extension.
//   * Ignore deleted entries, end marker, LFN entries, volume labels,
//     subdirectories, and non-media files.
//   * FAT cluster-chain traversal is intentionally left for C06.
//
// reader_req_lba is an LBA/sector address. reader_req_count is the number of
// contiguous sectors requested for the root cluster.
// -----------------------------------------------------------------------------
module fat32_dir_scanner #(
    parameter integer INDEX_WIDTH = 4,
    parameter integer MAX_MEDIA_FILES = (1 << INDEX_WIDTH),
    parameter integer SINGLE_SECTOR_READS = 1
) (
    input  wire                         clk_50m,
    input  wire                         rst_n,
    input  wire                         start,

    // C04 FAT32 layout outputs.
    input  wire [31:0]                  first_data_lba,
    input  wire [31:0]                  root_cluster,
    input  wire [7:0]                   sectors_per_cluster,

    // C03 sector-reader request/response stream.
    output wire                         reader_req_valid,
    output reg  [31:0]                  reader_req_lba,
    output reg  [15:0]                  reader_req_count,
    input  wire                         reader_req_ready,
    input  wire                         reader_rsp_valid,
    input  wire [7:0]                   reader_rsp_data,
    input  wire                         reader_rsp_last,
    input  wire [7:0]                   reader_rsp_error,

    output wire                         busy,
    output reg                          done,
    output reg                          fat32_dir_valid,
    output reg  [7:0]                   error_code,

    // Media event stream. media_valid/index_wr_en pulse for one accepted file.
    output reg                          media_valid,
    output reg  [INDEX_WIDTH-1:0]       media_index,
    output reg  [87:0]                  media_name_83,
    output reg  [1:0]                   media_type,
    output reg  [31:0]                  media_first_cluster,
    output reg  [31:0]                  media_file_size,
    output reg  [7:0]                   media_count,

    // Write port for media_index_ram.
    output reg                          index_wr_en,
    output reg  [INDEX_WIDTH-1:0]       index_wr_index,
    output reg  [87:0]                  index_wr_name_83,
    output reg  [1:0]                   index_wr_type,
    output reg  [31:0]                  index_wr_first_cluster,
    output reg  [31:0]                  index_wr_file_size
);

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_REQ   = 3'd1;
    localparam [2:0] ST_DATA  = 3'd2;
    localparam [2:0] ST_DONE  = 3'd3;
    localparam [2:0] ST_ERROR = 3'd4;

    localparam [7:0] ERR_PARAMS    = 8'h01;
    localparam [7:0] ERR_READER    = 8'h02;
    localparam [7:0] ERR_MALFORMED = 8'h03;
    localparam [7:0] ERR_INDEX_FULL = 8'h04;

    localparam [1:0] MEDIA_BMP = 2'd1;
    localparam [1:0] MEDIA_WAV = 2'd2;

    reg [2:0] state;
    reg [63:0] root_lba_wide;
    reg [31:0] root_lba;
    reg [7:0]  root_spc;
    reg [7:0]  dir_sector_index;
    reg [15:0] dir_byte_index;
    reg [5:0]  entry_offset;
    reg        dir_end_seen;

    reg [7:0] entry_first_byte;
    reg [7:0] entry_attr;
    reg [7:0] entry_name [0:10];
    reg [7:0] cluster_hi_lo;
    reg [7:0] cluster_hi_hi;
    reg [7:0] cluster_lo_lo;
    reg [7:0] cluster_lo_hi;
    // Cluster bytes settle before entry offset31; keep emission on its original POS edge.
    reg [31:0] cluster_stage;
    always @(negedge clk_50m) begin
        if (!rst_n) cluster_stage <= 0;
        else cluster_stage <= {cluster_hi_hi,cluster_hi_lo,cluster_lo_hi,cluster_lo_lo};
    end
    reg [7:0] size_b0;
    reg [7:0] size_b1;
    reg [7:0] size_b2;

    wire [63:0] root_cluster_minus_two = {32'd0, root_cluster} - 64'd2;
    wire [63:0] cluster_offset_sectors = root_cluster_minus_two * {56'd0, sectors_per_cluster};
    wire [63:0] root_lba_candidate = {32'd0, first_data_lba} + cluster_offset_sectors;

    assign reader_req_valid = (state == ST_REQ);
    assign busy = (state == ST_REQ) || (state == ST_DATA);

    function [7:0] upper_ascii;
        input [7:0] value;
        begin
            if ((value >= 8'h61) && (value <= 8'h7A))
                upper_ascii = value - 8'h20;
            else
                upper_ascii = value;
        end
    endfunction

    function is_bmp_ext;
        input [7:0] b0;
        input [7:0] b1;
        input [7:0] b2;
        begin
            is_bmp_ext = (upper_ascii(b0) == 8'h42) &&
                         (upper_ascii(b1) == 8'h4D) &&
                         (upper_ascii(b2) == 8'h50);
        end
    endfunction

    function is_wav_ext;
        input [7:0] b0;
        input [7:0] b1;
        input [7:0] b2;
        begin
            is_wav_ext = (upper_ascii(b0) == 8'h57) &&
                         (upper_ascii(b1) == 8'h41) &&
                         (upper_ascii(b2) == 8'h56);
        end
    endfunction

    // Emit one accepted media entry. The current byte is the final file-size
    // byte at directory-entry offset 31.
    task emit_entry;
        input [7:0] final_size_byte;
        reg [31:0] first_cluster_value;
        reg [31:0] file_size_value;
        reg [1:0]  media_type_value;
        reg        is_media;
        begin
            if (entry_first_byte == 8'h00) begin
                dir_end_seen <= 1'b1;
            end else if (!dir_end_seen &&
                         (entry_first_byte != 8'hE5) &&
                         (entry_attr != 8'h0F) &&
                         ((entry_attr & 8'h08) == 8'h00) &&
                         ((entry_attr & 8'h10) == 8'h00)) begin
                first_cluster_value = cluster_stage;
                file_size_value = {final_size_byte, size_b2, size_b1, size_b0};
                media_type_value = 2'd0;
                is_media = 1'b0;
                if (is_bmp_ext(entry_name[8], entry_name[9], entry_name[10])) begin
                    media_type_value = MEDIA_BMP;
                    is_media = 1'b1;
                end else if (is_wav_ext(entry_name[8], entry_name[9], entry_name[10])) begin
                    media_type_value = MEDIA_WAV;
                    is_media = 1'b1;
                end

                if (is_media) begin
                    if (media_count < MAX_MEDIA_FILES) begin
                        media_valid             <= 1'b1;
                        media_index             <= media_count[INDEX_WIDTH-1:0];
                        media_name_83           <= {entry_name[0], entry_name[1],
                                                     entry_name[2], entry_name[3],
                                                     entry_name[4], entry_name[5],
                                                     entry_name[6], entry_name[7],
                                                     entry_name[8], entry_name[9],
                                                     entry_name[10]};
                        media_type              <= media_type_value;
                        media_first_cluster     <= first_cluster_value;
                        media_file_size        <= file_size_value;
                        index_wr_en             <= 1'b1;
                        index_wr_index          <= media_count[INDEX_WIDTH-1:0];
                        index_wr_name_83        <= {entry_name[0], entry_name[1],
                                                     entry_name[2], entry_name[3],
                                                     entry_name[4], entry_name[5],
                                                     entry_name[6], entry_name[7],
                                                     entry_name[8], entry_name[9],
                                                     entry_name[10]};
                        index_wr_type           <= media_type_value;
                        index_wr_first_cluster  <= first_cluster_value;
                        index_wr_file_size      <= file_size_value;
                        media_count             <= media_count + 1'b1;
                    end else begin
                        error_code <= ERR_INDEX_FULL;
                        state      <= ST_ERROR;
                    end
                end
            end
        end
    endtask

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_IDLE;
            reader_req_lba       <= 32'd0;
            reader_req_count     <= 16'd0;
            root_lba             <= 32'd0;
            root_spc             <= 8'd0;
            dir_sector_index     <= 8'd0;
            root_lba_wide        <= 64'd0;
            dir_byte_index       <= 16'd0;
            entry_offset         <= 6'd0;
            dir_end_seen         <= 1'b0;
            entry_first_byte     <= 8'd0;
            entry_attr           <= 8'd0;
            cluster_hi_lo        <= 8'd0;
            cluster_hi_hi        <= 8'd0;
            cluster_lo_lo        <= 8'd0;
            cluster_lo_hi        <= 8'd0;
            size_b0              <= 8'd0;
            size_b1              <= 8'd0;
            size_b2              <= 8'd0;
            done                 <= 1'b0;
            fat32_dir_valid      <= 1'b0;
            error_code           <= 8'd0;
            media_valid          <= 1'b0;
            media_index          <= {INDEX_WIDTH{1'b0}};
            media_name_83        <= 88'd0;
            media_type           <= 2'd0;
            media_first_cluster  <= 32'd0;
            media_file_size      <= 32'd0;
            media_count          <= 8'd0;
            index_wr_en          <= 1'b0;
            index_wr_index       <= {INDEX_WIDTH{1'b0}};
            index_wr_name_83     <= 88'd0;
            index_wr_type        <= 2'd0;
            index_wr_first_cluster <= 32'd0;
            index_wr_file_size   <= 32'd0;
        end else begin
            done        <= 1'b0;
            media_valid <= 1'b0;
            index_wr_en <= 1'b0;

            case (state)
                ST_IDLE, ST_DONE, ST_ERROR: begin
                    if (start) begin
                        done            <= 1'b0;
                        fat32_dir_valid<= 1'b0;
                        error_code     <= 8'd0;
                        media_count    <= 8'd0;
                        dir_sector_index <= 8'd0;
                        dir_byte_index <= 16'd0;
                        entry_offset   <= 6'd0;
                        dir_end_seen   <= 1'b0;
                        root_lba_wide  <= root_lba_candidate;
                        root_spc       <= sectors_per_cluster;
                        if ((root_cluster < 32'd2) ||
                            (sectors_per_cluster == 8'd0) ||
                            (root_lba_candidate[63:32] != 32'd0)) begin
                            error_code <= ERR_PARAMS;
                            state      <= ST_ERROR;
                        end else begin
                            root_lba         <= root_lba_candidate[31:0];
                            reader_req_lba   <= root_lba_candidate[31:0];
                            reader_req_count <= (SINGLE_SECTOR_READS != 0) ? 16'd1 : {8'd0, sectors_per_cluster};
                            state            <= ST_REQ;
                        end
                    end
                end

                ST_REQ: begin
                    if (reader_req_ready) begin
                        entry_offset <= 6'd0;
                        state          <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    if (reader_rsp_error != 8'd0) begin
                        error_code <= ERR_READER;
                        state      <= ST_ERROR;
                    end else if (reader_rsp_valid) begin
                        if (entry_offset == 6'd0)
                            entry_first_byte <= reader_rsp_data;
                        if (entry_offset <= 6'd10)
                            entry_name[entry_offset] <= reader_rsp_data;
                        if (entry_offset == 6'd11)
                            entry_attr <= reader_rsp_data;
                        if (entry_offset == 6'd20)
                            cluster_hi_lo <= reader_rsp_data;
                        if (entry_offset == 6'd21)
                            cluster_hi_hi <= reader_rsp_data;
                        if (entry_offset == 6'd26)
                            cluster_lo_lo <= reader_rsp_data;
                        if (entry_offset == 6'd27)
                            cluster_lo_hi <= reader_rsp_data;
                        if (entry_offset == 6'd28)
                            size_b0 <= reader_rsp_data;
                        if (entry_offset == 6'd29)
                            size_b1 <= reader_rsp_data;
                        if (entry_offset == 6'd30)
                            size_b2 <= reader_rsp_data;
                        if (entry_offset == 6'd31)
                            emit_entry(reader_rsp_data);

                        dir_byte_index <= dir_byte_index + 1'b1;
                        if (entry_offset == 6'd31)
                            entry_offset <= 6'd0;
                        else
                            entry_offset <= entry_offset + 1'b1;

                        if (reader_rsp_last) begin
                            if (entry_offset != 6'd31) begin
                                error_code <= ERR_MALFORMED;
                                state      <= ST_ERROR;
                            end else if ((SINGLE_SECTOR_READS != 0) &&
                                         !dir_end_seen &&
                                         (dir_sector_index + 1'b1 < root_spc)) begin
                                dir_sector_index <= dir_sector_index + 1'b1;
                                reader_req_lba   <= root_lba + dir_sector_index + 1'd1;
                                reader_req_count <= 16'd1;
                                state            <= ST_REQ;
                            end else if (error_code == 8'd0) begin
                                fat32_dir_valid <= 1'b1;
                                done            <= 1'b1;
                                state           <= ST_DONE;
                            end
                        end
                    end
                end

                default: begin
                    state <= ST_ERROR;
                end
            endcase
        end
    end
endmodule
