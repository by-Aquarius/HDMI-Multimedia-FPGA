// -----------------------------------------------------------------------------
// fat32_bpb_parser.v
// C04: read-only MBR partition and FAT32 BPB parser.
//
// Address contract:
//   * reader_req_lba is an LBA/sector address, not a byte address.
//   * reader_req_count is one 512-byte sector for each parser request.
//   * The reader response is the C03 rsp_valid/rsp_data/rsp_last/rsp_error
//     byte stream.
//
// The parser reads MBR LBA 0, then the first MBR FAT32 partition boot sector.
// It intentionally does not support GPT, exFAT, NTFS, or card modification.
// -----------------------------------------------------------------------------
module fat32_bpb_parser (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        start,

    output wire        reader_req_valid,
    output wire [31:0] reader_req_lba,
    output wire [15:0] reader_req_count,
    input  wire        reader_req_ready,

    input  wire        reader_rsp_valid,
    input  wire [7:0]  reader_rsp_data,
    input  wire        reader_rsp_last,
    input  wire [7:0]  reader_rsp_error,

    output wire        busy,
    output reg         done,
    output reg         fat32_valid,
    output reg  [7:0]  error_code,

    output reg  [7:0]  partition_type,
    output reg [31:0]  partition_start_lba,
    output reg [15:0]  bytes_per_sector,
    output reg  [7:0]  sectors_per_cluster,
    output reg [15:0]  reserved_sector_count,
    output reg  [7:0]  fat_count,
    output reg [31:0]  fat_size_sectors,
    output reg [31:0]  root_cluster,
    output reg [31:0]  total_sectors,
    output reg [31:0]  first_fat_lba,
    output reg [31:0]  first_data_lba,
    output reg [31:0]  cluster_count
);

    localparam [3:0] ST_IDLE          = 4'd0;
    localparam [3:0] ST_REQ_MBR       = 4'd1;
    localparam [3:0] ST_READ_MBR      = 4'd2;
    localparam [3:0] ST_MBR_CHECK     = 4'd3;
    localparam [3:0] ST_REQ_BPB       = 4'd4;
    localparam [3:0] ST_READ_BPB      = 4'd5;
    localparam [3:0] ST_BPB_CHECK     = 4'd6;
    localparam [3:0] ST_CALC_FAT      = 4'd7;
    localparam [3:0] ST_CALC_DATA     = 4'd8;
    localparam [3:0] ST_CALC_CLUSTER  = 4'd9;
    localparam [3:0] ST_LAYOUT_CHECK   = 4'd10;
    localparam [3:0] ST_DONE          = 4'd11;
    localparam [3:0] ST_ERROR         = 4'd12;

    localparam [7:0] ERR_READER          = 8'h01;
    localparam [7:0] ERR_MBR_SIGNATURE   = 8'h02;
    localparam [7:0] ERR_PARTITION_TYPE  = 8'h03;
    localparam [7:0] ERR_BPB_SIGNATURE   = 8'h04;
    localparam [7:0] ERR_BPB_FIELD       = 8'h05;
    localparam [7:0] ERR_BPB_LAYOUT      = 8'h06;

    reg [3:0] state;
    reg [8:0] sector_byte_index;

    reg [7:0]  mbr_sig0_byte;
    reg [7:0]  mbr_sig1_byte;
    reg [7:0]  bpb_sig0_byte;
    reg [7:0]  bpb_sig1_byte;
    reg [15:0] root_entry_count;
    reg [15:0] total_sectors_16;
    reg [15:0] fat_size_16;
    reg [31:0] partition_sector_count;

    // Registered arithmetic pipeline. Each stage is separated by a clock so
    // large multiply/subtract/compare paths do not end at fat32_valid.
    reg [63:0] fat_span_reg;
    reg [63:0] data_sectors_reg;
    reg [63:0] fat_capacity_entries_reg;
    reg [63:0] first_fat_lba_reg;
    reg [63:0] first_data_lba_reg;
    reg [63:0] cluster_count_reg;

    function is_valid_spc;
        input [7:0] value;
        begin
            case (value)
                8'd1, 8'd2, 8'd4, 8'd8,
                8'd16, 8'd32, 8'd64, 8'd128: is_valid_spc = 1'b1;
                default: is_valid_spc = 1'b0;
            endcase
        end
    endfunction

    function [63:0] cluster_count_from_data;
        input [63:0] data_sectors;
        input [7:0]  sectors_per_cluster_value;
        begin
            case (sectors_per_cluster_value)
                8'd1:   cluster_count_from_data = data_sectors;
                8'd2:   cluster_count_from_data = data_sectors >> 1;
                8'd4:   cluster_count_from_data = data_sectors >> 2;
                8'd8:   cluster_count_from_data = data_sectors >> 3;
                8'd16:  cluster_count_from_data = data_sectors >> 4;
                8'd32:  cluster_count_from_data = data_sectors >> 5;
                8'd64:  cluster_count_from_data = data_sectors >> 6;
                8'd128: cluster_count_from_data = data_sectors >> 7;
                default: cluster_count_from_data = 64'd0;
            endcase
        end
    endfunction

    assign reader_req_valid = (state == ST_REQ_MBR) || (state == ST_REQ_BPB);
    assign reader_req_lba   = (state == ST_REQ_BPB) ? partition_start_lba : 32'd0;
    assign reader_req_count = 16'd1;
    assign busy = !((state == ST_IDLE) || (state == ST_DONE) ||
                    (state == ST_ERROR));

    task fail_parser;
        input [7:0] code;
        begin
            error_code  <= code;
            fat32_valid <= 1'b0;
            done        <= 1'b1;
            state       <= ST_ERROR;
        end
    endtask

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= ST_IDLE;
            sector_byte_index      <= 9'd0;
            done                   <= 1'b0;
            fat32_valid            <= 1'b0;
            error_code             <= 8'h00;
            partition_type         <= 8'h00;
            partition_start_lba    <= 32'd0;
            bytes_per_sector       <= 16'd0;
            sectors_per_cluster    <= 8'd0;
            reserved_sector_count  <= 16'd0;
            fat_count              <= 8'd0;
            fat_size_sectors       <= 32'd0;
            root_cluster           <= 32'd0;
            total_sectors          <= 32'd0;
            first_fat_lba          <= 32'd0;
            first_data_lba         <= 32'd0;
            cluster_count          <= 32'd0;
            mbr_sig0_byte          <= 8'h00;
            mbr_sig1_byte          <= 8'h00;
            bpb_sig0_byte          <= 8'h00;
            bpb_sig1_byte          <= 8'h00;
            root_entry_count       <= 16'd0;
            total_sectors_16       <= 16'd0;
            fat_size_16            <= 16'd0;
            partition_sector_count <= 32'd0;
            fat_span_reg           <= 64'd0;
            data_sectors_reg       <= 64'd0;
            fat_capacity_entries_reg <= 64'd0;
            first_fat_lba_reg      <= 64'd0;
            first_data_lba_reg     <= 64'd0;
            cluster_count_reg      <= 64'd0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        fat32_valid       <= 1'b0;
                        error_code        <= 8'h00;
                        sector_byte_index <= 9'd0;
                        state             <= ST_REQ_MBR;
                    end
                end

                ST_REQ_MBR: begin
                    if (reader_req_ready) begin
                        sector_byte_index <= 9'd0;
                        state <= ST_READ_MBR;
                    end
                end

                ST_READ_MBR: begin
                    if (reader_rsp_error != 8'h00) begin
                        fail_parser(ERR_READER);
                    end else if (reader_rsp_valid) begin
                        case (sector_byte_index)
                            9'd450: partition_type <= reader_rsp_data;
                            9'd454: partition_start_lba[7:0] <= reader_rsp_data;
                            9'd455: partition_start_lba[15:8] <= reader_rsp_data;
                            9'd456: partition_start_lba[23:16] <= reader_rsp_data;
                            9'd457: partition_start_lba[31:24] <= reader_rsp_data;
                            9'd458: partition_sector_count[7:0] <= reader_rsp_data;
                            9'd459: partition_sector_count[15:8] <= reader_rsp_data;
                            9'd460: partition_sector_count[23:16] <= reader_rsp_data;
                            9'd461: partition_sector_count[31:24] <= reader_rsp_data;
                            9'd510: mbr_sig0_byte <= reader_rsp_data;
                            9'd511: mbr_sig1_byte <= reader_rsp_data;
                            default: begin end
                        endcase

                        if (sector_byte_index == 9'd511) begin
                            if (reader_rsp_last)
                                state <= ST_MBR_CHECK;
                            else
                                fail_parser(ERR_READER);
                        end else if (reader_rsp_last) begin
                            fail_parser(ERR_READER);
                        end else begin
                            sector_byte_index <= sector_byte_index + 1'b1;
                        end
                    end
                end

                ST_MBR_CHECK: begin
                    if ((mbr_sig0_byte != 8'h55) ||
                        (mbr_sig1_byte != 8'hAA)) begin
                        fail_parser(ERR_MBR_SIGNATURE);
                    end else if ((partition_type != 8'h0B) &&
                                 (partition_type != 8'h0C)) begin
                        fail_parser(ERR_PARTITION_TYPE);
                    end else if ((partition_start_lba == 32'd0) ||
                                 (partition_sector_count == 32'd0)) begin
                        fail_parser(ERR_BPB_LAYOUT);
                    end else begin
                        sector_byte_index <= 9'd0;
                        state <= ST_REQ_BPB;
                    end
                end

                ST_REQ_BPB: begin
                    if (reader_req_ready) begin
                        sector_byte_index <= 9'd0;
                        state <= ST_READ_BPB;
                    end
                end

                ST_READ_BPB: begin
                    if (reader_rsp_error != 8'h00) begin
                        fail_parser(ERR_READER);
                    end else if (reader_rsp_valid) begin
                        case (sector_byte_index)
                            9'd11: bytes_per_sector[7:0] <= reader_rsp_data;
                            9'd12: bytes_per_sector[15:8] <= reader_rsp_data;
                            9'd13: sectors_per_cluster <= reader_rsp_data;
                            9'd14: reserved_sector_count[7:0] <= reader_rsp_data;
                            9'd15: reserved_sector_count[15:8] <= reader_rsp_data;
                            9'd16: fat_count <= reader_rsp_data;
                            9'd17: root_entry_count[7:0] <= reader_rsp_data;
                            9'd18: root_entry_count[15:8] <= reader_rsp_data;
                            9'd19: total_sectors_16[7:0] <= reader_rsp_data;
                            9'd20: total_sectors_16[15:8] <= reader_rsp_data;
                            9'd22: fat_size_16[7:0] <= reader_rsp_data;
                            9'd23: fat_size_16[15:8] <= reader_rsp_data;
                            9'd32: total_sectors[7:0] <= reader_rsp_data;
                            9'd33: total_sectors[15:8] <= reader_rsp_data;
                            9'd34: total_sectors[23:16] <= reader_rsp_data;
                            9'd35: total_sectors[31:24] <= reader_rsp_data;
                            9'd36: fat_size_sectors[7:0] <= reader_rsp_data;
                            9'd37: fat_size_sectors[15:8] <= reader_rsp_data;
                            9'd38: fat_size_sectors[23:16] <= reader_rsp_data;
                            9'd39: fat_size_sectors[31:24] <= reader_rsp_data;
                            9'd44: root_cluster[7:0] <= reader_rsp_data;
                            9'd45: root_cluster[15:8] <= reader_rsp_data;
                            9'd46: root_cluster[23:16] <= reader_rsp_data;
                            9'd47: root_cluster[31:24] <= reader_rsp_data;
                            9'd510: bpb_sig0_byte <= reader_rsp_data;
                            9'd511: bpb_sig1_byte <= reader_rsp_data;
                            default: begin end
                        endcase

                        if (sector_byte_index == 9'd511) begin
                            if (reader_rsp_last)
                                state <= ST_BPB_CHECK;
                            else
                                fail_parser(ERR_READER);
                        end else if (reader_rsp_last) begin
                            fail_parser(ERR_READER);
                        end else begin
                            sector_byte_index <= sector_byte_index + 1'b1;
                        end
                    end
                end

                ST_BPB_CHECK: begin
                    if ((bpb_sig0_byte != 8'h55) ||
                        (bpb_sig1_byte != 8'hAA)) begin
                        fail_parser(ERR_BPB_SIGNATURE);
                    end else if ((bytes_per_sector != 16'd512) ||
                                 !is_valid_spc(sectors_per_cluster) ||
                                 (reserved_sector_count == 16'd0) ||
                                 (fat_count == 8'd0) ||
                                 (root_entry_count != 16'd0) ||
                                 (total_sectors_16 != 16'd0) ||
                                 (fat_size_16 != 16'd0) ||
                                 (fat_size_sectors == 32'd0) ||
                                 (total_sectors == 32'd0) ||
                                 (root_cluster < 32'd2)) begin
                        fail_parser(ERR_BPB_FIELD);
                    end else begin
                        state <= ST_CALC_FAT;
                    end
                end

                ST_CALC_FAT: begin
                    fat_span_reg             <= {56'd0, fat_count} *
                                                 {32'd0, fat_size_sectors};
                    fat_capacity_entries_reg <= {32'd0, fat_size_sectors} *
                                                 64'd128;
                    first_fat_lba_reg        <= {32'd0, partition_start_lba} +
                                                 {48'd0, reserved_sector_count};
                    state <= ST_CALC_DATA;
                end

                ST_CALC_DATA: begin
                    if ({32'd0, total_sectors} <=
                        ({48'd0, reserved_sector_count} + fat_span_reg)) begin
                        fail_parser(ERR_BPB_LAYOUT);
                    end else begin
                        data_sectors_reg   <= {32'd0, total_sectors} -
                                              {48'd0, reserved_sector_count} -
                                              fat_span_reg;
                        first_data_lba_reg <= first_fat_lba_reg + fat_span_reg;
                        state <= ST_CALC_CLUSTER;
                    end
                end

                ST_CALC_CLUSTER: begin
                    cluster_count_reg <= cluster_count_from_data(
                        data_sectors_reg, sectors_per_cluster);
                    state <= ST_LAYOUT_CHECK;
                end

                ST_LAYOUT_CHECK: begin
                    if ((total_sectors > partition_sector_count) ||
                        (cluster_count_reg < 64'd65525) ||
                        (cluster_count_reg > 64'h000000000FFFFFF5) ||
                        (root_cluster > (cluster_count_reg[31:0] + 32'd1)) ||
                        (fat_capacity_entries_reg < (cluster_count_reg + 64'd2)) ||
                        (first_data_lba_reg > 64'h00000000FFFFFFFF)) begin
                        fail_parser(ERR_BPB_LAYOUT);
                    end else begin
                        first_fat_lba  <= first_fat_lba_reg[31:0];
                        first_data_lba <= first_data_lba_reg[31:0];
                        cluster_count  <= cluster_count_reg[31:0];
                        fat32_valid    <= 1'b1;
                        error_code     <= 8'h00;
                        done            <= 1'b1;
                        state           <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    if (start) begin
                        fat32_valid       <= 1'b0;
                        error_code        <= 8'h00;
                        sector_byte_index <= 9'd0;
                        state             <= ST_REQ_MBR;
                    end
                end

                ST_ERROR: begin
                    if (start) begin
                        fat32_valid       <= 1'b0;
                        error_code        <= 8'h00;
                        sector_byte_index <= 9'd0;
                        state             <= ST_REQ_MBR;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule