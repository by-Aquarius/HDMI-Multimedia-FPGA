`timescale 1ns / 1ps
module tb_audio_mode_protocol;
    reg clk=0,rst_n=0,rx=1;
    always #5 clk=!clk;
    wire tx;
    wire [15:0] keys;
    wire [2:0] audio_mode;
    wire text_ready,text_done,text_begin,text_write,text_commit,restore_default,cancel_urgent,urgent,upload_active,interrupt_active;
    wire [7:0] result,seconds;
    wire [6:0] length;
    wire [5:0] address;
    wire [15:0] code;
    wire [31:0] diagnostic;
    wire bitmap_write,bitmap_commit;
    wire [11:0] bitmap_address,bitmap_width;
    wire [15:0] bitmap_data;
    reg bitmap_done=0;
    reg [7:0] frame_wait=0;
    reg suppress_done=0;
    wire [7:0] monitor_data;
    wire monitor_valid;
    reg [7:0] replies [0:1023];
    integer received=0,sequence_id=0,checks=0,key_count=0,timer_count,i,base;
    reg [15:0] crc;
    reg [7:0] packet [0:9];
    host_control_bridge #(.BIT_CYCLES(8),.FRAME_TIMEOUT(2000),.COMMIT_TIMEOUT_CYCLES(20000),.UPLOAD_TIMEOUT_CYCLES(10000)) bridge (
        .clk(clk),.rst_n(rst_n),.serial_rx(rx),.serial_tx(tx),.active_index(5'd2),.media_count(5'd6),
        .playback_state(3'd3),.volume_level(5'd8),.brightness(8'd10),.speed_level(3'd2),.error_code(8'd0),
        .status_flags({1'b0,interrupt_active,1'b1,5'b00001}),.fault_snapshot(32'h01234567),.live_snapshot(32'h12345678),
        .audio_snapshot(32'h23456789),.load_snapshot(32'h3456789a),.key_pulse(keys),.audio_diagnostic_mode(audio_mode),
        .text_ready(text_ready),.text_done(text_done && !suppress_done),.text_result(result),
        .recovery_snapshot(32'h456789ab),.scheduler_snapshot(32'h56789abc),.subtitle_snapshot(diagnostic),
        .memory_health_snapshot(32'hc4a50102),.memory_crc_snapshot(32'h12345678),.memory_pass_snapshot(32'hc5000900),
        .prompt_snapshot(32'h11223344),.audio_health_snapshot(32'h55667788),
        .upload_in_progress(upload_active),.text_begin(text_begin),.text_urgent(urgent),.text_seconds(seconds),.text_length(length),
        .text_write(text_write),.text_address(address),.text_code(code),.text_commit(text_commit),
        .restore_default(restore_default),.cancel_urgent(cancel_urgent)
    );
    subtitle_text_renderer #(.SECOND_CYCLES(1000000)) renderer (
        .clk(clk),.rst_n(rst_n),.text_begin(text_begin),.upload_in_progress(upload_active),.upload_urgent(urgent),
        .upload_length(length),.upload_seconds(seconds),.text_write(text_write),.text_address(address),.text_code(code),
        .text_commit(text_commit),.restore_default(restore_default),.cancel_urgent(cancel_urgent),
        .ready(text_ready),.done(text_done),.result(result),.interrupt_active(interrupt_active),.diagnostic(diagnostic),
        .bitmap_ready(1'b1),.bitmap_done(bitmap_done),.bitmap_write(bitmap_write),.bitmap_address(bitmap_address),
        .bitmap_data(bitmap_data),.bitmap_width(bitmap_width),.bitmap_commit(bitmap_commit)
    );
    host_uart_bytes #(.BIT_CYCLES(8)) monitor (
        .clk(clk),.rst_n(rst_n),.serial_rx(tx),.serial_tx(),.rx_data(monitor_data),.rx_valid(monitor_valid),
        .tx_ready(),.tx_valid(1'b0),.tx_data(8'd0)
    );
    always @(negedge clk) begin
        if(monitor_valid) begin replies[received]=monitor_data;received=received+1;end
        if(keys!=0) key_count=key_count+1;
    end
    always @(posedge clk) begin
        bitmap_done<=0;
        if(bitmap_commit) frame_wait<=20;
        else if(frame_wait!=0) begin frame_wait<=frame_wait-1'b1;if(frame_wait==1)bitmap_done<=1;end
    end
    function [15:0] crc_byte;
        input [15:0] previous;
        input [7:0] data;
        integer b;
        reg [15:0] value;
        begin
            value=previous ^ {data,8'd0};
            for(b=0;b<8;b=b+1) value=value[15] ? (value<<1)^16'h1021 : value<<1;
            crc_byte=value;
        end
    endfunction
    task send_byte;
        input [7:0] value;
        integer b;
        begin
            @(negedge clk);rx=0;repeat(8)@(negedge clk);
            for(b=0;b<8;b=b+1) begin rx=value[b];repeat(8)@(negedge clk);end
            rx=1;repeat(8)@(negedge clk);
        end
    endtask
    task request;
        input [7:0] command;
        input [15:0] offset,data;
        input corrupt;
        begin
            sequence_id=sequence_id+1;
            packet[0]=8'ha5;packet[1]=8'h5a;packet[2]=command;packet[3]=sequence_id;
            packet[4]=offset[7:0];packet[5]=offset[15:8];packet[6]=data[7:0];packet[7]=data[15:8];
            crc=16'hffff;for(i=2;i<8;i=i+1)crc=crc_byte(crc,packet[i]);
            packet[8]=crc[7:0] ^ corrupt;packet[9]=crc[15:8];
            base=received;
            for(i=0;i<10;i=i+1)send_byte(packet[i]);
        end
    endtask
    task acknowledge;
        input [7:0] command,expected_result;
        begin
            timer_count=0;
            while(received<base+10 && timer_count<30000) begin @(negedge clk);timer_count=timer_count+1;end
            if(received!=base+10 || replies[base+2]!=(command|8'h80) || replies[base+3]!=sequence_id[7:0]) $fatal(1,"Missing or wrong UART response");
            crc=16'hffff;for(i=2;i<8;i=i+1)crc=crc_byte(crc,replies[base+i]);
            if({replies[base+9],replies[base+8]}!==crc) $fatal(1,"Reply CRC mismatch");
            if(command>9 && replies[base+6]!==expected_result) $fatal(1,"Wrong command result command=%h got=%h expected=%h",command,replies[base+6],expected_result);
            checks=checks+1;
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        wait(text_ready);
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==0 || replies[base+7]!==8'ha3) $fatal(1,"Default mode/capability bytes wrong");
        request(8'h13,0,1,0);acknowledge(8'h13,0);
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==1 || replies[base+7]!==8'ha3) $fatal(1,"Pair mode not acknowledged");
        request(8'h13,0,2,0);acknowledge(8'h13,1);
        request(8'h13,0,0,1);repeat(2000)@(negedge clk);
        if(received!=base) $fatal(1,"Bad CRC was acknowledged");
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==1) $fatal(1,"Rejected command changed mode");
        request(8'h13,0,0,0);acknowledge(8'h13,0);
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==0) $fatal(1,"Shared mode not restored");
        request(2,0,0,0);acknowledge(2,0);
        if(replies[base+7]!=4) $fatal(1,"Protocol did not advertise character interface");
        request(8'h0c,0,0,0);acknowledge(8'h0c,8'ha5);
        if({replies[base+7],replies[base+6],replies[base+5],replies[base+4]}!==32'hc4a50102)$fatal(1,"Memory health query overwritten");
        request(8'h0d,0,0,0);acknowledge(8'h0d,8'h34);
        if({replies[base+7],replies[base+6],replies[base+5],replies[base+4]}!==32'h12345678)$fatal(1,"CRC query overwritten");
        request(8'h0e,0,0,0);acknowledge(8'h0e,8'h00);
        if({replies[base+7],replies[base+6],replies[base+5],replies[base+4]}!==32'hc5000900)$fatal(1,"Frame verification query overwritten");
        request(8'h20,0,2,0);acknowledge(8'h20,0);
        request(8'h21,0,16'h4f60,0);request(8'h21,1,16'h597d,0);
        request(8'h22,0,1,0);acknowledge(8'h22,0);
        if(!diagnostic[3]) $fatal(1,"Normal text not committed");
        request(8'h20,16'h0301,1,0);acknowledge(8'h20,0);
        request(8'h21,0,16'h5b89,0);request(8'h22,0,1,0);acknowledge(8'h22,0);
        request(1,0,0,0);acknowledge(1,0);
        if(!replies[base+7][6]) $fatal(1,"Urgent state not observable");
        request(8'h20,0,1,0);acknowledge(8'h20,2);
        request(8'h24,0,0,0);acknowledge(8'h24,0);
        if(interrupt_active || !diagnostic[3]) $fatal(1,"Cancel did not restore normal text");
        request(8'h20,0,2,0);acknowledge(8'h20,0);
        request(8'h21,1,16'h4f60,0);
        request(8'h22,0,1,0);acknowledge(8'h22,3);
        request(8'h20,0,1,0);acknowledge(8'h20,0);
        request(8'h21,0,16'hd800,0);
        request(8'h22,0,1,0);acknowledge(8'h22,5);
        request(8'h10,0,9,1);repeat(2000)@(negedge clk);
        if(key_count!=0 || received!=base) $fatal(1,"Bad CRC changed control state");
        request(8'h10,0,9,0);acknowledge(8'h10,0);
        if(key_count!=1) $fatal(1,"Valid key not forwarded once");
        request(8'h20,0,1,0);acknowledge(8'h20,0);
        repeat(11000)@(negedge clk);
        if(upload_active) $fatal(1,"Abandoned upload did not expire");
        suppress_done=1;
        request(8'h23,0,0,0);acknowledge(8'h23,4);
        suppress_done=0;
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==0 || replies[base+7]!==8'ha3) $fatal(1,"Default mode/capability bytes wrong");
        request(8'h13,0,1,0);acknowledge(8'h13,0);
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==1 || replies[base+7]!==8'ha3) $fatal(1,"Pair mode not acknowledged");
        request(8'h13,0,2,0);acknowledge(8'h13,1);
        request(8'h13,0,0,1);repeat(2000)@(negedge clk);
        if(received!=base) $fatal(1,"Bad CRC was acknowledged");
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==1) $fatal(1,"Rejected command changed mode");
        request(8'h13,0,0,0);acknowledge(8'h13,0);
        request(8'h0f,0,0,0);acknowledge(8'h0f,0);
        if(replies[base+4]!==0) $fatal(1,"Shared mode not restored");
        request(2,0,0,0);acknowledge(2,0);
        request(8'h23,0,0,0);acknowledge(8'h23,0);
        if(diagnostic[3]) $fatal(1,"Default carousel not restored");
        $display("AUDIO_MODE_PROTOCOL_PASS checks=%0d; real UART/CRC/order/length/urgent/timeout/control recovery",checks);$finish;
    end
    initial begin #10000000;$fatal(1,"UART test timeout");end
endmodule
