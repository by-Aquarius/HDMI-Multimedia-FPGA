`timescale 1ns/1ps
module tb_portrait_bounds;
parameter integer LEGACY_PRIORITY=0;
parameter integer SOURCE_HEIGHT=300;
parameter integer SOURCE_WIDTH=200;
parameter real PIXEL_OFFSET=1.395;
reg ctrl_clk50=0,sdram_ctrl_clk=0,device_clk=0,pxlclk_i=0;
always #10 ctrl_clk50=~ctrl_clk50;
initial begin #2.2;forever #10 sdram_ctrl_clk=~sdram_ctrl_clk;end
initial begin #8;forever #10 device_clk=~device_clk;end
initial begin #(PIXEL_OFFSET);forever #6.734 pxlclk_i=~pxlclk_i;end
reg ctrl_rst_img_n=0,mem_rst_n=0,pxl_rst_n=0;
wire mem_rst_phy_n=mem_rst_n,mem_rst_bridge_n=mem_rst_n;
localparam [20:0] FRAME_A_BASE_WORD=0,FRAME_B_BASE_WORD=21'h40000,AUDIO_BUF_BASE_WORD=21'h80000;
reg d03_valid=0,d03_last=0,frame_load_start=0,bmp_start_r=0;
reg [15:0] d03_rgb565=0;
reg [11:0] d03_x=0,d03_y=0;
wire [11:0] d01_width=SOURCE_WIDTH,d01_height=SOURCE_HEIGHT;
wire frame_pixel_ready,frame_load_busy,frame_load_done,frame_load_error,frame_load_timeout,frame_load_conflict;
wire [7:0] frame_load_error_detail;
wire frame_load_select,frame_show_select,frame_swap_ack;
wire [1:0] frame_ready;
reg frame_swap_request=0,frame_boundary_ctrl=0;
wire mem_wr_valid,mem_wr_ready,mem_wr_done,mem_wr_error;
wire [20:0] mem_wr_addr_word;
wire [31:0] mem_wr_data;wire [3:0] mem_wr_strb;
wire mem_cdc_valid,mem_cdc_ready,mem_cdc_done,mem_cdc_error;
wire [20:0] mem_cdc_addr_word;wire [31:0] mem_cdc_data;wire [3:0] mem_cdc_strb;
wire mem_rd_valid,mem_rd_ready,mem_rd_rsp_valid,mem_rd_error;
wire [20:0] mem_rd_addr_word;wire [31:0] mem_rd_rsp_data;
wire mem_burst_valid,mem_burst_ready,mem_burst_rsp_valid,mem_burst_rsp_last,mem_burst_rsp_error;
wire [20:0] mem_burst_addr_word;wire [3:0] mem_burst_len;wire [31:0] mem_burst_rsp_data;
wire phy_req_valid,phy_req_ready,phy_req_write,phy_rsp_valid,phy_rsp_error,phy_init_done,phy_timeout_error;
wire [20:0] phy_req_addr_word;wire [31:0] phy_req_wdata,phy_rsp_rdata;wire [3:0] phy_req_wstrb;
wire phy_burst_valid,phy_burst_ready,phy_burst_rsp_valid,phy_burst_rsp_last,phy_burst_rsp_error;
wire [20:0] phy_burst_addr_word;wire [3:0] phy_burst_len;wire [31:0] phy_burst_rsp_data;
wire arbiter_init_done;
wire sdram_clk,sdram_cke,sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n;
wire [1:0] sdram_ba;wire [10:0] sdram_addr;tri [31:0] sdram_dq;wire [3:0] sdram_dqm;
reg front_has_been_committed=0;
always @(posedge ctrl_clk50)begin
 if(!ctrl_rst_img_n)front_has_been_committed<=0;else if(frame_swap_ack)front_has_been_committed<=1;
 if(ctrl_rst_img_n&&front_has_been_committed&&!frame_ready[frame_show_select])$fatal(1,"FULL_PATH_FRONT_INVALIDATED_DURING_HEADER");
end
reg allow_refill=0;
reg show_meta_mem=0,frame_show_mem2=0,show_meta_pxl=0,frame_select_sync_pxl=0;
reg [1:0] ready_meta_mem=0,ready_sync_mem=0;
reg swap_toggle=0,swap_meta_pxl=0,swap_sync_pxl=0,swap_seen_pxl=0;
always @(posedge ctrl_clk50)if(frame_swap_ack)swap_toggle<=!swap_toggle;
always @(posedge sdram_ctrl_clk) begin
 show_meta_mem<=frame_show_select;frame_show_mem2<=show_meta_mem;ready_meta_mem<=frame_ready;ready_sync_mem<=ready_meta_mem;
end
always @(posedge pxlclk_i) begin
 show_meta_pxl<=frame_show_select;frame_select_sync_pxl<=show_meta_pxl;
 swap_meta_pxl<=swap_toggle;swap_sync_pxl<=swap_meta_pxl;swap_seen_pxl<=swap_sync_pxl;
end
wire frame_swap_event_pxl=swap_sync_pxl^swap_seen_pxl;
wire front_ready_mem=allow_refill&&ready_sync_mem[frame_show_mem2];
wire [20:0] frame_base_word_mem=frame_show_mem2 ? FRAME_B_BASE_WORD : FRAME_A_BASE_WORD;
wire [11:0] width_sync_mem=SOURCE_WIDTH;
wire [11:0] height_sync_mem=SOURCE_HEIGHT;
wire [15:0] verified_frame_count_mem;
wire line_urgent_mem;
wire crc_line_start_mem,crc_line_done_mem,crc_word_valid_mem,crc_frame_mem;
wire [8:0] crc_line_y_mem;
wire [11:0] crc_width_mem,last_crc_error_y_mem;
wire [31:0] crc_word_data_mem;
wire crc_result_valid_mem,crc_result_ok_mem,line_error_event_mem;
wire [15:0] expected_crc_mem,observed_crc_mem,crc_failure_count_mem;
reg line_req_pulse_pxl=0;reg [11:0] line_req_y_pxl=0;
wire bridge_line_ready_pulse,bridge_line_ready_bank;
wire [11:0] bridge_line_ready_y;
reg bridge_pixel_req_valid_q=0;
reg [11:0] bridge_pixel_req_x_q=0,bridge_pixel_req_y_q=0;
wire bridge_pixel_req_ready,bridge_pixel_valid,bridge_pixel_error;
wire [15:0] bridge_pixel_data;
reg inject_once=0;
wire [31:0] injected_burst_data=(inject_once && u_line_bridge.word_index==5) ? mem_burst_rsp_data^32'd1 : mem_burst_rsp_data;
always @(posedge sdram_ctrl_clk)if(inject_once&&crc_word_valid_mem&&u_line_bridge.word_index==5)inject_once<=0;
    frame_buffer_manager #(
        .FRAME_WIDTH(640), .FRAME_HEIGHT(480),
        .FRAME_A_BASE_WORD(FRAME_A_BASE_WORD),
        .FRAME_B_BASE_WORD(FRAME_B_BASE_WORD),
        .LOAD_TIMEOUT_CYCLES(32'h3FFF_FFFF),
        .INPUT_BOTTOM_UP(1)
    ) u_frame_mgr (
        .clk(ctrl_clk50), .rst_n(ctrl_rst_img_n),
        .pixel_valid(d03_valid), .pixel_ready(frame_pixel_ready),
        .pixel_rgb565(d03_rgb565), .pixel_x(d03_x), .pixel_y(d03_y),
        .pixel_last(d03_last),
        .frame_width_i(d01_width), .frame_height_i(d01_height),
        .load_start(frame_load_start), .load_abort(bmp_start_r),
        .load_busy(frame_load_busy), .load_done(frame_load_done), .load_error(frame_load_error),
        .load_error_detail(frame_load_error_detail),
        .load_timeout(frame_load_timeout), .load_conflict(frame_load_conflict),
        .load_frame_select(frame_load_select), .show_frame_select(frame_show_select),
        .frame_ready(frame_ready), .swap_request(frame_swap_request),
        .frame_boundary(frame_boundary_ctrl), .swap_ack(frame_swap_ack),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_addr_word(mem_wr_addr_word), .mem_wr_data(mem_wr_data),
        .mem_wr_strb(mem_wr_strb), .mem_wr_done(mem_wr_done),
        .mem_wr_error(mem_wr_error)
    );
    mem_write_cdc u_mem_write_cdc (
        .wr_clk(ctrl_clk50), .wr_rst_n(ctrl_rst_img_n),
        .wr_valid(mem_wr_valid), .wr_ready(mem_wr_ready),
        .wr_addr_word(mem_wr_addr_word), .wr_data(mem_wr_data), .wr_strb(mem_wr_strb),
        .wr_done(mem_wr_done), .wr_error(mem_wr_error),
        .rd_clk(sdram_ctrl_clk), .rd_rst_n(mem_rst_n),
        .rd_valid(mem_cdc_valid), .rd_ready(mem_cdc_ready),
        .rd_addr_word(mem_cdc_addr_word), .rd_data(mem_cdc_data), .rd_strb(mem_cdc_strb),
        .rd_done(mem_cdc_done), .rd_error(mem_cdc_error)
    );
    sdram_arbiter #(
        .FRAME_A_BASE_WORD(FRAME_A_BASE_WORD),
        .FRAME_B_BASE_WORD(FRAME_B_BASE_WORD),
        .AUDIO_BUF_BASE_WORD(AUDIO_BUF_BASE_WORD)
    ) u_arbiter (
        .clk(sdram_ctrl_clk), .rst_n(mem_rst_n),
        .line_urgent(LEGACY_PRIORITY ? 1'b0 : line_urgent_mem),
        .wr_valid(mem_cdc_valid), .wr_ready(mem_cdc_ready),
        .wr_addr_word(mem_cdc_addr_word), .wr_data(mem_cdc_data),
        .wr_strb(mem_cdc_strb), .wr_done(mem_cdc_done), .wr_error(mem_cdc_error),
        .rd_valid(mem_rd_valid), .rd_ready(mem_rd_ready),
        .rd_addr_word(mem_rd_addr_word), .rd_rsp_valid(mem_rd_rsp_valid),
        .rd_data(mem_rd_rsp_data), .rd_error(mem_rd_error),
        .burst_valid(mem_burst_valid), .burst_ready(mem_burst_ready),
        .burst_addr_word(mem_burst_addr_word), .burst_len(mem_burst_len),
        .burst_rsp_valid(mem_burst_rsp_valid), .burst_rsp_data(mem_burst_rsp_data),
        .burst_rsp_last(mem_burst_rsp_last), .burst_rsp_error(mem_burst_rsp_error),
        .sdram_init_done(arbiter_init_done), .busy(),
        .phy_req_valid(phy_req_valid), .phy_req_ready(phy_req_ready),
        .phy_req_write(phy_req_write), .phy_req_addr_word(phy_req_addr_word),
        .phy_req_wdata(phy_req_wdata), .phy_req_wstrb(phy_req_wstrb),
        .phy_rsp_valid(phy_rsp_valid), .phy_rsp_rdata(phy_rsp_rdata),
        .phy_rsp_error(phy_rsp_error), .phy_init_done(phy_init_done),
        .phy_burst_valid(phy_burst_valid), .phy_burst_ready(phy_burst_ready),
        .phy_burst_addr_word(phy_burst_addr_word), .phy_burst_len(phy_burst_len),
        .phy_burst_rsp_valid(phy_burst_rsp_valid), .phy_burst_rsp_data(phy_burst_rsp_data),
        .phy_burst_rsp_last(phy_burst_rsp_last), .phy_burst_rsp_error(phy_burst_rsp_error)
    );
    eg4_sdram_phy #(
        .INIT_WAIT_CYCLES(10000), .TRP_CYCLES(2), .TRCD_CYCLES(2),
        .CAS_LATENCY(3), .TRSC_CYCLES(2), .TRFC_CYCLES(7),
        .REFRESH_INTERVAL_CYCLES(390), .REQUEST_TIMEOUT_CYCLES(65535)
    ) u_phy (
        .clk(sdram_ctrl_clk), .rst_n(mem_rst_phy_n),
        .req_valid(phy_req_valid), .req_ready(phy_req_ready),
        .req_write(phy_req_write), .req_addr_word(phy_req_addr_word),
        .req_wdata(phy_req_wdata), .req_wstrb(phy_req_wstrb),
        .rsp_valid(phy_rsp_valid), .rsp_rdata(phy_rsp_rdata),
        .rsp_error(phy_rsp_error), .timeout_error(phy_timeout_error),
        .init_done(phy_init_done), .sdram_clk(sdram_clk),
        .burst_req_valid(phy_burst_valid), .burst_req_ready(phy_burst_ready),
        .burst_req_addr_word(phy_burst_addr_word), .burst_req_len(phy_burst_len),
        .burst_rsp_valid(phy_burst_rsp_valid), .burst_rsp_rdata(phy_burst_rsp_data),
        .burst_rsp_last(phy_burst_rsp_last), .burst_rsp_error(phy_burst_rsp_error),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n), .sdram_ba(sdram_ba),
        .sdram_addr(sdram_addr), .sdram_dq(sdram_dq), .sdram_dqm(sdram_dqm)
    );
    frame_line_crc u_frame_line_crc (
        .write_clk(ctrl_clk50),.write_rst_n(ctrl_rst_img_n),
        .pixel_valid(d03_valid),.pixel_ready(frame_pixel_ready),.pixel_rgb565(d03_rgb565),
        .pixel_x(d03_x),.pixel_y(d03_y),.image_width(d01_width),.write_frame_select(frame_load_select),
        .read_clk(sdram_ctrl_clk),.read_rst_n(mem_rst_bridge_n),
        .line_start(crc_line_start_mem),.read_frame_select(crc_frame_mem),.read_line_y(crc_line_y_mem),.read_width(crc_width_mem),
        .word_valid(crc_word_valid_mem),.word_data(crc_word_data_mem),.line_done(crc_line_done_mem),
        .result_valid(crc_result_valid_mem),.result_ok(crc_result_ok_mem),.expected_crc(expected_crc_mem),.observed_crc(observed_crc_mem)
    );
    direct_line_bridge_dp #(.FRAME_WIDTH(640), .FRAME_HEIGHT(480)) u_line_bridge (
        .ctrl_clk(sdram_ctrl_clk),
        .ctrl_rst_n(mem_rst_bridge_n),
        .pxl_clk(pxlclk_i),
        .pxl_rst_n(pxl_rst_n),
        .line_req_pulse_pxl(line_req_pulse_pxl),
        .line_req_y_pxl(line_req_y_pxl),
        .frame_base_word_ctrl(frame_base_word_mem),
        .line_urgent_ctrl(line_urgent_mem),
        .raster_frame_start_pxl(1'b0),.frame_changed_pxl(frame_swap_event_pxl),.front_frame_select_pxl(frame_select_sync_pxl),
        .front_ready_ctrl(front_ready_mem),.front_frame_select_ctrl(frame_show_mem2),.front_width_ctrl(width_sync_mem),
        .front_height_ctrl(height_sync_mem),.verified_frame_count_ctrl(verified_frame_count_mem),
        .crc_line_start_ctrl(crc_line_start_mem),.crc_frame_select_ctrl(crc_frame_mem),.crc_line_y_ctrl(crc_line_y_mem),
        .crc_width_ctrl(crc_width_mem),.crc_word_valid_ctrl(crc_word_valid_mem),.crc_word_data_ctrl(crc_word_data_mem),
        .crc_line_done_ctrl(crc_line_done_mem),.crc_result_valid_ctrl(crc_result_valid_mem),.crc_result_ok_ctrl(crc_result_ok_mem),
        .line_error_event_ctrl(line_error_event_mem),.crc_failure_count_ctrl(crc_failure_count_mem),.last_crc_error_y_ctrl(last_crc_error_y_mem),
        .line_ready_pulse_pxl(bridge_line_ready_pulse),
        .line_ready_y_pxl(bridge_line_ready_y),
        .line_ready_bank_pxl(bridge_line_ready_bank),
        .pixel_req_valid(bridge_pixel_req_valid_q),
        .pixel_req_x(bridge_pixel_req_x_q),
        .pixel_req_y(bridge_pixel_req_y_q),
        .pixel_req_ready(bridge_pixel_req_ready),
        .pixel_valid(bridge_pixel_valid),
        .pixel_data(bridge_pixel_data),
        .pixel_error(bridge_pixel_error),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_ready(mem_rd_ready),
        .mem_rd_addr_word(mem_rd_addr_word),
        .mem_rd_rsp_valid(mem_rd_rsp_valid),
        .mem_rd_rsp_data(mem_rd_rsp_data),
        .mem_rd_error(mem_rd_error),
         .mem_burst_valid(mem_burst_valid),
         .mem_burst_ready(mem_burst_ready),
         .mem_burst_addr_word(mem_burst_addr_word),
         .mem_burst_len(mem_burst_len),
         .mem_burst_rsp_valid(mem_burst_rsp_valid),
         .mem_burst_rsp_data(injected_burst_data),
         .mem_burst_rsp_last(mem_burst_rsp_last),
         .mem_burst_rsp_error(mem_burst_rsp_error)
    );

wire [17:0] command_pin;wire [3:0] mask_pin;wire write_pin;wire [31:0] data_pin;
assign #4 command_pin={sdram_cke,sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n,sdram_ba,sdram_addr};
assign #4 mask_pin=sdram_dqm;assign #4 write_pin=u_phy.dq_oe;assign #4 data_pin=u_phy.dq_out;
wire [31:0] read_pin,physical_reads,physical_writes,physical_refreshes,physical_stops;
assign sdram_dq=read_pin;
sdram_timed_model device_model(.clk(device_clk),.cke(command_pin[17]),.cs_n(command_pin[16]),
 .ras_n(command_pin[15]),.cas_n(command_pin[14]),.we_n(command_pin[13]),.ba(command_pin[12:11]),.addr(command_pin[10:0]),
 .dqm(mask_pin),.write_oe(write_pin),.write_data(data_pin),.read_data(read_pin),
 .reads(physical_reads),.writes(physical_writes),.refreshes(physical_refreshes),.stops(physical_stops));
function [15:0] image_pixel;
 input frame;input integer y,x;
 begin image_pixel=(frame ? 16'h8421 : 16'h1248) ^ (y*16'h0127) ^ (x*16'h003d);end
endfunction
integer checks=0,accepted_pixels=0,ready_serial=0,last_ready_y=-1;
realtime last_ready_time=0;
reg accepted_now;reg [15:0] expected_now;
always @(posedge pxlclk_i)begin
 accepted_now=bridge_pixel_req_valid_q&&bridge_pixel_req_ready;
 expected_now=image_pixel(frame_select_sync_pxl,bridge_pixel_req_y_q,bridge_pixel_req_x_q);
 #2;
 if(pxl_rst_n) begin
  if(bridge_line_ready_pulse)begin ready_serial=ready_serial+1;last_ready_y=bridge_line_ready_y;last_ready_time=$realtime;end
  if(bridge_pixel_valid!==accepted_now)$fatal(1,"Pixel tag latency");
  if(accepted_now)begin
   if(bridge_pixel_data!==expected_now)$fatal(1,"Pixel mismatch frame=%0d y=%0d x=%0d expected=%h actual=%h",frame_select_sync_pxl,bridge_pixel_req_y_q,bridge_pixel_req_x_q,expected_now,bridge_pixel_data);
   checks=checks+1;
  end
 end
end
always @(posedge sdram_ctrl_clk)begin
 if(mem_rst_n && u_line_bridge.refill_write && bridge_pixel_req_valid_q&&bridge_pixel_req_ready &&
    u_line_bridge.fill_bank==u_line_bridge.selected_bank)$fatal(1,"Display bank overwritten during accepted reads");
end
task load_frame;
 integer row_index,x,guard;
 reg selected;
 begin
  @(negedge ctrl_clk50);bmp_start_r=1;
  @(negedge ctrl_clk50);bmp_start_r=0;
  repeat(54)@(negedge ctrl_clk50);
  @(negedge ctrl_clk50);frame_load_start=1;
  @(negedge ctrl_clk50);frame_load_start=0;selected=frame_load_select;
  for(row_index=SOURCE_HEIGHT-1;row_index>=0;row_index=row_index-1)for(x=0;x<SOURCE_WIDTH;x=x+1)begin
   d03_valid=1;d03_x=x;d03_y=row_index;d03_rgb565=image_pixel(selected,row_index,x);d03_last=(row_index==0&&x==SOURCE_WIDTH-1);
   @(posedge ctrl_clk50);guard=0;
   while(!frame_pixel_ready)begin @(posedge ctrl_clk50);guard=guard+1;if(guard>50000)$fatal(1,"Input pixel stalled");end
   accepted_pixels=accepted_pixels+1;
   @(negedge ctrl_clk50);
  end
  d03_valid=0;d03_last=0;
  wait(frame_load_done || frame_load_error);#1;
  if(frame_load_error)$fatal(1,"Frame manager error detail=%h",frame_load_error_detail);
  $display("ACTUAL_FRAME_LOAD frame=%0d accepted=%0d",selected,accepted_pixels);
 end
endtask
task swap_frame;
 begin
  @(negedge ctrl_clk50);frame_swap_request=1;
  @(negedge ctrl_clk50);frame_swap_request=0;frame_boundary_ctrl=1;
  @(negedge ctrl_clk50);frame_boundary_ctrl=0;
  wait(frame_swap_ack);repeat(6)@(negedge pxlclk_i);request_row(0);
 end
endtask
task request_row;
 input integer y;
 begin @(negedge pxlclk_i);line_req_y_pxl=y;line_req_pulse_pxl=1;
 @(negedge pxlclk_i);line_req_pulse_pxl=0;end
endtask
task await_row;
 input integer y,serial;
 input realtime started;
 input realtime bound;
 begin
  while(ready_serial<=serial)begin
   @(negedge pxlclk_i);if($realtime-started>bound)$fatal(1,"Row deadline y=%0d latency=%0.1f state=%0d CRC=%0d",y,$realtime-started,u_line_bridge.state,crc_failure_count_mem);
  end
  if(last_ready_y!=y)$fatal(1,"Stale/wrong row published got=%0d want=%0d",last_ready_y,y);
  $display("VERIFIED_ROW frame=%0d y=%0d latency_ns=%0.3f",frame_select_sync_pxl,y,last_ready_time-started);
 end
endtask
task display_row;
 input integer y,next_y;
 integer x,prior_serial,start_checks;
 realtime started;
 begin
  prior_serial=ready_serial;started=$realtime;start_checks=checks;
  for(x=0;x<SOURCE_WIDTH;x=x+1)begin
   @(negedge pxlclk_i);bridge_pixel_req_valid_q=1;bridge_pixel_req_x_q=x;bridge_pixel_req_y_q=y;
   line_req_pulse_pxl=(x==0&&next_y>=0);line_req_y_pxl=next_y;
  end
  @(negedge pxlclk_i);bridge_pixel_req_valid_q=0;line_req_pulse_pxl=0;
  if(checks-start_checks!=SOURCE_WIDTH)$fatal(1,"Incomplete displayed row %0d",checks-start_checks);
  if(next_y>=0)await_row(next_y,prior_serial,started,22222.222);
 end
endtask
integer initial_serial,row_index;
realtime started;
initial begin
 #200;ctrl_rst_img_n=1;mem_rst_n=1;pxl_rst_n=1;
 wait(phy_init_done);
 // Both reference and SDRAM contents come through the actual frame manager/write CDC.
 load_frame();swap_frame();load_frame();swap_frame();
 repeat(8)@(negedge pxlclk_i);allow_refill=1;
 initial_serial=ready_serial;started=$realtime;
 // The sole scheduler has explicitly requested row zero after the real commit.
 await_row(0,initial_serial,started,22222.222);
 fork
  begin load_frame();end
  begin
   for(row_index=0;row_index<SOURCE_HEIGHT-1;row_index=row_index+1)display_row(row_index,row_index+1);
   display_row(SOURCE_HEIGHT-1,-1);
  end
 join
 if(crc_failure_count_mem!=0)$fatal(1,"Unexpected clean CRC failure");
 // Switch during a pending old-generation refill. Only new row0 may publish.
 request_row(2);wait(u_line_bridge.state==3);
 @(negedge pxlclk_i);bridge_pixel_req_valid_q=1;bridge_pixel_req_x_q=SOURCE_WIDTH;bridge_pixel_req_y_q=SOURCE_HEIGHT-1;
 #1;if(bridge_pixel_req_ready)$fatal(1,"STALE_ROW_PADDING_ACCEPTED x=%0d width=%0d",bridge_pixel_req_x_q,SOURCE_WIDTH);
 @(negedge pxlclk_i);bridge_pixel_req_valid_q=0;
 initial_serial=ready_serial;started=$realtime;swap_frame();
 await_row(0,initial_serial,started,60000);display_row(0,1);display_row(1,-1);
 // Persistent stored corruption must never publish, and preserves current row1.
 device_model.memory[21'h40000+2*320+5]=device_model.memory[21'h40000+2*320+5]^32'd1;
 initial_serial=ready_serial;request_row(2);#60000;
 if(ready_serial!=initial_serial || crc_failure_count_mem!=2 || last_crc_error_y_mem!=2)$fatal(1,"Persistent corruption not isolated");
 display_row(1,-1);
 // Single transfer corruption: discard first refill, bounded clean retry succeeds.
 inject_once=1;initial_serial=ready_serial;started=$realtime;request_row(3);
 await_row(3,initial_serial,started,60000);display_row(3,-1);
 if(crc_failure_count_mem!=3 || verified_frame_count_mem!=1)$fatal(1,"Transient/full-frame integrity counter");
 $display("MEMORY_PIXEL_INTEGRITY_PASS pixels=%0d input_pixels=%0d writes=%0d reads=%0d refresh=%0d CRC_injected=%0d; actual frame_manager/writeCDC/arbiter/timedPHY/vendorBRAM; concurrent backload,epoch,CRC",checks,accepted_pixels,physical_writes,physical_reads,physical_refreshes,crc_failure_count_mem);$finish;
end
initial begin #(SOURCE_HEIGHT*800000+2000000);$fatal(1,"Pixel integration timeout");end
endmodule
