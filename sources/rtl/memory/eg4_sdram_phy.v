// -----------------------------------------------------------------------------
// eg4_sdram_phy.v
// D04: EG4S20BG256 integrated 2M x 32 SDRAM transaction PHY/controller.
//
// Address contract (fixed):
//   req_addr_word is a 21-bit SDRAM WORD address. One word is 32 bits/4 bytes.
//   byte_addr[23:2] == req_addr_word; byte_addr[1:0] are byte-in-word bits.
//   Physical address mapping: {bank[1:0], row[10:0], column[7:0]}.
//
// This module provides a single-outstanding, one-word transaction interface.
// A later frame/line layer may issue bursts as a sequence of word requests, but
// it must not drive random requests directly from the pixel clock domain.
// The physical pins are the EG4 integrated-SDRAM pins. In the formal top they
// are connected to the device's 2M x 32 SDRAM primitive/pin wrapper.
// -----------------------------------------------------------------------------
module eg4_sdram_phy #(
    parameter integer INIT_WAIT_CYCLES        = 10000, // 200 us @ 50 MHz
    parameter integer TRP_CYCLES              = 2,
    parameter integer TRCD_CYCLES             = 2,
    parameter integer CAS_LATENCY             = 3,
    parameter integer TRSC_CYCLES             = 2,
    parameter integer TRFC_CYCLES             = 7,
    parameter integer REFRESH_INTERVAL_CYCLES = 390,   // ~7.8 us @ 50 MHz
    parameter integer REQUEST_TIMEOUT_CYCLES  = 4095
) (
    input  wire        clk,
    input  wire        rst_n,

    // One outstanding transaction. Address is SDRAM word address, not bytes.
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [20:0] req_addr_word,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,

    // Read burst interface: BL is 1..8 words and must not cross an SDRAM row.
    input  wire        burst_req_valid,
    output wire        burst_req_ready,
    input  wire [20:0] burst_req_addr_word,
    input  wire [3:0]  burst_req_len,
    output reg         burst_rsp_valid,
    output wire [31:0] burst_rsp_rdata,
    output reg         burst_rsp_last,
    output reg         burst_rsp_error,

    output reg         rsp_valid,
    output wire [31:0] rsp_rdata,
    output reg         rsp_error,
    output reg         timeout_error,
    output reg         init_done,

    // EG4 integrated SDRAM physical interface.
    output wire        sdram_clk,
    output reg         sdram_cke,
    output reg         sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n,
    output reg  [1:0]  sdram_ba,
    output reg  [10:0] sdram_addr,
    inout  wire [31:0] sdram_dq,
    output reg  [3:0]  sdram_dqm
);

    localparam [4:0] ST_POWERUP       = 5'd0;
    localparam [4:0] ST_INIT_PRE      = 5'd1;
    localparam [4:0] ST_INIT_TRP      = 5'd2;
    localparam [4:0] ST_INIT_AR1      = 5'd3;
    localparam [4:0] ST_INIT_AR1_WAIT = 5'd4;
    localparam [4:0] ST_INIT_AR2      = 5'd5;
    localparam [4:0] ST_INIT_AR2_WAIT = 5'd6;
    localparam [4:0] ST_INIT_MRS      = 5'd7;
    localparam [4:0] ST_INIT_MRS_WAIT = 5'd8;
    localparam [4:0] ST_IDLE          = 5'd9;
    localparam [4:0] ST_ACTIVATE      = 5'd10;
    localparam [4:0] ST_RCD_WAIT      = 5'd11;
    localparam [4:0] ST_READ_CMD      = 5'd12;
    localparam [4:0] ST_READ_WAIT     = 5'd13;
    localparam [4:0] ST_WRITE_CMD     = 5'd14;
    localparam [4:0] ST_WRITE_HOLD    = 5'd15;
    localparam [4:0] ST_PRECHARGE     = 5'd16;
    localparam [4:0] ST_TRP_WAIT      = 5'd17;
    localparam [4:0] ST_REFRESH       = 5'd18;
    localparam [4:0] ST_TRFC_WAIT     = 5'd19;
    localparam [4:0] ST_BURST_READ_CMD = 5'd20;
    localparam [4:0] ST_BURST_WAIT     = 5'd21;
    localparam [4:0] ST_BURST_DATA     = 5'd22;

    localparam [4:0] ST_READ_STOP=5'd23, ST_READ_DRAIN=5'd24, ST_CKE_WAKE=5'd25;
    function integer count_width;
        input integer limit;
        integer value;
        begin value=limit-1;count_width=0;
            while(value>0) begin count_width=count_width+1;value=value>>1;end
            if(count_width<1)count_width=1;
        end
    endfunction
    localparam integer TIMER_WIDTH=count_width(INIT_WAIT_CYCLES>64 ? INIT_WAIT_CYCLES+1 : 65);
    localparam integer OP_WIDTH=count_width(REQUEST_TIMEOUT_CYCLES>0 ? REQUEST_TIMEOUT_CYCLES+1 : 2);
    localparam integer REFRESH_WIDTH=count_width(REFRESH_INTERVAL_CYCLES>0 ? REFRESH_INTERVAL_CYCLES+1 : 2);
    reg cleanup_precharge;
    reg [31:0] dq_sample, read_return;
    assign rsp_rdata=read_return;
    assign burst_rsp_rdata=read_return;
    // Unconditional sampling removes the FSM-enable LUT from the physical input path.
    always @(posedge clk) dq_sample<=sdram_dq;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) read_return<=32'd0;
        else read_return<=dq_sample;
    end
    reg [4:0]  state;
    reg [TIMER_WIDTH-1:0] timer;
    reg [OP_WIDTH-1:0] op_timer;
    reg [REFRESH_WIDTH-1:0] refresh_timer;

    reg        op_write;
    reg        burst_mode;
    reg [3:0]  burst_len_hold;
    reg [3:0]  burst_count;
    reg [20:0] op_addr_word;
    reg [31:0] op_wdata;
    reg [3:0]  op_wstrb;

    // Keep an SDRAM row open across adjacent word transactions.
    reg        row_open;
    reg [1:0]  open_bank;
    reg [10:0] open_row;
    reg        precharge_to_activate;
    reg        precharge_to_refresh;

    wire req_same_open_row = row_open &&
                             (req_addr_word[20:19] == open_bank) &&
                             (req_addr_word[18:8]  == open_row);
    wire burst_same_open_row = row_open &&
                             (burst_req_addr_word[20:19] == open_bank) &&
                             (burst_req_addr_word[18:8]  == open_row);

    wire transaction_state =
        (state == ST_ACTIVATE)   || (state == ST_RCD_WAIT) ||
        (state == ST_READ_CMD)   || (state == ST_READ_WAIT) ||
        (state == ST_WRITE_CMD)  || (state == ST_WRITE_HOLD) ||
        (state == ST_PRECHARGE)  || (state == ST_TRP_WAIT) ||
        (state == ST_BURST_READ_CMD) || (state == ST_BURST_WAIT) ||
        (state == ST_BURST_DATA);

    wire refresh_due = (REFRESH_INTERVAL_CYCLES > 0) &&
                       (refresh_timer >= REFRESH_INTERVAL_CYCLES - 1);
    assign req_ready = init_done && (state == ST_IDLE) && !refresh_due && !burst_req_valid;
    assign burst_req_ready = init_done && (state == ST_IDLE) && !refresh_due;
    assign sdram_clk = clk;

    // The EG4 primitive/pin wrapper is external to this transaction module.
    // During a write command the controller drives all four DQ byte lanes.
    reg        dq_oe;
    reg [31:0] dq_out;
    assign sdram_dq = dq_oe ? dq_out : 32'hzzzz_zzzz;

    reg sdram_cke_next;
    reg sdram_cs_n_next;
    reg sdram_ras_n_next;
    reg sdram_cas_n_next;
    reg sdram_we_n_next;
    reg [1:0] sdram_ba_next;
    reg [10:0] sdram_addr_next;
    reg [3:0] sdram_dqm_next;
    reg dq_oe_next;
    reg [31:0] dq_out_next;
    // Physical command/address decode. All SDRAM commands are active-low.
    always @* begin
        sdram_cke_next  = rst_n && (state != ST_POWERUP);
        sdram_cs_n_next = 1'b0;
        sdram_ras_n_next = 1'b1;
        sdram_cas_n_next = 1'b1;
        sdram_we_n_next  = 1'b1;
        sdram_ba_next    = 2'b00;
        sdram_addr_next  = 11'd0;
        sdram_dqm_next   = 4'hf;
        dq_oe_next       = 1'b0;
        dq_out_next      = op_wdata;

        if (!rst_n) begin
            sdram_cke_next   = 1'b0;
            sdram_cs_n_next  = 1'b1;
            sdram_ras_n_next = 1'b1;
            sdram_cas_n_next = 1'b1;
            sdram_we_n_next  = 1'b1;
        end else begin
            case (state)
                ST_INIT_PRE: begin
                    // PRECHARGE ALL: A10=1.
                    sdram_ras_n_next = 1'b0;
                    sdram_we_n_next  = 1'b0;
                    sdram_addr_next[10] = 1'b1;
                end
                ST_INIT_AR1, ST_INIT_AR2, ST_REFRESH: begin
                    sdram_ras_n_next = 1'b0;
                    sdram_cas_n_next = 1'b0;
                end
                ST_INIT_MRS: begin
                    // Read BL=8, sequential, CAS=3; A9=1 keeps single-word writes single.
                    sdram_ras_n_next = 1'b0;
                    sdram_cas_n_next = 1'b0;
                    sdram_we_n_next  = 1'b0;
                    sdram_ba_next    = 2'b00;
                    sdram_addr_next  = {1'b0,1'b1,2'b00,3'b011,1'b0,3'b011};
                end
                ST_ACTIVATE: begin
                    sdram_ras_n_next = 1'b0;
                    sdram_ba_next    = op_addr_word[20:19];
                    sdram_addr_next  = op_addr_word[18:8];
                end
                ST_READ_CMD: begin
                    sdram_cas_n_next = 1'b0;
                    sdram_ba_next    = op_addr_word[20:19];
                    sdram_addr_next  = {3'b000, op_addr_word[7:0]};
                    // DQM=0 enables the read data bus after CAS latency.
                    sdram_dqm_next   = 4'h0;
                end
                ST_BURST_READ_CMD, ST_BURST_WAIT, ST_BURST_DATA: begin
                    sdram_dqm_next   = 4'h0;
                    if (state == ST_BURST_READ_CMD) begin
                        sdram_cas_n_next = 1'b0;
                        sdram_ba_next    = op_addr_word[20:19];
                        sdram_addr_next  = {3'b000, op_addr_word[7:0]};
                    end
                end
                ST_READ_WAIT: begin
                    // Keep DQM low through the read latency/capture window.
                    sdram_dqm_next   = 4'h0;
                end
                ST_WRITE_CMD, ST_WRITE_HOLD: begin
                    // Keep write data and byte masks stable through the write hold.
                    sdram_dqm_next   = ~op_wstrb;
                    dq_oe_next       = 1'b1;
                    if (state == ST_WRITE_CMD) begin
                        sdram_cas_n_next = 1'b0;
                        sdram_we_n_next  = 1'b0;
                        sdram_ba_next    = op_addr_word[20:19];
                        sdram_addr_next  = {3'b000, op_addr_word[7:0]};
                    end
                end
                ST_READ_STOP: begin
                    sdram_we_n_next=1'b0; // BURST STOP; read bus is drained before ready.
                end
                ST_PRECHARGE: begin
                    sdram_ras_n_next = 1'b0;
                    sdram_we_n_next  = 1'b0;
                    sdram_addr_next[10] = 1'b1;
                end
                default: begin
                    // NOP.
                end
            endcase
        end
    end

    // Core reset releases at NEG; pin reset releases at POS for NEG output flops.
    reg pin_reset_n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pin_reset_n <= 1'b0;
        else pin_reset_n <= 1'b1;
    end
    always @(negedge clk or negedge pin_reset_n) begin
        if(!pin_reset_n) begin
            sdram_cke<=0;sdram_cs_n<=1;sdram_ras_n<=1;sdram_cas_n<=1;sdram_we_n<=1;
            sdram_ba<=0;sdram_addr<=0;sdram_dqm<=4'hf;dq_oe<=0;dq_out<=0;
        end else begin
            sdram_cke<=sdram_cke_next;
            sdram_cs_n<=sdram_cs_n_next;
            sdram_ras_n<=sdram_ras_n_next;
            sdram_cas_n<=sdram_cas_n_next;
            sdram_we_n<=sdram_we_n_next;
            sdram_ba<=sdram_ba_next;
            sdram_addr<=sdram_addr_next;
            sdram_dqm<=sdram_dqm_next;
            dq_oe<=dq_oe_next;
            dq_out<=dq_out_next;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cleanup_precharge<=0;
            state        <= ST_POWERUP;
            timer        <= 32'd0;
            op_timer     <= 32'd0;
            refresh_timer <= 32'd0;
            op_write     <= 1'b0;
            burst_mode  <= 1'b0;
            burst_len_hold <= 4'd0;
            burst_count <= 4'd0;
            op_addr_word <= 21'd0;
            op_wdata     <= 32'd0;
            op_wstrb     <= 4'd0;
            rsp_valid    <= 1'b0;

            burst_rsp_valid <= 1'b0;

            burst_rsp_last <= 1'b0;
            burst_rsp_error <= 1'b0;
            rsp_error    <= 1'b0;
            timeout_error        <= 1'b0;
            init_done             <= 1'b0;
            row_open              <= 1'b0;
            open_bank             <= 2'b00;
            open_row              <= 11'd0;
            precharge_to_activate <= 1'b0;
            precharge_to_refresh  <= 1'b0;
        end else begin
            rsp_valid     <= 1'b0;
            rsp_error     <= 1'b0;
            burst_rsp_valid <= 1'b0;
            burst_rsp_last  <= 1'b0;
            burst_rsp_error <= 1'b0;
            timeout_error <= 1'b0;

            // Refresh is wall-clock time; requests must never postpone retention service.
            if (!init_done || state == ST_REFRESH) refresh_timer <= 32'd0;
            else if (!refresh_due) refresh_timer <= refresh_timer + 1'b1;

            // A timeout is an error response and returns to the idle state.
            if (transaction_state &&
                (REQUEST_TIMEOUT_CYCLES > 0) &&
                (op_timer >= REQUEST_TIMEOUT_CYCLES - 1)) begin
                state<=ST_READ_STOP;timer<=0;op_timer<=0;
                cleanup_precharge<=1;precharge_to_activate<=0;precharge_to_refresh<=0;op_write<=0;
                if(burst_mode) begin burst_rsp_valid<=1;burst_rsp_error<=1;burst_rsp_last<=1;end
                else begin rsp_valid<=1;rsp_error<=1;end
                timeout_error<=1;
            end else begin
                if (transaction_state)
                    op_timer <= op_timer + 1'b1;
                else
                    op_timer <= 32'd0;

                case (state)
                    ST_POWERUP: begin
                        timer <= timer + 1'b1;
                        if ((INIT_WAIT_CYCLES <= 1) ||
                            (timer >= INIT_WAIT_CYCLES - 1)) begin
                            timer <= 32'd0;
                            state <= ST_CKE_WAKE;
                        end
                    end
                    ST_CKE_WAKE: begin
                        if(timer>=1) begin timer<=0;state<=ST_INIT_PRE;end
                        else timer<=timer+1'b1;
                    end
                    ST_INIT_PRE: begin
                        timer <= 32'd0;
                        state <= ST_INIT_TRP;
                    end
                    ST_INIT_TRP: begin
                        if ((TRP_CYCLES <= 1) || (timer >= TRP_CYCLES - 1)) begin
                            timer <= 32'd0;
                            state <= ST_INIT_AR1;
                        end else timer <= timer + 1'b1;
                    end
                    ST_INIT_AR1: begin
                        timer <= 32'd0;
                        state <= ST_INIT_AR1_WAIT;
                    end
                    ST_INIT_AR1_WAIT: begin
                        if ((TRFC_CYCLES <= 1) || (timer >= TRFC_CYCLES - 1)) begin
                            timer <= 32'd0;
                            state <= ST_INIT_AR2;
                        end else timer <= timer + 1'b1;
                    end
                    ST_INIT_AR2: begin
                        timer <= 32'd0;
                        state <= ST_INIT_AR2_WAIT;
                    end
                    ST_INIT_AR2_WAIT: begin
                        if ((TRFC_CYCLES <= 1) || (timer >= TRFC_CYCLES - 1)) begin
                            timer <= 32'd0;
                            state <= ST_INIT_MRS;
                        end else timer <= timer + 1'b1;
                    end
                    ST_INIT_MRS: begin
                        timer <= 32'd0;
                        state <= ST_INIT_MRS_WAIT;
                    end
                    ST_INIT_MRS_WAIT: begin
                        if ((TRSC_CYCLES <= 1) || (timer >= TRSC_CYCLES - 1)) begin
                            timer <= 32'd0;
                            init_done <= 1'b1;
                            state <= ST_IDLE;
                        end else timer <= timer + 1'b1;
                    end
                    ST_IDLE: begin
                        timer <= 32'd0;
                        if (refresh_due) begin
                            precharge_to_refresh  <= row_open;
                            precharge_to_activate <= 1'b0;
                            if (row_open) state <= ST_PRECHARGE;
                            else           state <= ST_REFRESH;
                        end else if (burst_req_valid && burst_req_ready &&
                                     ((burst_req_len<1) || (burst_req_len>8) ||
                                      ({1'b0,burst_req_addr_word[2:0]}+burst_req_len>8))) begin
                            burst_rsp_valid<=1;burst_rsp_last<=1;burst_rsp_error<=1;
                        end else if (burst_req_valid && burst_req_ready) begin
                            op_write       <= 1'b0;
                            burst_mode     <= 1'b1;
                            burst_len_hold <= burst_req_len;
                            burst_count    <= 4'd0;
                            op_addr_word   <= burst_req_addr_word;
                            op_timer       <= 32'd0;
                            precharge_to_refresh  <= 1'b0;
                            precharge_to_activate <= row_open && !burst_same_open_row;
                            if (row_open && !burst_same_open_row) state <= ST_PRECHARGE;
                            else if (burst_same_open_row) state <= ST_BURST_READ_CMD;
                            else state <= ST_ACTIVATE;
                        end else if (req_valid && req_ready) begin
                            op_write      <= req_write;
                            burst_mode    <= 1'b0;
                            op_addr_word  <= req_addr_word;
                            op_wdata      <= req_wdata;
                            op_wstrb      <= req_wstrb;
                            op_timer      <= 32'd0;
                            precharge_to_refresh  <= 1'b0;
                            precharge_to_activate <= row_open && !req_same_open_row;
                            if (row_open && !req_same_open_row) state <= ST_PRECHARGE;
                            else if (req_same_open_row) state <= req_write ? ST_WRITE_CMD : ST_READ_CMD;
                            else state <= ST_ACTIVATE;
                        end
                    end
                    ST_ACTIVATE: begin
                        timer     <= 32'd0;
                        row_open  <= 1'b1;
                        open_bank <= op_addr_word[20:19];
                        open_row  <= op_addr_word[18:8];
                        state     <= ST_RCD_WAIT;
                    end
                    ST_RCD_WAIT: begin
                        if ((TRCD_CYCLES <= 1) || (timer >= TRCD_CYCLES - 1)) begin
                            timer <= 32'd0;
                            if (op_write) state <= ST_WRITE_CMD;
                            else if (burst_mode) state <= ST_BURST_READ_CMD;
                            else          state <= ST_READ_CMD;
                        end else timer <= timer + 1'b1;
                    end
                    ST_READ_CMD: begin
                        timer <= 32'd0;
                        state <= ST_READ_WAIT;
                    end
                ST_READ_WAIT: begin
                        if ((CAS_LATENCY <= 1) || (timer >= CAS_LATENCY)) begin

                            rsp_valid <= 1'b1;
                            rsp_error <= 1'b0;
                            timer <= 32'd0;
                            state <= ST_READ_STOP;cleanup_precharge<=0;
                        end else timer <= timer + 1'b1;
                    end
                    ST_BURST_READ_CMD: begin
                        timer <= 32'd0;
                        state <= ST_BURST_WAIT;
                    end
                    ST_BURST_WAIT: begin
                        if ((CAS_LATENCY <= 1) || (timer >= CAS_LATENCY)) begin
                            timer <= 32'd0;
                            // Capture the first word at the SAME latency as a single read.
                            // Advancing state alone here discards word zero of every burst.
                            burst_rsp_valid <= 1'b1;

                            burst_rsp_error <= 1'b0;
                            burst_rsp_last <= (burst_len_hold == 4'd1);
                            burst_count <= 4'd1;
                            if(burst_len_hold == 4'd1)begin
                                state <= ST_READ_STOP;cleanup_precharge<=0;
                                burst_mode <= 1'b0;
                            end else state <= ST_BURST_DATA;
                        end else timer <= timer + 1'b1;
                    end
                    ST_BURST_DATA: begin
                        burst_rsp_valid <= 1'b1;

                        burst_rsp_error <= 1'b0;
                        burst_rsp_last <= (burst_count == burst_len_hold - 1'b1);
                        if (burst_count == burst_len_hold - 1'b1) begin
                            state <= ST_READ_STOP;timer<=0;cleanup_precharge<=0;
                            burst_mode <= 1'b0;
                        end else begin
                            burst_count <= burst_count + 1'b1;
                        end
                    end
                    ST_READ_STOP: begin
                        timer<=0;state<=ST_READ_DRAIN;
                    end
                    ST_READ_DRAIN: begin
                        if(timer>=4) begin
                            timer<=0;
                            if(cleanup_precharge) state<=ST_PRECHARGE;
                            else state<=ST_IDLE;
                            cleanup_precharge<=0;
                        end else timer<=timer+1'b1;
                    end
                    ST_WRITE_CMD: begin
                        timer <= 32'd0;
                        state <= ST_WRITE_HOLD;
                    end
                    ST_WRITE_HOLD: begin
                        timer     <= 32'd0;
                        rsp_valid <= 1'b1;
                        rsp_error <= 1'b0;
                        state     <= ST_IDLE;
                    end
                    ST_PRECHARGE: begin
                        timer <= 32'd0;
                        state <= ST_TRP_WAIT;
                    end
                    ST_TRP_WAIT: begin
                        if ((TRP_CYCLES <= 1) || (timer >= TRP_CYCLES - 1)) begin
                            timer <= 32'd0;
                            row_open <= 1'b0;
                            if (precharge_to_refresh) begin
                                precharge_to_refresh <= 1'b0;
                                state <= ST_REFRESH;
                            end else if (precharge_to_activate) begin
                                precharge_to_activate <= 1'b0;
                                state <= ST_ACTIVATE;
                            end else begin
                                if (op_write) begin
                                    rsp_valid <= 1'b1;
                                    rsp_error <= 1'b0;
                                end
                                state <= ST_IDLE;
                            end
                        end else timer <= timer + 1'b1;
                    end
                    ST_REFRESH: begin
                        timer    <= 32'd0;
                        row_open <= 1'b0;
                        state    <= ST_TRFC_WAIT;
                    end
                    ST_TRFC_WAIT: begin
                        if ((TRFC_CYCLES <= 1) || (timer >= TRFC_CYCLES - 1)) begin
                            timer <= 32'd0;
                            state <= ST_IDLE;
                        end else timer <= timer + 1'b1;
                    end
                    default: begin
                        state <= ST_POWERUP;
                        timer <= 32'd0;
                        init_done <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule




