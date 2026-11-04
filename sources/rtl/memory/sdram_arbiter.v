// D04 SDRAM arbiter with single-word write and BL=1..8 read-burst clients.
module sdram_arbiter #(
    parameter [20:0] FRAME_A_BASE_WORD   = 21'h00000,
    parameter [20:0] FRAME_B_BASE_WORD   = 21'h40000,
    parameter [20:0] AUDIO_BUF_BASE_WORD = 21'h80000
) (
    input wire clk, input wire rst_n,
    input wire line_urgent,
    input wire wr_valid, output wire wr_ready, input wire [20:0] wr_addr_word,
    input wire [31:0] wr_data, input wire [3:0] wr_strb,
    output reg wr_done, output reg wr_error,
    input wire rd_valid, output wire rd_ready, input wire [20:0] rd_addr_word,
    output reg rd_rsp_valid, output reg [31:0] rd_data, output reg rd_error,
    input wire burst_valid, output wire burst_ready, input wire [20:0] burst_addr_word,
    input wire [3:0] burst_len, output reg burst_rsp_valid,
    output reg [31:0] burst_rsp_data, output reg burst_rsp_last, output reg burst_rsp_error,
    output wire sdram_init_done, output wire busy,
    output reg phy_req_valid, input wire phy_req_ready, output reg phy_req_write,
    output reg [20:0] phy_req_addr_word, output reg [31:0] phy_req_wdata,
    output reg [3:0] phy_req_wstrb, input wire phy_rsp_valid,
    input wire [31:0] phy_rsp_rdata, input wire phy_rsp_error,
    output reg phy_burst_valid, input wire phy_burst_ready,
    output reg [20:0] phy_burst_addr_word, output reg [3:0] phy_burst_len,
    input wire phy_burst_rsp_valid, input wire [31:0] phy_burst_rsp_data,
    input wire phy_burst_rsp_last, input wire phy_burst_rsp_error,
    input wire phy_init_done
);
    localparam [2:0] A_IDLE=3'd0, A_SEND=3'd1, A_WAIT=3'd2,
                     A_BSEND=3'd3, A_BWAIT=3'd4;
    reg [2:0] state;
    reg grant_write;
    reg [20:0] held_addr_word;
    reg [31:0] held_wdata;
    reg [3:0] held_wstrb;
    reg [3:0] held_burst_len;
    reg turn_write;
    wire can_accept = (state==A_IDLE) && phy_init_done;
    // Reserve a complete display refill, including gaps between its bursts.
    // Otherwise alternating front reads/back writes repeatedly close rows and miss deadlines.
    wire choose_write = can_accept && wr_valid && !line_urgent && (turn_write || (!rd_valid && !burst_valid));
    wire choose_burst = can_accept && !choose_write && burst_valid && (!rd_valid || !turn_write);
    wire choose_read = can_accept && !choose_write && !choose_burst && rd_valid;
    assign wr_ready = choose_write;
    assign burst_ready = choose_burst;
    assign rd_ready = choose_read;
    assign sdram_init_done = phy_init_done;
    assign busy = (state != A_IDLE);
    always @* begin
        phy_req_valid = (state==A_SEND);
        phy_req_write = grant_write;
        phy_req_addr_word = held_addr_word;
        phy_req_wdata = held_wdata;
        phy_req_wstrb = held_wstrb;
        phy_burst_valid = (state==A_BSEND);
        phy_burst_addr_word = held_addr_word;
        phy_burst_len = held_burst_len;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=A_IDLE; grant_write<=0; turn_write<=1; held_addr_word<=0;
            held_wdata<=0; held_wstrb<=0; held_burst_len<=0;
            wr_done<=0; wr_error<=0; rd_rsp_valid<=0; rd_data<=0; rd_error<=0;
            burst_rsp_valid<=0; burst_rsp_data<=0; burst_rsp_last<=0; burst_rsp_error<=0;
        end else begin
            wr_done<=0; wr_error<=0; rd_rsp_valid<=0; rd_error<=0;
            burst_rsp_valid<=0; burst_rsp_last<=0; burst_rsp_error<=0;
            case(state)
                A_IDLE: begin
                    if(choose_write) begin
                        grant_write<=1; held_addr_word<=wr_addr_word; held_wdata<=wr_data;
                        held_wstrb<=wr_strb; turn_write<=0; state<=A_SEND;
                    end else if(choose_burst) begin
                        grant_write<=0; held_addr_word<=burst_addr_word;
                        held_burst_len<=burst_len; turn_write<=1; state<=A_BSEND;
                    end else if(choose_read) begin
                        grant_write<=0; held_addr_word<=rd_addr_word; held_wdata<=0;
                        held_wstrb<=0; turn_write<=1; state<=A_SEND;
                    end
                end
                A_SEND: if(phy_req_ready) state<=A_WAIT;
                A_WAIT: if(phy_rsp_valid) begin
                    if(grant_write) begin wr_done<=1; wr_error<=phy_rsp_error; end
                    else begin rd_rsp_valid<=1; rd_data<=phy_rsp_rdata; rd_error<=phy_rsp_error; end
                    state<=A_IDLE;
                end
                A_BSEND: if(phy_burst_ready) state<=A_BWAIT;
                A_BWAIT: if(phy_burst_rsp_valid) begin
                    burst_rsp_valid<=1; burst_rsp_data<=phy_burst_rsp_data;
                    burst_rsp_last<=phy_burst_rsp_last; burst_rsp_error<=phy_burst_rsp_error;
                    if(phy_burst_rsp_last) state<=A_IDLE;
                end
                default: state<=A_IDLE;
            endcase
        end
    end
endmodule
