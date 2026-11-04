// -----------------------------------------------------------------------------
// media_index_ram.v
// C05: small synthesizable media metadata table.
// Stores 8.3 name, media type, first cluster, and byte size.
// -----------------------------------------------------------------------------
module media_index_ram #(
    parameter integer INDEX_WIDTH = 4,
    parameter integer DEPTH = (1 << INDEX_WIDTH)
) (
    input  wire                         clk_50m,
    input  wire                         rst_n,
    input  wire                         clear,

    input  wire                         wr_en,
    input  wire [INDEX_WIDTH-1:0]       wr_index,
    input  wire [87:0]                  wr_name_83,
    input  wire [1:0]                   wr_type,
    input  wire [31:0]                  wr_first_cluster,
    input  wire [31:0]                  wr_file_size,

    input  wire                         rd_en,
    input  wire [INDEX_WIDTH-1:0]       rd_index,
    output reg                          rd_valid,
    output reg  [87:0]                  rd_name_83,
    output reg  [1:0]                   rd_type,
    output reg  [31:0]                  rd_first_cluster,
    output reg  [31:0]                  rd_file_size,
    output reg  [INDEX_WIDTH:0]         item_count
);

    reg [87:0] name_mem [0:DEPTH-1];
    reg [1:0]  type_mem [0:DEPTH-1];
    reg [31:0] cluster_mem [0:DEPTH-1];
    reg [31:0] size_mem [0:DEPTH-1];

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid         <= 1'b0;
            rd_name_83       <= 88'd0;
            rd_type          <= 2'd0;
            rd_first_cluster <= 32'd0;
            rd_file_size     <= 32'd0;
            item_count       <= {(INDEX_WIDTH+1){1'b0}};
        end else begin
            rd_valid <= 1'b0;
            if (clear) begin
                item_count <= {(INDEX_WIDTH+1){1'b0}};
            end else begin
                if (wr_en) begin
                    name_mem[wr_index]    <= wr_name_83;
                    type_mem[wr_index]    <= wr_type;
                    cluster_mem[wr_index] <= wr_first_cluster;
                    size_mem[wr_index]    <= wr_file_size;
                    if ({1'b0, wr_index} >= item_count)
                        item_count <= {1'b0, wr_index} + 1'b1;
                end
                if (rd_en && ({1'b0, rd_index} < item_count)) begin
                    rd_name_83       <= name_mem[rd_index];
                    rd_type          <= type_mem[rd_index];
                    rd_first_cluster <= cluster_mem[rd_index];
                    rd_file_size     <= size_mem[rd_index];
                    rd_valid         <= 1'b1;
                end
            end
        end
    end
endmodule