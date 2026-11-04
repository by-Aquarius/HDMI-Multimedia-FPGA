`timescale 1ns/1ps
// Verification-only EM638325 command/data-window model. Not a synthesis source.
module sdram_timed_model #(
    parameter real T_ACCESS=5.4,
    parameter real T_HOLD=1.0,
    parameter real T_INPUT_SETUP=1.5,
    parameter real T_INPUT_HOLD=1.0,
    parameter real READ_PATH_DELAY=4.9
) (
    input wire clk,cke,cs_n,ras_n,cas_n,we_n,
    input wire [1:0] ba,
    input wire [10:0] addr,
    input wire [3:0] dqm,
    input wire write_oe,
    input wire [31:0] write_data,
    output wire [31:0] read_data,
    output reg [31:0] reads=0,writes=0,refreshes=0,stops=0
);
    reg [31:0] memory[0:2097151];
    reg [10:0] row[0:3];
    reg [3:0] active=0;
    reg [31:0] chip_data=32'hzzzzzzzz;
    reg driving=0,reading=0;
    reg [3:0] mask_delay_a=15,mask_delay_b=15;
    integer read_delay=0,read_count=0,read_length=8,cas_latency=3;
    integer stop_delay=-1,read_bank=0,read_column=0,read_start=0;
    integer n,lane,index;
    reg single_write=1;
    reg [31:0] next_data;
    realtime last_command_change=-100,last_write_change=-100;
    realtime activated[0:3],precharged[0:3],last_write[0:3];
    realtime last_refresh=-1000,last_mode=-1000,bus_release_at=-1000;
    reg initialized_mode=0;
    reg [21:0] sampled_command;
    assign #(READ_PATH_DELAY) read_data=chip_data;
    initial for(n=0;n<4;n=n+1) begin
        row[n]=0;activated[n]=-1000;precharged[n]=-1000;last_write[n]=-1000;
    end
    always @(cke,cs_n,ras_n,cas_n,we_n,ba,addr,dqm) last_command_change=$realtime;
    always @(write_oe,write_data) last_write_change=$realtime;
    always @(posedge write_oe) begin
        if(driving || $realtime<bus_release_at) $fatal(1,"SDRAM read/write bus contention at %0t",$time);
    end
    task release_bus;
        begin
            reading=0;driving=0;bus_release_at=$realtime+T_ACCESS;
            chip_data<=#(T_HOLD) 32'hxxxxxxxx;
            chip_data<=#(T_ACCESS) 32'hzzzzzzzz;
        end
    endtask
    always @(posedge clk) begin
        if(cke && !cs_n) begin
            if(($realtime-last_command_change)<T_INPUT_SETUP)
                $fatal(1,"SDRAM command setup violated margin=%0.3f at %0t",$realtime-last_command_change,$time);
            sampled_command={cke,cs_n,ras_n,cas_n,we_n,ba,addr,dqm};
            if({ras_n,cas_n,we_n}!=3'b111) begin
                if(($realtime-last_refresh)<63) $fatal(1,"SDRAM tRFC violated");
                if(($realtime-last_mode)<40) $fatal(1,"SDRAM tMRS violated");
            end
            if(initialized_mode && ($realtime-last_refresh)>15625) $fatal(1,"Refresh retention interval exceeded");
            mask_delay_b=mask_delay_a;mask_delay_a=dqm;
            if(stop_delay==0) begin release_bus();stop_delay=-1;end
            else if(stop_delay>0) stop_delay=stop_delay-1;
            if(reading) begin
                if(read_delay>0) read_delay=read_delay-1;
                else if(read_count<read_length) begin
                    index={read_bank[1:0],row[read_bank],read_column[7:0]};
                    next_data=memory[index];
                    for(lane=0;lane<4;lane=lane+1)
                        if(mask_delay_b[lane]) next_data[lane*8+:8]=8'hzz;
                    if(!(&mask_delay_b)) begin
                        if(write_oe) $fatal(1,"SDRAM bus contention during output");
                        driving=1;
                    end else driving=0;
                    chip_data<=#(T_HOLD) 32'hxxxxxxxx;
                    chip_data<=#(T_ACCESS) next_data;
                    read_column=(read_start&~7)|((read_column+1)&7);
                    read_count=read_count+1;reads=reads+1;
                end else release_bus();
            end
            case({ras_n,cas_n,we_n})
                3'b011: begin // ACTIVATE
                    if(active[ba]) $fatal(1,"ACTIVATE on open bank");
                    if(($realtime-precharged[ba])<21) $fatal(1,"SDRAM tRP violated");
                    active[ba]=1;row[ba]=addr;activated[ba]=$realtime;
                end
                3'b101: begin // READ, CAS3/BL8
                    if(!active[ba] || ($realtime-activated[ba])<21) $fatal(1,"SDRAM READ tRCD/bank");
                    reading=1;read_delay=cas_latency-2;read_count=0;
                    read_bank=ba;read_start=addr[7:0];read_column=addr[7:0];stop_delay=-1;
                end
                3'b100: begin // single-word WRITE
                    if(!active[ba] || ($realtime-activated[ba])<21) $fatal(1,"SDRAM WRITE tRCD/bank");
                    if(!write_oe || ($realtime-last_write_change)<T_INPUT_SETUP) $fatal(1,"SDRAM write data setup/OE");
                    if(driving) $fatal(1,"SDRAM WRITE while read output active");
                    index={ba,row[ba],addr[7:0]};
                    for(lane=0;lane<4;lane=lane+1) if(!dqm[lane]) begin
                        if((^write_data[lane*8+:8])===1'bx) $fatal(1,"Unknown write lane");
                        memory[index][lane*8+:8]=write_data[lane*8+:8];
                    end
                    writes=writes+1;last_write[ba]=$realtime;
                end
                3'b010: begin // PRECHARGE
                    for(n=0;n<4;n=n+1) if(addr[10] || n==ba) begin
                        if(active[n] && ($realtime-activated[n])<42) $fatal(1,"SDRAM tRAS violated");
                        if(($realtime-last_write[n])<40) $fatal(1,"SDRAM tWR violated");
                        active[n]=0;precharged[n]=$realtime;
                    end
                    release_bus();
                end
                3'b001: begin // AUTO REFRESH
                    if(active!=0) $fatal(1,"SDRAM REFRESH with open bank");
                    for(n=0;n<4;n=n+1) if(($realtime-precharged[n])<21) $fatal(1,"REFRESH tRP");
                    last_refresh=$realtime;refreshes=refreshes+1;
                end
                3'b000: begin // MRS
                    if(active!=0 || addr[2:0]!=3 || addr[6:4]!=3 || !addr[9]) $fatal(1,"Unexpected SDRAM mode");
                    cas_latency=addr[6:4];read_length=8;single_write=addr[9];last_mode=$realtime;initialized_mode=1;
                end
                3'b110: begin stop_delay=cas_latency-1;stops=stops+1;end
                default: begin end
            endcase
        end else if(!cke) begin
            driving=0;initialized_mode=0;chip_data<=#(T_ACCESS) 32'hzzzzzzzz;
        end
    end
    always @(posedge clk) begin
        if(cke && !cs_n) begin
            #(T_INPUT_HOLD);
            if(sampled_command!=={cke,cs_n,ras_n,cas_n,we_n,ba,addr,dqm})
                $fatal(1,"SDRAM command hold violated");
        end
    end
endmodule
