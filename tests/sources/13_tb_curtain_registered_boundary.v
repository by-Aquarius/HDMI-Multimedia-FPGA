`timescale 1ns/1ps
// Actual playback/request/curtain/frame-manager chain with deterministic start loss.
module tb_curtain_registered_boundary;
    parameter integer LEGACY=0;
    parameter integer SCENARIO=0;
    parameter real PIXEL_OFFSET=0.0;
    reg ctrl_clk=0,pixel_clk=0;
    always #10 ctrl_clk=~ctrl_clk;
    initial begin #PIXEL_OFFSET;forever #6.734 pixel_clk=~pixel_clk;end
    reg rst_ctrl_n=0,rst_pixel_n=0,abort_pixel=SCENARIO==0;
    reg next_key=0;
    wire [2:0] playback_state,curtain_state;
    wire playing,paused,busy,error,commit,transition_start,reverse;
    wire [7:0] error_code;
    wire [4:0] active_index,request_index,load_index;
    wire request_valid,request_ready,request_done,request_error;
    wire [1:0] request_type;
    wire [7:0] request_error_code;
    wire [3:0] request_debug;
    wire load_start,swap_command,frame_swap_request,frame_swap_ack;
    wire load_done,load_error,load_timeout,load_busy,pixel_ready;
    wire pending,start_pixel,ready_pixel,curtain_ready,curtain_done;
    reg [5:0] frame_divider=0;
    wire frame_boundary_pixel=frame_divider==0;
    always @(posedge pixel_clk or negedge rst_pixel_n)begin
        if(!rst_pixel_n)frame_divider<=0;
        else frame_divider<=frame_divider==36 ? 0 : frame_divider+1'b1;
    end
    reg curtain_frame_boundary_q;
    always @(posedge pixel_clk or negedge rst_pixel_n)begin
        if(!rst_pixel_n)curtain_frame_boundary_q<=0;
        else curtain_frame_boundary_q<=frame_boundary_pixel;
    end
    reg frame_toggle=0,frame_meta=0,frame_sync=0,frame_seen=0;
    wire frame_boundary_ctrl=frame_sync^frame_seen;
    always @(posedge pixel_clk or negedge rst_pixel_n)begin
        if(!rst_pixel_n)frame_toggle<=0;
        else if(frame_boundary_pixel)frame_toggle<=!frame_toggle;
    end
    always @(posedge ctrl_clk or negedge rst_ctrl_n)begin
        if(!rst_ctrl_n)begin frame_meta<=0;frame_sync<=0;frame_seen<=0;end
        else begin frame_meta<=frame_toggle;frame_sync<=frame_meta;frame_seen<=frame_sync;end
    end
    reg ack_toggle=0,ack_meta=0,ack_sync=0,ack_seen=0,ack_token=0;
    wire ack_event=ack_sync^ack_seen;
    always @(posedge ctrl_clk or negedge rst_ctrl_n)begin
        if(!rst_ctrl_n)ack_toggle<=0;else if(frame_swap_ack)ack_toggle<=!ack_toggle;
    end
    always @(posedge pixel_clk or negedge rst_pixel_n)begin
        if(!rst_pixel_n)begin ack_meta<=0;ack_sync<=0;ack_seen<=0;ack_token<=0;end
        else begin
            ack_meta<=ack_toggle;ack_sync<=ack_meta;ack_seen<=ack_sync;
            if(start_pixel || abort_pixel)ack_token<=0;
            else if(ack_event)ack_token<=1;
        end
    end
    reg done_toggle=0,done_meta=0,done_sync=0,done_seen=0;
    wire done_ctrl=done_sync^done_seen;
    always @(posedge pixel_clk or negedge rst_pixel_n)begin
        if(!rst_pixel_n)done_toggle<=0;else if(curtain_done)done_toggle<=!done_toggle;
    end
    always @(posedge ctrl_clk or negedge rst_ctrl_n)begin
        if(!rst_ctrl_n)begin done_meta<=0;done_sync<=0;done_seen<=0;end
        else begin done_meta<=done_toggle;done_sync<=done_meta;done_seen<=done_sync;end
    end
    generate if(LEGACY)begin:old_bridge
        reg intent=0,intent_meta=0,intent_sync=0,intent_seen=0;
        reg pending_q=0,ready_meta=0,ready_sync=0,pending_meta=0,pending_sync=0;
        assign pending=pending_q;
        assign frame_swap_request=pending_q && ready_sync;
        assign start_pixel=intent_sync^intent_seen;
        assign ready_pixel=pending_sync;
        always @(posedge ctrl_clk or negedge rst_ctrl_n)begin
            if(!rst_ctrl_n)begin intent<=0;pending_q<=0;ready_meta<=0;ready_sync<=0;end
            else begin
                if(transition_start)intent<=!intent;
                if(swap_command)pending_q<=1;else if(frame_swap_request || request_error)pending_q<=0;
                ready_meta<=curtain_ready;ready_sync<=ready_meta;
            end
        end
        always @(posedge pixel_clk or negedge rst_pixel_n)begin
            if(!rst_pixel_n)begin intent_meta<=0;intent_sync<=0;intent_seen<=0;pending_meta<=0;pending_sync<=0;end
            else begin intent_meta<=intent;intent_sync<=intent_meta;intent_seen<=intent_sync;pending_meta<=pending_q;pending_sync<=pending_meta;end
        end
    end else begin:new_bridge
        curtain_request_bridge bridge(.clk_ctrl(ctrl_clk),.rst_ctrl_n(rst_ctrl_n),.clk_pixel(pixel_clk),.rst_pixel_n(rst_pixel_n),
            .enable(1'b1),.program_transaction(1'b0),.swap_command_ctrl(swap_command),.swap_ack_ctrl(frame_swap_ack),
            .request_error_ctrl(request_error),.curtain_idle_pixel(curtain_state==0 || curtain_state==5),
            .curtain_abort_pixel(abort_pixel),.curtain_ready_pixel(curtain_ready),
            .pending_ctrl(pending),.ready_ctrl(),.frame_swap_request_ctrl(frame_swap_request),.start_pixel(start_pixel),.frame_ready_pixel(ready_pixel));
    end endgenerate
    page_curtain_transition #(.SCREEN_WIDTH(1280),.FRAME_TIMEOUT_CYCLES(10000),.SWAP_TIMEOUT_CYCLES(80000)) curtain(
        .clk(pixel_clk),.rst_n(rst_pixel_n),.enable(1'b1),.start(start_pixel),.reverse(reverse),
        .frame_boundary(curtain_frame_boundary_q),.frame_swapped(ack_token),.frame_ready(ready_pixel),.abort(abort_pixel),
        .pixel_valid(1'b1),.pixel_x(12'd640),.in_rgb565(16'h3ac5),.out_valid(),.out_rgb565(),.fade_active(),.fade_level(),
        .swap_ready(curtain_ready),.done(curtain_done),.debug_state(curtain_state),.fade_error());
    playback_fsm #(.REQUEST_TIMEOUT_CYCLES(30000),.AUTO_LOAD_FIRST_IMAGE(1)) playback(
        .clk(ctrl_clk),.rst_n(rst_ctrl_n),.cmd_prev(1'b0),.cmd_next(next_key),.cmd_play_pause(1'b0),
        .media_ready(1'b1),.media_error(1'b0),.media_error_code(8'd0),.media_count(5'd6),
        .load_request(1'b0),.load_request_index(5'd0),.request_hold(1'b0),
        .req_valid(request_valid),.req_type(request_type),.req_index(request_index),.req_ready(request_ready),.req_done(request_done),
        .req_error(request_error),.req_error_code(request_error_code),.transition_enable(1'b1),.recover(1'b0),
        .state(playback_state),.playing(playing),.paused(paused),.busy(busy),.error(error),.error_code(error_code),
        .hold_frame(),.active_index(active_index),.index_commit(commit),.transition_reverse(reverse),.transition_start(transition_start));
    e_media_request_ctrl #(.REQUEST_TIMEOUT_CYCLES(2000),.LOAD_RETRY_MAX(0)) requests(
        .clk(ctrl_clk),.rst_n(rst_ctrl_n),.media_ready(1'b1),.media_count(5'd6),
        .req_valid(request_valid),.req_type(request_type),.req_index(request_index),.req_ready(request_ready),.req_done(request_done),
        .req_error(request_error),.req_error_code(request_error_code),.load_start(load_start),.load_index(load_index),.swap_request(swap_command),
        .load_done(load_done),.load_error(load_error),.permanent_media_error(1'b0),.load_timeout(load_timeout),.swap_ack(frame_swap_ack),
        .transition_enable(1'b1),.transition_done(done_ctrl),.pipeline_error_code(8'd0),.debug_status(request_debug),.busy());
    integer source_pixel=0;
    wire pixel_valid=load_busy && source_pixel<8;
    wire [11:0] source_x=source_pixel%4;
    wire [11:0] source_y=source_pixel/4;
    wire [15:0] source_color=16'h6300+source_pixel;
    wire mem_valid,show_select,load_select;
    wire [20:0] mem_address;
    wire [31:0] mem_data;
    reg mem_done=0;
    always @(posedge ctrl_clk or negedge rst_ctrl_n)begin
        if(!rst_ctrl_n)begin source_pixel<=0;mem_done<=0;end
        else begin
            mem_done<=mem_valid;
            if(load_start)source_pixel<=0;else if(pixel_valid && pixel_ready)source_pixel<=source_pixel+1;
        end
    end
    frame_buffer_manager #(.FRAME_WIDTH(4),.FRAME_HEIGHT(2),.LOAD_TIMEOUT_CYCLES(1000),.INPUT_BOTTOM_UP(0)) manager(
        .clk(ctrl_clk),.rst_n(rst_ctrl_n),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.pixel_rgb565(source_color),
        .pixel_x(source_x),.pixel_y(source_y),.pixel_last(source_pixel==7),.frame_width_i(12'd4),.frame_height_i(12'd2),
        .load_start(load_start),.load_abort(1'b0),.load_busy(load_busy),.load_done(load_done),.load_error(load_error),.load_error_detail(),
        .load_timeout(load_timeout),.load_conflict(),.load_frame_select(load_select),.show_frame_select(show_select),.frame_ready(),
        .swap_request(frame_swap_request),.frame_boundary(frame_boundary_ctrl),.swap_ack(frame_swap_ack),
        .mem_wr_valid(mem_valid),.mem_wr_ready(1'b1),.mem_wr_addr_word(mem_address),.mem_wr_data(mem_data),.mem_wr_strb(),
        .mem_wr_done(mem_done),.mem_wr_error(1'b0));
    integer grants=0,acks=0,commits=0,writes=0,iteration;
    reg captured_idle_wait=0;
    always @(posedge ctrl_clk)begin
        if(rst_ctrl_n)begin
            if(frame_swap_request)grants=grants+1;
            if(frame_swap_ack)acks=acks+1;
            if(commit)begin commits=commits+1;if(acks<commits)$fatal(1,"Commit without actual manager ACK");end
            if(mem_valid)begin
                writes=writes+1;
                if((mem_address>=21'h40000)==show_select)$fatal(1,"Wrote displayed frame");
            end
            if(request_debug[2:0]==3 && pending && curtain_state==0)captured_idle_wait=1;
            if(error)begin
                if(LEGACY && error_code==8'he4 && captured_idle_wait)
                    $fatal(1,"OLD_IDLE_SWAP_TIMEOUT_REPRODUCED scenario=%0d idle_wait=1 grants=%0d acks=%0d",SCENARIO,grants,acks);
                else $fatal(1,"Unexpected playback error=%h",error_code);
            end
            if(load_error || load_timeout)$fatal(1,"Frame manager load error");
        end
    end
    task next_image;
        begin wait(playback_state==2 && curtain_state==0);@(negedge ctrl_clk);next_key=1;@(negedge ctrl_clk);next_key=0;end
    endtask
    initial begin
        #120;rst_ctrl_n=1;rst_pixel_n=1;
        if(SCENARIO==0)begin #2000;abort_pixel=0;end
        else begin
            wait(commits==1);next_image();wait(transition_start);rst_pixel_n=0;
            wait(swap_command);repeat(5)@(negedge ctrl_clk);rst_pixel_n=1;
        end
        wait(commits==(SCENARIO==0 ? 1 : 2));
        for(iteration=0;iteration<8;iteration=iteration+1)begin next_image();wait(commits==(SCENARIO==0 ? 2 : 3)+iteration);end
        wait(!busy);repeat(5)@(negedge ctrl_clk);
        if(grants!=acks || acks!=commits || writes!=commits*4)$fatal(1,"Transaction conservation grants=%0d acks=%0d commits=%0d writes=%0d",grants,acks,commits,writes);
        $display("CURTAIN_SWAP_INTEGRATION_PASS scenario=%0d offset=%f commits=%0d grants=%0d real_ACKs=%0d back_frame_writes=%0d",SCENARIO,PIXEL_OFFSET,commits,grants,acks,writes);$finish;
    end
    initial begin #1000000;$fatal(1,"Integration timeout");end
endmodule
