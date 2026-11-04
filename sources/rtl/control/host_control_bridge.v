`timescale 1ns/1ps
// Host control bridge / 上位机控制桥。CRC checked commands share physical keys.
// Character codes are checked in sequence; the FPGA owns glyph composition.
module host_control_bridge #(
    parameter integer BIT_CYCLES = 434,
    parameter integer FRAME_TIMEOUT = 500000,
    parameter integer VOLUME_STEP_CYCLES = 50000,
    parameter integer COMMIT_TIMEOUT_CYCLES = 50000000,
    parameter integer UPLOAD_TIMEOUT_CYCLES = 250000000
) (
    input wire clk,
    input wire rst_n,
    input wire serial_rx,
    output wire serial_tx,
    input wire [4:0] active_index,
    input wire [4:0] media_count,
    input wire [2:0] playback_state,
    input wire [4:0] volume_level,
    input wire [7:0] brightness,
    input wire [2:0] speed_level,
    input wire [7:0] error_code,
    input wire [7:0] status_flags,
    input wire [31:0] fault_snapshot,
    input wire [31:0] live_snapshot,
    input wire [31:0] audio_snapshot,
    input wire [31:0] load_snapshot,
    output reg [15:0] key_pulse,
    output reg [2:0] audio_diagnostic_mode,
    input wire text_ready,
    input wire text_done,
    input wire [7:0] text_result,
    input wire [31:0] recovery_snapshot,
    input wire [31:0] scheduler_snapshot,
    input wire [31:0] subtitle_snapshot,
    input wire [31:0] prompt_snapshot,
    input wire [31:0] audio_health_snapshot,
    input wire [31:0] memory_health_snapshot,memory_crc_snapshot,
    input wire [31:0] memory_pass_snapshot,
    output reg audio_pair_mode,
    output wire upload_in_progress,
    output reg text_begin,
    output reg text_urgent,
    output reg [7:0] text_seconds,
    output reg [6:0] text_length,
    output reg text_write,
    output reg [5:0] text_address,
    output reg [15:0] text_code,
    output reg text_commit,
    output reg restore_default,
    output reg cancel_urgent
);
    wire [7:0] rx_data;
    wire rx_valid, tx_ready;
    wire tx_valid;
    wire [7:0] tx_data;
    host_uart_bytes #(.BIT_CYCLES(BIT_CYCLES)) u_uart (
        .clk(clk),.rst_n(rst_n),.serial_rx(serial_rx),.serial_tx(serial_tx),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_ready(tx_ready),.tx_valid(tx_valid),.tx_data(tx_data)
    );
    function [15:0] crc_byte;
        input [15:0] prior;
        input [7:0] value;
        integer bit_index;
        reg [15:0] work;
        begin
            work = prior ^ {value,8'd0};
            for (bit_index=0;bit_index<8;bit_index=bit_index+1)
                work = {work[14:0],1'b0} ^ (work[15] ? 16'h1021 : 16'd0);
            crc_byte = work;
        end
    endfunction
    reg [3:0] rx_position;
    reg [15:0] rx_crc;
    reg [7:0] crc_low, command, sequence_id;
    reg [15:0] address, argument;
    reg [19:0] idle_count;
    reg upload_active, upload_bad;
    reg [6:0] words_received;
    reg [28:0] upload_idle;
    reg [25:0] commit_wait;
    assign upload_in_progress = upload_active;
    reg wait_commit;
    reg [7:0] commit_sequence, commit_command;
    reg volume_pending;
    reg [4:0] volume_target;
    reg [23:0] volume_delay;
    // Keep the text-address capture logically unchanged while adding a short
    // fixed hold margin to address bit3 in the packed register path.
    wire text_address_hold_n_3 /* synthesis keep=true */;
    wire text_address_hold_3 /* synthesis keep=true */;
    assign text_address_hold_n_3 = ~address[3];
    assign text_address_hold_3 = ~text_address_hold_n_3;
    wire [5:0] text_address_capture = {
        address[5:4], text_address_hold_3, address[2:0]
    };
    reg [79:0] tx_packet;
    reg [47:0] reply_body;
    // Whole reply body is stable from the preceding POS producer through NEG.
    reg [47:0] reply_body_stage;
    always @(negedge clk) begin
        if (!rst_n) reply_body_stage <= 0;
        else reply_body_stage <= reply_body;
    end
    reg [15:0] reply_crc;
    reg [3:0] reply_phase, tx_position;
    reg tx_active;
    reg [7:0] ack_result;
    wire reply_idle = reply_phase == 0 && !tx_active;
    assign tx_valid = tx_active;
    assign tx_data = tx_packet[tx_position*8 +: 8];

    // Reply preparation computes one CRC byte per cycle, rather than a long combinational chain.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_position<=0;rx_crc<=16'hffff;crc_low<=0;command<=0;sequence_id<=0;address<=0;argument<=0;idle_count<=0;
            upload_active<=0;upload_bad<=0;words_received<=0;wait_commit<=0;commit_sequence<=0;commit_command<=0;
            audio_diagnostic_mode<=3'd6;audio_pair_mode<=1'b0;volume_pending<=0;volume_target<=8;volume_delay<=0;key_pulse<=0;
            text_begin<=0;text_urgent<=0;text_seconds<=10;text_length<=1;text_write<=0;text_address<=0;text_code<=0;text_commit<=0;restore_default<=0;cancel_urgent<=0;upload_idle<=0;commit_wait<=0;
            tx_packet<=0;reply_body<=0;reply_crc<=16'hffff;reply_phase<=0;tx_position<=0;tx_active<=0;ack_result<=0;
        end else begin
            key_pulse<=0;text_begin<=0;text_write<=0;text_commit<=0;restore_default<=0;cancel_urgent<=0;
            if(upload_active) begin
                if(upload_idle >= UPLOAD_TIMEOUT_CYCLES-1) begin upload_active<=0;upload_bad<=1;upload_idle<=0;end
                else upload_idle<=upload_idle+1'b1;
            end else upload_idle<=0;
            if(wait_commit) commit_wait<=commit_wait+1'b1;
            else commit_wait<=0;
            if (volume_pending) begin
                if (volume_delay != 0) volume_delay<=volume_delay-1'b1;
                else if (volume_level==volume_target) volume_pending<=0;
                else begin
                    key_pulse[volume_level<volume_target ? 5 : 4]<=1;
                    volume_delay<=VOLUME_STEP_CYCLES;
                end
            end
            if (reply_phase != 0) begin
                if (reply_phase<=6) begin
                    reply_crc<=crc_byte(reply_crc,reply_body_stage[(reply_phase-1)*8 +: 8]);
                    reply_phase<=reply_phase+1'b1;
                end else begin
                    tx_packet<={reply_crc,reply_body_stage,16'h5aa5};
                    tx_position<=0;tx_active<=1;reply_phase<=0;
                end
            end
            if (tx_active && tx_ready) begin
                if (tx_position==9) tx_active<=0;
                else tx_position<=tx_position+1'b1;
            end
            if (wait_commit && (text_done || commit_wait >= COMMIT_TIMEOUT_CYCLES-1) && reply_idle) begin
                wait_commit<=0;
                reply_body<={8'd0,(text_done ? text_result : 8'd4),16'd0,commit_sequence,commit_command|8'h80};
                reply_crc<=16'hffff;reply_phase<=1;
            end
            if (rx_position!=0 && !rx_valid) begin
                if (idle_count==FRAME_TIMEOUT-1) begin rx_position<=0;idle_count<=0;end
                else idle_count<=idle_count+1'b1;
            end
            if (rx_valid) begin
                idle_count<=0;
                case (rx_position)
                    0: if (rx_data==8'ha5) rx_position<=1;
                    1: if (rx_data==8'h5a) begin rx_position<=2;rx_crc<=16'hffff;end
                       else rx_position<=rx_data==8'ha5 ? 1 : 0;
                    2: begin command<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);rx_position<=3;end
                    3: begin sequence_id<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);rx_position<=4;end
                    4: begin address[7:0]<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);rx_position<=5;end
                    5: begin address[15:8]<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);rx_position<=6;end
                    6: begin argument[7:0]<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);rx_position<=7;end
                    7: begin argument[15:8]<=rx_data;rx_crc<=crc_byte(rx_crc,rx_data);rx_position<=8;end
                    8: begin crc_low<=rx_data;rx_position<=9;end
                    9: begin
                        rx_position<=0;
                        if ({rx_data,crc_low}==rx_crc) begin
                            if (command==8'h21) begin
                                if (upload_active && text_ready && !wait_commit && !upload_bad && address=={9'd0,words_received} && words_received<64) begin
                                    text_write<=1;text_address<=text_address_capture;text_code<=argument;words_received<=words_received+1'b1;upload_idle<=0;
                                end else upload_bad<=1;
                            end else if (reply_idle && !wait_commit) begin
                                ack_result=0;
                                case(command)
                                    8'h01: reply_body<={status_flags,{playback_state,volume_level},{3'd0,media_count},{3'd0,active_index},sequence_id,8'h81};
                                    8'h02: reply_body<={8'd4,error_code,{5'd0,speed_level},brightness,sequence_id,8'h82};
                                    8'h03: reply_body<={fault_snapshot,sequence_id,8'h83};
                                    8'h04: reply_body<={live_snapshot,sequence_id,8'h84};
                                    8'h05: reply_body<={audio_snapshot,sequence_id,8'h85};
                                    8'h06: reply_body<={load_snapshot,sequence_id,8'h86};
                                    8'h07: reply_body<={recovery_snapshot,sequence_id,8'h87};
                                    8'h08: reply_body<={scheduler_snapshot,sequence_id,8'h88};
                                    8'h09: reply_body<={subtitle_snapshot,sequence_id,8'h89};
                            8'h0a: begin reply_body<={prompt_snapshot,sequence_id,8'h8a}; reply_phase<=1; end
                            8'h0b: reply_body<={audio_health_snapshot,sequence_id,8'h8b};
                                    8'h0C: reply_body<={memory_health_snapshot,sequence_id,8'h8C};
                                    8'h0D: reply_body<={memory_crc_snapshot,sequence_id,8'h8D};
                                    8'h0E: reply_body<={memory_pass_snapshot,sequence_id,8'h8E};
                                    8'h0F: reply_body<={8'hA3,16'd0,{7'd0,audio_pair_mode},sequence_id,8'h8F};
                                    8'h10: if (argument<16) begin key_pulse<=16'h0001<<argument[3:0];if(argument==4 || argument==5)volume_pending<=0;end else ack_result=1;
                                    8'h11: if(argument<=10) begin volume_target<=argument[4:0];volume_pending<=1;volume_delay<=0;end else ack_result=1;
                                    8'h12: if(argument<8)audio_diagnostic_mode<=argument[2:0];else ack_result=1;
                                    8'h13: if(argument<=1)audio_pair_mode<=argument[0];else ack_result=1;
                                    8'h20: if(!text_ready || status_flags[6]) ack_result=2;
                                           else if(argument<1 || argument>64 || address[7:0]>1 ||
                                               (address[0] && (address[15:8]<1 || address[15:8]>120))) ack_result=1;
                                           else begin
                                               text_begin<=1;text_length<=argument[6:0];text_urgent<=address[0];
                                               text_seconds<=address[0] ? address[15:8] : 8'd10;
                                               upload_active<=1;upload_bad<=0;words_received<=0;upload_idle<=0;
                                           end
                                    8'h22: if(!text_ready)ack_result=2;
                                           else if(!upload_active || upload_bad || words_received!=text_length || argument!=1)ack_result=3;
                                           else begin text_commit<=1;upload_active<=0;wait_commit<=1;commit_sequence<=sequence_id;commit_command<=command;end
                                    8'h23,8'h24: if(!text_ready)ack_result=2;
                                           else begin
                                               restore_default<=command==8'h23;cancel_urgent<=command==8'h24;
                                               upload_active<=0;wait_commit<=1;commit_sequence<=sequence_id;commit_command<=command;
                                           end
                                    default: ack_result=1;
                                endcase
                                if((command<8'h01 || command>8'h0E) && command!=8'h0F) reply_body<={8'd0,ack_result,16'd0,sequence_id,command|8'h80};
                                if (!((command==8'h22 || command==8'h23 || command==8'h24) && ack_result==0)) begin reply_crc<=16'hffff;reply_phase<=1;end
                            end
                        end
                    end
                    default: rx_position<=0;
                endcase
            end
        end
    end
endmodule
