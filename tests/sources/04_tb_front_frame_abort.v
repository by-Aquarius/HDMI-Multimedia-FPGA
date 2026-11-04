`timescale 1ns/1ps
module tb_front_frame_abort;
reg clk=0,rst_n=0,load_start=0,pixel_valid=0,pixel_last=0;
reg bmp_start=0;
reg [11:0] pixel_x=0,pixel_y=0;
reg [15:0] pixel_rgb565=0;
reg swap_request=0,frame_boundary=0;
wire pixel_ready,load_busy,load_done,load_error,load_timeout,load_conflict;
wire [7:0] load_error_detail;
wire load_frame_select,show_frame_select;
wire [1:0] frame_ready;
wire swap_ack,mem_wr_valid;
wire [20:0] mem_wr_addr_word;
wire [31:0] mem_wr_data;
wire [3:0] mem_wr_strb;
wire load_abort = bmp_start && load_busy;
reg mem_wr_done=0;
integer cycles=0,checks=0,writes=0,commits=0;
reg has_front=0;
always #10 clk=~clk;
wire mem_wr_ready=cycles%4!=0;
always @(posedge clk) begin
 cycles<=cycles+1;mem_wr_done<=mem_wr_valid&&mem_wr_ready;
 if(swap_ack)begin has_front<=1;commits<=commits+1;end
 if(rst_n&&has_front)begin
  checks=checks+1;
  if(!frame_ready[show_frame_select])$fatal(1,"FRONT_INVALIDATED show=%b load=%b ready=%b abort=%b",show_frame_select,load_frame_select,frame_ready,load_abort);
 end
 if(mem_wr_valid&&mem_wr_ready)begin
  writes=writes+1;
  if(has_front && ((show_frame_select&&mem_wr_addr_word>=16)||(!show_frame_select&&mem_wr_addr_word<16)))
   $fatal(1,"Displayed buffer written");
 end
end
frame_buffer_manager #(.FRAME_WIDTH(4),.FRAME_HEIGHT(2),.FRAME_B_BASE_WORD(21'd16),.LOAD_TIMEOUT_CYCLES(128)) dut (
 .clk(clk),.rst_n(rst_n),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
 .pixel_rgb565(pixel_rgb565),.pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_last(pixel_last),
 .frame_width_i(12'd4),.frame_height_i(12'd2),.load_start(load_start),.load_abort(load_abort),
 .load_busy(load_busy),.load_done(load_done),.load_error(load_error),.load_error_detail(load_error_detail),
 .load_timeout(load_timeout),.load_conflict(load_conflict),.load_frame_select(load_frame_select),
 .show_frame_select(show_frame_select),.frame_ready(frame_ready),.swap_request(swap_request),
 .frame_boundary(frame_boundary),.swap_ack(swap_ack),.mem_wr_valid(mem_wr_valid),.mem_wr_ready(mem_wr_ready),
 .mem_wr_addr_word(mem_wr_addr_word),.mem_wr_data(mem_wr_data),.mem_wr_strb(mem_wr_strb),
 .mem_wr_done(mem_wr_done),.mem_wr_error(1'b0)
);
task file_begin;
 begin
  @(negedge clk);bmp_start=1;
  @(negedge clk);bmp_start=0;
  // Actual top aborts at BMP file open, before the header produces load_start.
  repeat(40)@(negedge clk);
 end
endtask
task start_frame;
 begin @(negedge clk);load_start=1;@(negedge clk);load_start=0;end
endtask
task send_frame;
 integer x,y;
 begin
  start_frame();
  for(y=0;y<2;y=y+1)for(x=0;x<4;x=x+1)begin
   @(negedge clk);pixel_valid=1;pixel_x=x;pixel_y=y;pixel_last=y==1&&x==3;pixel_rgb565={12'habc,y[0],x[1:0],1'b0};
   @(posedge clk);while(!pixel_ready)@(posedge clk);
   @(negedge clk);pixel_valid=0;pixel_last=0;
  end
  wait(load_done);@(negedge clk);
 end
endtask
task commit_frame;
 begin
  @(negedge clk);swap_request=1;
  @(negedge clk);swap_request=0;frame_boundary=1;
  @(negedge clk);frame_boundary=0;
  repeat(3)@(negedge clk);
 end
endtask
integer round;
initial begin
 repeat(4)@(negedge clk);rst_n=1;
 file_begin();send_frame();commit_frame();
 for(round=0;round<4;round=round+1)begin file_begin();send_frame();commit_frame();end
 // File open before the next header is not a busy-load abort.
 file_begin();send_frame();file_begin();
 if(!frame_ready[!show_frame_select])$fatal(1,"Prepared back frame lost before load");
 start_frame();
 if(frame_ready[!show_frame_select])$fatal(1,"New load did not clear back frame");
 file_begin();
 if(frame_ready[!show_frame_select])$fatal(1,"Busy abort left back frame ready");
 if(!frame_ready[show_frame_select])$fatal(1,"Busy abort lost front frame");
 // An incomplete load times out without invalidating the front frame.
 start_frame();repeat(140)@(negedge clk);
 if(load_busy || !frame_ready[show_frame_select])$fatal(1,"Timeout front ownership");
 file_begin();send_frame();commit_frame();
 $display("FRONT_FRAME_ABORT_PASS checks=%0d commits=%0d writes=%0d gated-header/no-front-write/busy-abort/timeout",checks,commits,writes);
 $finish;
end
initial begin #200000;$fatal(1,"Front ownership test watchdog");end
endmodule
