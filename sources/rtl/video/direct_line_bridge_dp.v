`timescale 1ns/1ps
// Direct burst refill, explicit bank revocation and frame-generation tags.
module direct_line_bridge_dp #(
    parameter integer FRAME_WIDTH=640,
    parameter integer FRAME_HEIGHT=480
) (
    input wire ctrl_clk,ctrl_rst_n,pxl_clk,pxl_rst_n,
    input wire line_req_pulse_pxl,
    input wire [11:0] line_req_y_pxl,
    input wire [20:0] frame_base_word_ctrl,
    output reg line_ready_pulse_pxl,
    output reg [11:0] line_ready_y_pxl,
    output reg line_ready_bank_pxl,
    input wire pixel_req_valid,
    input wire [11:0] pixel_req_x,pixel_req_y,
    output wire pixel_req_ready,pixel_valid,
    output wire [15:0] pixel_data,
    output reg pixel_error,
    output wire mem_rd_valid,
    input wire mem_rd_ready,
    output wire [20:0] mem_rd_addr_word,
    input wire mem_rd_rsp_valid,
    input wire [31:0] mem_rd_rsp_data,
    input wire mem_rd_error,
    output wire line_urgent_ctrl,
    output wire mem_burst_valid,
    input wire mem_burst_ready,
    output wire [20:0] mem_burst_addr_word,
    output wire [3:0] mem_burst_len,
    input wire mem_burst_rsp_valid,
    input wire [31:0] mem_burst_rsp_data,
    input wire mem_burst_rsp_last,mem_burst_rsp_error,
    input wire frame_changed_pxl,front_frame_select_pxl,
    // Vertical frame start retires the previous raster's reader ownership.
    input wire raster_frame_start_pxl,
    input wire front_ready_ctrl,front_frame_select_ctrl,
    input wire [11:0] front_width_ctrl,front_height_ctrl,
    output reg crc_line_start_ctrl,
    output wire crc_frame_select_ctrl,
    output wire [8:0] crc_line_y_ctrl,
    output wire [11:0] crc_width_ctrl,
    output wire crc_word_valid_ctrl,
    output wire [31:0] crc_word_data_ctrl,
    output reg crc_line_done_ctrl,
    input wire crc_result_valid_ctrl,crc_result_ok_ctrl,
    output reg line_error_event_ctrl,
    output reg [15:0] crc_failure_count_ctrl,
    output reg [11:0] last_crc_error_y_ctrl,
    output reg [15:0] verified_frame_count_ctrl
);
    localparam integer WORDS_PER_LINE=FRAME_WIDTH/2;
    localparam [2:0] CTRL_IDLE=0,CTRL_ACQUIRE=1,CTRL_ISSUE=2,CTRL_RECEIVE=3,
        CTRL_VERIFY=4,CTRL_PAYLOAD=5,CTRL_PUBLISH=6,CTRL_ARM=7;
    reg [2:0] state;
    reg [15:0] wait_timer;
    reg [20:0] line_base;
    reg [11:0] line_y,width_hold;
    reg [8:0] word_index;
    reg [3:0] burst_length,burst_received;
    reg fill_bank,last_published_bank,frame_hold,epoch_hold,retried;
    reg [11:0] height_hold,verified_next_y;
    reg verified_sequence_active,verification_epoch;
    // Four-phase source mailbox holds the complete request through acceptance.
    reg request_valid_pxl,request_epoch_pxl,epoch_pxl;
    reg [11:0] request_y_pxl,queued_y_pxl;
    reg queued_valid_pxl,queued_epoch_pxl;
    reg [2:0] mailbox_settle_pxl;
    reg request_sync_first,request_sync_second,request_sync_third;
    reg [11:0] y_sync_first,y_sync_second,y_sync_third;
    reg epoch_sync_first,epoch_sync_second,epoch_sync_third;
    reg current_epoch_meta,current_epoch_sync;
    reg request_ack_ctrl,ack_meta_pxl,ack_sync_pxl;
    // Reader must revoke ownership before the writer touches a bank.
    reg revoke_valid_ctrl,revoke_bank_ctrl;
    reg revoke_meta_pxl,revoke_sync_pxl,revoke_bank_meta_pxl,revoke_bank_sync_pxl;
    reg revoke_ack_pxl,revoke_ack_meta_ctrl,revoke_ack_sync_ctrl;
    reg active_bank_pxl,active_valid_pxl;
    reg bank_zero_valid,bank_one_valid;
    reg [11:0] bank_zero_y,bank_one_y;
    reg bank_zero_epoch,bank_one_epoch,bank_zero_frame,bank_one_frame;
    // Metadata is published before the completion toggle.
    reg ready_toggle_ctrl,ready_valid_ctrl;
    reg ready_bank_ctrl,ready_epoch_ctrl,ready_frame_ctrl;
    reg [11:0] ready_y_ctrl;
    reg ready_meta_pxl,ready_sync_pxl,ready_delayed_pxl,ready_seen_pxl;
    reg ready_valid_meta_pxl,ready_valid_sync_pxl;
    reg ready_bank_meta_pxl,ready_bank_sync_pxl;
    reg ready_epoch_meta_pxl,ready_epoch_sync_pxl;
    reg ready_frame_meta_pxl,ready_frame_sync_pxl;
    reg [11:0] ready_y_meta_pxl,ready_y_sync_pxl;
    wire zero_matches=bank_zero_valid && bank_zero_epoch==epoch_pxl &&
        bank_zero_frame==front_frame_select_pxl && pixel_req_y==bank_zero_y;
    wire one_matches=bank_one_valid && bank_one_epoch==epoch_pxl &&
        bank_one_frame==front_frame_select_pxl && pixel_req_y==bank_one_y;
    wire selected_bank=!zero_matches && one_matches;
    wire pixel_accept=pixel_req_valid&&pixel_req_ready;
    assign pixel_req_ready=(zero_matches||one_matches) && pixel_req_x<FRAME_WIDTH && !frame_changed_pxl;
    reg response_valid,response_bank,response_odd;
    assign pixel_valid=response_valid;
    wire [15:0] bank_zero_even,bank_zero_odd,bank_one_even,bank_one_odd;
    assign pixel_data=response_bank ? (response_odd ? bank_one_odd : bank_one_even) :
                                             (response_odd ? bank_zero_odd : bank_zero_even);
    wire refill_write=state==CTRL_RECEIVE && mem_burst_rsp_valid && !mem_burst_rsp_error &&
        word_index<WORDS_PER_LINE && mem_burst_rsp_last==(burst_received==burst_length-1'b1);
    genvar bank,plane;
    generate for(bank=0;bank<2;bank=bank+1) begin: banks
        for(plane=0;plane<2;plane=plane+1) begin: planes
            wire [15:0] read_value;
            wire write_enable=refill_write && fill_bank==bank;
            EG_LOGIC_BRAM #(
                .DATA_WIDTH_A(16),.ADDR_WIDTH_A(9),.DATA_DEPTH_A(512),
                .DATA_WIDTH_B(16),.ADDR_WIDTH_B(9),.DATA_DEPTH_B(512),
                .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
                .IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),.FILL_ALL("NONE")
            ) line_words (
                .dia(mem_burst_rsp_data[plane*16+:16]),.dib(16'd0),
                .addra(word_index),.addrb(pixel_req_x[9:1]),
                .cea(write_enable),.ceb(1'b1),.ocea(1'b0),.oceb(1'b0),
                .clka(ctrl_clk),.clkb(pxl_clk),.wea(write_enable),.web(1'b0),
                .bea(1'b1),.beb(1'b0),.rsta(!ctrl_rst_n),.rstb(!pxl_rst_n),
                .doa(),.dob(read_value)
            );
            if(bank==0 && plane==0)assign bank_zero_even=read_value;
            if(bank==0 && plane==1)assign bank_zero_odd=read_value;
            if(bank==1 && plane==0)assign bank_one_even=read_value;
            if(bank==1 && plane==1)assign bank_one_odd=read_value;
        end
    end endgenerate
    assign mem_rd_valid=1'b0;
    assign mem_rd_addr_word=21'd0;
    assign mem_burst_valid=state==CTRL_ISSUE;
    assign line_urgent_ctrl=state!=CTRL_IDLE;
    assign mem_burst_addr_word=line_base+word_index;
    wire [9:0] remaining_words=WORDS_PER_LINE-{1'b0,word_index};
    wire [3:0] boundary_words=4'd8-{1'b0,mem_burst_addr_word[2:0]};
    assign mem_burst_len=remaining_words<boundary_words ? remaining_words[3:0] : boundary_words;
    assign crc_frame_select_ctrl=frame_hold;
    assign crc_line_y_ctrl=line_y[8:0];
    assign crc_width_ctrl=width_hold;
    assign crc_word_valid_ctrl=refill_write;
    assign crc_word_data_ctrl=mem_burst_rsp_data;
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if(!ctrl_rst_n) begin
            state<=CTRL_IDLE;wait_timer<=0;line_base<=0;line_y<=0;width_hold<=0;word_index<=0;
            burst_length<=0;burst_received<=0;fill_bank<=0;last_published_bank<=0;frame_hold<=0;epoch_hold<=0;retried<=0;
            request_sync_first<=0;request_sync_second<=0;request_sync_third<=0;
            y_sync_first<=0;y_sync_second<=0;y_sync_third<=0;
            epoch_sync_first<=0;epoch_sync_second<=0;epoch_sync_third<=0;current_epoch_meta<=0;current_epoch_sync<=0;
            request_ack_ctrl<=0;revoke_valid_ctrl<=0;revoke_bank_ctrl<=0;revoke_ack_meta_ctrl<=0;revoke_ack_sync_ctrl<=0;
            ready_toggle_ctrl<=0;ready_valid_ctrl<=0;ready_bank_ctrl<=0;ready_epoch_ctrl<=0;ready_frame_ctrl<=0;ready_y_ctrl<=0;
            crc_line_start_ctrl<=0;crc_line_done_ctrl<=0;line_error_event_ctrl<=0;crc_failure_count_ctrl<=0;last_crc_error_y_ctrl<=0;
            height_hold<=0;verified_next_y<=0;verified_frame_count_ctrl<=0;
            verified_sequence_active<=0;verification_epoch<=0;
        end else begin
            request_sync_first<=request_valid_pxl;request_sync_second<=request_sync_first;request_sync_third<=request_sync_second;
            y_sync_first<=request_y_pxl;y_sync_second<=y_sync_first;y_sync_third<=y_sync_second;
            epoch_sync_first<=request_epoch_pxl;epoch_sync_second<=epoch_sync_first;epoch_sync_third<=epoch_sync_second;
            current_epoch_meta<=epoch_pxl;current_epoch_sync<=current_epoch_meta;
            if(verification_epoch!=current_epoch_sync)begin
                verification_epoch<=current_epoch_sync;verified_sequence_active<=0;verified_next_y<=0;
            end
            revoke_ack_meta_ctrl<=revoke_ack_pxl;revoke_ack_sync_ctrl<=revoke_ack_meta_ctrl;
            crc_line_start_ctrl<=0;crc_line_done_ctrl<=0;line_error_event_ctrl<=0;
            if(!request_sync_third)request_ack_ctrl<=0;
            if(state==CTRL_IDLE)wait_timer<=0;else wait_timer<=wait_timer+1'b1;
            if(state!=CTRL_IDLE && wait_timer>=16'd50000) begin
                state<=CTRL_IDLE;revoke_valid_ctrl<=0;line_error_event_ctrl<=1;
            end else case(state)
                CTRL_IDLE: if(request_sync_third&&!request_ack_ctrl&&front_ready_ctrl) begin
                    request_ack_ctrl<=1;
                    if(epoch_sync_second!=current_epoch_sync)begin end
                    else if(y_sync_second>=FRAME_HEIGHT || front_width_ctrl==0 || front_width_ctrl>FRAME_WIDTH)
                        line_error_event_ctrl<=1;
                    else begin
                        line_y<=y_sync_second;width_hold<=front_width_ctrl;frame_hold<=front_frame_select_ctrl;
                        height_hold<=front_height_ctrl;
                        epoch_hold<=epoch_sync_second;line_base<=frame_base_word_ctrl+y_sync_second*WORDS_PER_LINE;
                        fill_bank<=!last_published_bank;revoke_bank_ctrl<=!last_published_bank;revoke_valid_ctrl<=0;
                        word_index<=0;retried<=0;state<=CTRL_ARM;
                    end
                end
                CTRL_ARM: if(!revoke_ack_sync_ctrl)begin revoke_valid_ctrl<=1;state<=CTRL_ACQUIRE;end
                CTRL_ACQUIRE: if(revoke_ack_sync_ctrl) begin
                    revoke_valid_ctrl<=0;crc_line_start_ctrl<=1;state<=CTRL_ISSUE;
                end
                CTRL_ISSUE: if(mem_burst_ready) begin
                    burst_length<=mem_burst_len;burst_received<=0;state<=CTRL_RECEIVE;
                end
                CTRL_RECEIVE: if(mem_burst_rsp_valid) begin
                    if(mem_burst_rsp_error || mem_burst_rsp_last!=(burst_received==burst_length-1'b1)) begin
                        line_error_event_ctrl<=1;state<=CTRL_IDLE;
                    end else begin
                        if(word_index==WORDS_PER_LINE-1) begin
                            crc_line_done_ctrl<=1;state<=CTRL_VERIFY;
                        end else begin
                            word_index<=word_index+1'b1;
                            if(mem_burst_rsp_last)state<=CTRL_ISSUE;
                        end
                        burst_received<=burst_received+1'b1;
                    end
                end
                CTRL_VERIFY: if(crc_result_valid_ctrl) begin
                    if(epoch_hold!=current_epoch_sync)state<=CTRL_IDLE;
                    else if(crc_result_ok_ctrl) begin
                        if(line_y==0 || (verified_sequence_active && line_y==verified_next_y))begin
                            if(line_y==height_hold-1'b1)begin
                                if(verified_frame_count_ctrl!=16'hffff)verified_frame_count_ctrl<=verified_frame_count_ctrl+1'b1;
                                verified_next_y<=0;verified_sequence_active<=0;
                            end else begin verified_next_y<=line_y+1'b1;verified_sequence_active<=1;end
                        end else begin verified_next_y<=0;verified_sequence_active<=0;end
                        ready_bank_ctrl<=fill_bank;ready_epoch_ctrl<=epoch_hold;ready_frame_ctrl<=frame_hold;ready_y_ctrl<=line_y;
                        ready_valid_ctrl<=1;state<=CTRL_PAYLOAD;
                    end else begin
                        line_error_event_ctrl<=1;last_crc_error_y_ctrl<=line_y;
                        if(crc_failure_count_ctrl!=16'hffff)crc_failure_count_ctrl<=crc_failure_count_ctrl+1'b1;
                        if(!retried)begin retried<=1;word_index<=0;crc_line_start_ctrl<=1;state<=CTRL_ISSUE;end
                        else state<=CTRL_IDLE;
                    end
                end
                CTRL_PAYLOAD: state<=CTRL_PUBLISH;
                CTRL_PUBLISH: begin
                    ready_toggle_ctrl<=!ready_toggle_ctrl;last_published_bank<=fill_bank;state<=CTRL_IDLE;
                end
                default: state<=CTRL_IDLE;
            endcase
        end
    end
    always @(posedge pxl_clk or negedge pxl_rst_n) begin
        if(!pxl_rst_n) begin
            request_valid_pxl<=0;request_y_pxl<=0;request_epoch_pxl<=0;epoch_pxl<=0;
            queued_y_pxl<=0;queued_valid_pxl<=0;queued_epoch_pxl<=0;ack_meta_pxl<=0;ack_sync_pxl<=0;mailbox_settle_pxl<=0;
            revoke_meta_pxl<=0;revoke_sync_pxl<=0;revoke_bank_meta_pxl<=0;revoke_bank_sync_pxl<=0;revoke_ack_pxl<=0;
            active_bank_pxl<=0;active_valid_pxl<=0;bank_zero_valid<=0;bank_one_valid<=0;
            bank_zero_y<=0;bank_one_y<=0;bank_zero_epoch<=0;bank_one_epoch<=0;bank_zero_frame<=0;bank_one_frame<=0;
            ready_meta_pxl<=0;ready_sync_pxl<=0;ready_delayed_pxl<=0;ready_seen_pxl<=0;
            ready_valid_meta_pxl<=0;ready_valid_sync_pxl<=0;ready_bank_meta_pxl<=0;ready_bank_sync_pxl<=0;
            ready_epoch_meta_pxl<=0;ready_epoch_sync_pxl<=0;ready_frame_meta_pxl<=0;ready_frame_sync_pxl<=0;ready_y_meta_pxl<=0;ready_y_sync_pxl<=0;
            response_valid<=0;response_bank<=0;response_odd<=0;pixel_error<=0;
            line_ready_pulse_pxl<=0;line_ready_y_pxl<=0;line_ready_bank_pxl<=0;
        end else begin
            ack_meta_pxl<=request_ack_ctrl;ack_sync_pxl<=ack_meta_pxl;
            mailbox_settle_pxl<={mailbox_settle_pxl[1:0],1'b1};
            revoke_meta_pxl<=revoke_valid_ctrl;revoke_sync_pxl<=revoke_meta_pxl;
            revoke_bank_meta_pxl<=revoke_bank_ctrl;revoke_bank_sync_pxl<=revoke_bank_meta_pxl;
            ready_meta_pxl<=ready_toggle_ctrl;ready_sync_pxl<=ready_meta_pxl;ready_delayed_pxl<=ready_sync_pxl;
            ready_valid_meta_pxl<=ready_valid_ctrl;ready_valid_sync_pxl<=ready_valid_meta_pxl;
            ready_bank_meta_pxl<=ready_bank_ctrl;ready_bank_sync_pxl<=ready_bank_meta_pxl;
            ready_epoch_meta_pxl<=ready_epoch_ctrl;ready_epoch_sync_pxl<=ready_epoch_meta_pxl;
            ready_frame_meta_pxl<=ready_frame_ctrl;ready_frame_sync_pxl<=ready_frame_meta_pxl;
            ready_y_meta_pxl<=ready_y_ctrl;ready_y_sync_pxl<=ready_y_meta_pxl;
            response_valid<=pixel_accept;response_bank<=selected_bank;response_odd<=pixel_req_x[0];
            pixel_error<=pixel_req_valid&&!pixel_req_ready;line_ready_pulse_pxl<=0;
            if(pixel_accept)begin active_bank_pxl<=selected_bank;active_valid_pxl<=1;end
            // Never release at horizontal blank: scaled rows can be read again.
            if(raster_frame_start_pxl)active_valid_pxl<=0;
            if(request_valid_pxl&&ack_sync_pxl)request_valid_pxl<=0;
            if((&mailbox_settle_pxl)&&!request_valid_pxl&&!ack_sync_pxl&&queued_valid_pxl) begin
                request_y_pxl<=queued_y_pxl;request_epoch_pxl<=queued_epoch_pxl;request_valid_pxl<=1;queued_valid_pxl<=0;
            end
            if(line_req_pulse_pxl)begin queued_y_pxl<=line_req_y_pxl;queued_epoch_pxl<=epoch_pxl;queued_valid_pxl<=1;end
            if(!revoke_sync_pxl)revoke_ack_pxl<=0;
            else if(!revoke_ack_pxl && !(pixel_accept&&selected_bank==revoke_bank_sync_pxl) &&
                (!active_valid_pxl || active_bank_pxl!=revoke_bank_sync_pxl ||
                 (revoke_bank_sync_pxl ? !bank_one_valid : !bank_zero_valid))) begin
                if(revoke_bank_sync_pxl)bank_one_valid<=0;else bank_zero_valid<=0;
                revoke_ack_pxl<=1;
            end
            if(ready_delayed_pxl!=ready_seen_pxl) begin
                ready_seen_pxl<=ready_delayed_pxl;
                if(ready_valid_sync_pxl && ready_epoch_sync_pxl==epoch_pxl && ready_frame_sync_pxl==front_frame_select_pxl) begin
                    if(ready_bank_sync_pxl)begin
                        bank_one_valid<=1;bank_one_y<=ready_y_sync_pxl;bank_one_epoch<=ready_epoch_sync_pxl;bank_one_frame<=ready_frame_sync_pxl;
                    end else begin
                        bank_zero_valid<=1;bank_zero_y<=ready_y_sync_pxl;bank_zero_epoch<=ready_epoch_sync_pxl;bank_zero_frame<=ready_frame_sync_pxl;
                    end
                    line_ready_pulse_pxl<=1;line_ready_y_pxl<=ready_y_sync_pxl;line_ready_bank_pxl<=ready_bank_sync_pxl;
                end
            end
            if(frame_changed_pxl)begin
                epoch_pxl<=!epoch_pxl;bank_zero_valid<=0;bank_one_valid<=0;active_valid_pxl<=0;
                // The mapper is the only request producer, including row zero.
                queued_valid_pxl<=0;
                response_valid<=0;line_ready_pulse_pxl<=0;
            end
        end
    end
endmodule
