// -----------------------------------------------------------------------------
// fat32_cluster_reader.v
// R263: pipelined, read-only FAT32 file byte-stream reader.
//
// The reader follows FAT entries and never assumes clusters are contiguous.
// C03 requests are single-sector reads, so this module does not require CMD12
// cleanup for a file cluster. FAT traversal is delegated to fat32_fat_cache.
// Cluster address arithmetic is split across registered stages so the external
// request mux never receives a multiply/add/select chain in one clock period.
// -----------------------------------------------------------------------------
module fat32_cluster_reader #(
    parameter integer FAT_RESPONSE_TIMEOUT_CYCLES = 262144,
    parameter integer WAIT_TIMEOUT_CYCLES         = 4096
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        start,
    input wire request_pause,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size_bytes,

    input  wire [31:0] first_data_lba,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] first_fat_lba,
    input  wire [31:0] fat_size_sectors,

    // Shared C03 sector-reader interface.
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
    output reg  [7:0]  error_code,
    output reg  [7:0]  error_detail,
    output reg         byte_valid,
    output reg  [7:0]  byte_data,
    output reg         byte_last
);

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_DATA_REQ   = 4'd1;
    localparam [3:0] ST_DATA_STREAM = 4'd2;
    localparam [3:0] ST_DATA_DRAIN = 4'd3;
    localparam [3:0] ST_FAT_START  = 4'd4;
    localparam [3:0] ST_FAT_WAIT   = 4'd5;
    localparam [3:0] ST_DONE       = 4'd6;
    localparam [3:0] ST_ERROR      = 4'd7;
    localparam [3:0] ST_FAT_RETRY  = 4'd8;
    localparam [3:0] ST_LBA_DELTA  = 4'd9;
    localparam [3:0] ST_LBA_SCALE  = 4'd10;
    localparam [3:0] ST_LBA_BASE   = 4'd11;
    localparam [3:0] ST_DATA_PREP  = 4'd12;

    localparam [7:0] ERR_PARAMS       = 8'h01;
    localparam [7:0] ERR_READER       = 8'h02;
    localparam [7:0] ERR_FAT          = 8'h03;
    localparam [7:0] ERR_EOF_EARLY    = 8'h04;
    localparam [7:0] ERR_TIMEOUT      = 8'h05;

    reg [3:0]  state;
    reg [31:0] current_cluster;
    reg [31:0] bytes_remaining;
    reg [7:0]  cluster_sector_index;
    reg [9:0]  sector_byte_index;
    reg [31:0] wait_count;
    reg        data_active;
    reg        fat_active;
    reg [1:0]  fat_retry_count;
    reg [39:0] cluster_delta_q;
    reg [39:0] cluster_offset_q;
    reg [39:0] cluster_lba_sum_q;
    reg [31:0] data_req_lba_q;
    localparam [31:0] FAT_RETRY_GAP_CYCLES = 32'd1024;

    wire fat_lookup_start;
    wire fat_lookup_busy;
    wire fat_lookup_done;
    wire fat_lookup_ok;
    wire fat_lookup_eof;
    wire [31:0] fat_next_cluster;
    wire [7:0] fat_error;
    wire [7:0] fat_reader_error;
    wire fat_req_valid;
    wire [31:0] fat_req_lba;
    wire [15:0] fat_req_count;
    wire fat_req_ready;
    wire fat_rsp_valid;
    wire [7:0] fat_rsp_data;
    wire fat_rsp_last;
    wire [7:0] fat_rsp_error;

    wire data_req_valid;
    wire [31:0] data_req_lba;
    wire [15:0] data_req_count = 16'd1;
    wire data_req_ready;
    wire data_rsp_valid;
    wire [7:0] data_rsp_data;
    wire data_rsp_last;
    wire [7:0] data_rsp_error;

    assign data_req_lba = data_req_lba_q;

    assign busy = (state != ST_IDLE) && (state != ST_DONE) && (state != ST_ERROR);
    assign fat_lookup_start = (state == ST_FAT_START);
    assign data_req_valid = (state == ST_DATA_REQ);

    assign reader_req_valid = fat_req_valid | data_req_valid;
    assign reader_req_lba = fat_req_valid ? fat_req_lba : data_req_lba;
    assign reader_req_count = fat_req_valid ? fat_req_count : data_req_count;
    assign fat_req_ready = reader_req_ready && fat_req_valid;
    assign data_req_ready = reader_req_ready && data_req_valid && !fat_req_valid;

    assign fat_rsp_valid = reader_rsp_valid && fat_active;
    assign fat_rsp_data  = reader_rsp_data;
    assign fat_rsp_last  = reader_rsp_last;
    assign fat_rsp_error = reader_rsp_error;
    assign data_rsp_valid = reader_rsp_valid && data_active;
    assign data_rsp_data  = reader_rsp_data;
    assign data_rsp_last  = reader_rsp_last;
    assign data_rsp_error = reader_rsp_error;

    fat32_fat_cache #(
        .RESPONSE_TIMEOUT_CYCLES(FAT_RESPONSE_TIMEOUT_CYCLES)
    ) u_fat_cache (
        .clk_50m(clk_50m),
        // A new file request must also terminate an in-flight FAT lookup.
        // Otherwise that sub-FSM can remain busy and ignore the next lookup.
        .rst_n(rst_n && !start),
        .lookup_start(fat_lookup_start),
        .lookup_cluster(current_cluster),
        .first_fat_lba(first_fat_lba),
        .fat_size_sectors(fat_size_sectors),
        .lookup_busy(fat_lookup_busy),
        .lookup_done(fat_lookup_done),
        .lookup_ok(fat_lookup_ok),
        .lookup_eof(fat_lookup_eof),
        .next_cluster(fat_next_cluster),
        .error_code(fat_error),
        .reader_error_code(fat_reader_error),
        .reader_req_valid(fat_req_valid),
        .reader_req_lba(fat_req_lba),
        .reader_req_count(fat_req_count),
        .reader_req_ready(fat_req_ready),
        .reader_rsp_valid(fat_rsp_valid),
        .reader_rsp_data(fat_rsp_data),
        .reader_rsp_last(fat_rsp_last),
        .reader_rsp_error(fat_rsp_error)
    );

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            current_cluster     <= 32'd0;
            bytes_remaining     <= 32'd0;
            cluster_sector_index<= 8'd0;
            sector_byte_index   <= 10'd0;
            wait_count          <= 32'd0;
            data_active         <= 1'b0;
            fat_active          <= 1'b0;
            fat_retry_count     <= 2'd0;
            cluster_delta_q     <= 40'd0;
            cluster_offset_q    <= 40'd0;
            cluster_lba_sum_q   <= 40'd0;
            data_req_lba_q      <= 32'd0;
            done                <= 1'b0;
            error_code          <= 8'd0;
            error_detail        <= 8'd0;
            byte_valid          <= 1'b0;
            byte_data           <= 8'd0;
            byte_last           <= 1'b0;
        end else begin
            done       <= 1'b0;
            byte_valid <= 1'b0;
            byte_last  <= 1'b0;

            // A new file request has priority over every active state. This
            // is required when the previous BMP failed or the user requested
            // another image: the stale C03 sector is drained by the arbiter,
            // but none of its bytes may enter the new file stream.
            if (start) begin
                error_code           <= 8'd0;
                error_detail        <= 8'd0;
                wait_count           <= 32'd0;
                current_cluster      <= file_first_cluster;
                bytes_remaining      <= file_size_bytes;
                cluster_sector_index <= 8'd0;
                sector_byte_index    <= 10'd0;
                fat_retry_count      <= 2'd0;
                data_active          <= 1'b0;
                fat_active           <= 1'b0;
                if (file_size_bytes == 32'd0) begin
                    done  <= 1'b1;
                    state <= ST_DONE;
                end else if ((file_first_cluster < 32'd2) ||
                             (sectors_per_cluster == 8'd0)) begin
                    error_code <= ERR_PARAMS;
                    error_detail <= 8'd2;
                    state      <= ST_ERROR;
                    done       <= 1'b1;
                end else begin
                    state <= ST_LBA_DELTA;
                end
            end else begin
                if (fat_req_valid && reader_req_ready)
                    fat_active <= 1'b1;
                if (data_req_valid && reader_req_ready)
                    data_active <= 1'b1;
                if (fat_active && (fat_rsp_last || (fat_rsp_error != 8'd0)))
                    fat_active <= 1'b0;
                if (data_active && (data_rsp_last || (data_rsp_error != 8'd0)))
                    data_active <= 1'b0;

                case (state)
                    ST_IDLE, ST_DONE, ST_ERROR: begin
                        // A new request is handled by the start branch above.
                    end

                    ST_LBA_DELTA: begin
                        cluster_delta_q <= {8'd0, current_cluster} - 40'd2;
                        state <= ST_LBA_SCALE;
                    end

                    ST_LBA_SCALE: begin
                        // FAT32 permits only power-of-two cluster sizes. The BPB
                        // parser enforces this, and the local case keeps this
                        // module fail-closed when it is used independently.
                        case (sectors_per_cluster)
                            8'd1:   cluster_offset_q <= cluster_delta_q;
                            8'd2:   cluster_offset_q <= cluster_delta_q << 1;
                            8'd4:   cluster_offset_q <= cluster_delta_q << 2;
                            8'd8:   cluster_offset_q <= cluster_delta_q << 3;
                            8'd16:  cluster_offset_q <= cluster_delta_q << 4;
                            8'd32:  cluster_offset_q <= cluster_delta_q << 5;
                            8'd64:  cluster_offset_q <= cluster_delta_q << 6;
                            8'd128: cluster_offset_q <= cluster_delta_q << 7;
                            default: begin
                                error_code   <= ERR_PARAMS;
                                error_detail <= 8'd3;
                                done         <= 1'b1;
                                state        <= ST_ERROR;
                            end
                        endcase
                        if ((sectors_per_cluster == 8'd1) ||
                            (sectors_per_cluster == 8'd2) ||
                            (sectors_per_cluster == 8'd4) ||
                            (sectors_per_cluster == 8'd8) ||
                            (sectors_per_cluster == 8'd16) ||
                            (sectors_per_cluster == 8'd32) ||
                            (sectors_per_cluster == 8'd64) ||
                            (sectors_per_cluster == 8'd128))
                            state <= ST_LBA_BASE;
                    end

                    ST_LBA_BASE: begin
                        cluster_lba_sum_q <= {8'd0, first_data_lba} +
                                             cluster_offset_q;
                        if (({8'd0, first_data_lba} + cluster_offset_q) >
                            40'hFF_FFFF_FFFF)
                            begin
                                error_code   <= ERR_PARAMS;
                                error_detail <= 8'd4;
                                done         <= 1'b1;
                                state        <= ST_ERROR;
                            end else begin
                                state <= ST_DATA_PREP;
                            end
                    end

                    ST_DATA_PREP: begin
                        if ((cluster_lba_sum_q +
                             {32'd0, cluster_sector_index}) >
                            40'hFF_FFFF_FFFF)
                            begin
                                error_code   <= ERR_PARAMS;
                                error_detail <= 8'd5;
                                done         <= 1'b1;
                                state        <= ST_ERROR;
                            end else begin
                                data_req_lba_q <= cluster_lba_sum_q +
                                                  {32'd0, cluster_sector_index};
                                state <= ST_DATA_REQ;
                            end
                    end

                    ST_DATA_REQ: begin
                        if (data_req_ready) begin
                            sector_byte_index <= 10'd0;
                            wait_count <= 32'd0;
                            state <= ST_DATA_STREAM;
                        end else if (request_pause) begin
                            // No sector was accepted: consumer pause is not a card failure.
                            wait_count <= 32'd0;
                        end else if (wait_count >= WAIT_TIMEOUT_CYCLES - 1) begin
                            error_code <= ERR_TIMEOUT;
                            state <= ST_ERROR;
                            done <= 1'b1;
                        end else begin
                            wait_count <= wait_count + 1'b1;
                        end
                    end

                    ST_DATA_STREAM: begin
                        if (data_rsp_error != 8'd0) begin
                            error_code <= ERR_READER;
                            error_detail <= 8'h08 | data_rsp_error[3:0];
                            state <= ST_ERROR;
                            done <= 1'b1;
                        end else if (data_rsp_valid) begin
                            wait_count <= 32'd0;
                            if (bytes_remaining != 32'd0) begin
                                byte_valid <= 1'b1;
                                byte_data  <= data_rsp_data;
                                if (bytes_remaining == 32'd1) begin
                                    byte_last <= 1'b1;
                                    bytes_remaining <= 32'd0;
                                    if (data_rsp_last) begin
                                        done <= 1'b1;
                                        state <= ST_DONE;
                                    end else begin
                                        state <= ST_DATA_DRAIN;
                                    end
                                end else begin
                                    bytes_remaining <= bytes_remaining - 1'b1;
                                end
                            end
                            if (data_rsp_last && (bytes_remaining != 32'd1)) begin
                                if (sector_byte_index == 10'd511) begin
                                    if (cluster_sector_index + 1'b1 < sectors_per_cluster) begin
                                        cluster_sector_index <= cluster_sector_index + 1'b1;
                                        state <= ST_DATA_PREP;
                                    end else begin
                                        state <= ST_FAT_START;
                                    end
                                end else begin
                                    error_code <= ERR_READER;
                                    state <= ST_ERROR;
                                    done <= 1'b1;
                                end
                            end else if (!data_rsp_last && (sector_byte_index != 10'd511)) begin
                                sector_byte_index <= sector_byte_index + 1'b1;
                            end
                        end else if (wait_count >= WAIT_TIMEOUT_CYCLES - 1) begin
                            error_code <= ERR_TIMEOUT;
                            state <= ST_ERROR;
                            done <= 1'b1;
                        end else begin
                            wait_count <= wait_count + 1'b1;
                        end
                    end

                    ST_DATA_DRAIN: begin
                        if (data_rsp_error != 8'd0) begin
                            error_code <= ERR_READER;
                            state <= ST_ERROR;
                            done <= 1'b1;
                        end else if (data_rsp_last) begin
                            done <= 1'b1;
                            state <= ST_DONE;
                        end else if (wait_count >= WAIT_TIMEOUT_CYCLES - 1) begin
                            error_code <= ERR_TIMEOUT;
                            state <= ST_ERROR;
                            done <= 1'b1;
                        end else begin
                            wait_count <= wait_count + 1'b1;
                        end
                    end

                    ST_FAT_START: begin
                        wait_count <= 32'd0;
                        state <= ST_FAT_WAIT;
                    end

                    ST_FAT_WAIT: begin
                        if (fat_lookup_done) begin
                            wait_count <= 32'd0;
                            if (fat_error != 8'd0) begin
                                if (fat_retry_count < 2'd3) begin
                                    fat_retry_count <= fat_retry_count + 1'b1;
                                    wait_count <= 32'd0;
                                    state <= ST_FAT_RETRY;
                                end else begin
                                    error_code <= ERR_FAT;
                                    error_detail <= (fat_error == ERR_READER) ?
                                                    (8'h08 | fat_reader_error[3:0]) :
                                                    fat_error;
                                    state <= ST_ERROR;
                                    done <= 1'b1;
                                end
                            end else if (fat_lookup_eof) begin
                                if (bytes_remaining == 32'd0) begin
                                    done <= 1'b1;
                                    state <= ST_DONE;
                                end else begin
                                    error_code <= ERR_EOF_EARLY;
                                    state <= ST_ERROR;
                                    done <= 1'b1;
                                end
                            end else if (fat_lookup_ok) begin
                                fat_retry_count <= 2'd0;
                                current_cluster <= fat_next_cluster;
                                cluster_sector_index <= 8'd0;
                                state <= ST_LBA_DELTA;
                            end
                        end else if (wait_count >= WAIT_TIMEOUT_CYCLES - 1) begin
                            error_code <= ERR_TIMEOUT;
                            state <= ST_ERROR;
                            done <= 1'b1;
                        end else begin
                            wait_count <= wait_count + 1'b1;
                        end
                    end

                    ST_FAT_RETRY: begin
                        if (wait_count >= FAT_RETRY_GAP_CYCLES - 1) begin
                            wait_count <= 32'd0;
                            state <= ST_FAT_START;
                        end else begin
                            wait_count <= wait_count + 1'b1;
                        end
                    end

                    default: begin
                        state <= ST_ERROR;
                        error_code <= ERR_PARAMS;
                        done <= 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
