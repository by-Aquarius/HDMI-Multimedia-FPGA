`timescale 1ns / 1ps
// Fixed-font text compositor / 固定字库文字合成。
// Serial input contains character codes. Font lookup, doubling, placement,
// background clearing and frame-boundary presentation all execute in FPGA.
module subtitle_text_renderer #(
    parameter integer SECOND_CYCLES = 50000000
) (
    input wire clk,
    input wire rst_n,
    input wire text_begin,
    input wire upload_in_progress,
    input wire upload_urgent,
    input wire [6:0] upload_length,
    input wire [7:0] upload_seconds,
    input wire text_write,
    input wire [5:0] text_address,
    input wire [15:0] text_code,
    input wire text_commit,
    input wire restore_default,
    input wire cancel_urgent,
    output wire ready,
    output wire done,
    output wire [7:0] result,
    output wire interrupt_active,
    output wire [31:0] diagnostic,
    input wire bitmap_ready,
    input wire bitmap_done,
    input wire bitmap_scroll_done,
    output wire bitmap_write,
    output wire [11:0] bitmap_address,
    output wire [15:0] bitmap_data,
    output wire [11:0] bitmap_width,
    output wire bitmap_commit
);
    localparam [3:0] IDLE=0, CLEAR=1, CHARACTER=2, LOOK_WAIT=3,
        LOOK_COMPARE=4, ROW_WAIT=5, ROW_WRITE=6, COMMIT=7, ACK=8, FETCH_WAIT=9;
    reg [3:0] state_q, state_d;
    reg [15:0] text_memory [0:191];
    wire [15:0] dictionary_q, font_row_q;
    wire [15:0] builtin_code;
    reg [14:0] font_address_q;
    reg [10:0] middle_q;
    reg [11:0] low_q, high_q;
    reg [15:0] character_q;
    reg [11:0] clear_address_q;
    reg [5:0] character_index_q;
    reg [3:0] row_q;
    reg half_q, repeat_q;
    reg normal_bank_q, custom_valid_q, upload_urgent_q;
    reg [6:0] upload_length_q, normal_length_q, length_q;
    reg [7:0] upload_seconds_q, remaining_q;
    reg [1:0] source_q, render_bank_q, builtin_q;
    reg [31:0] second_count_q;
    reg initial_pending_q, return_pending_q;
    reg interrupt_q;
    reg done_q;
    reg [7:0] result_q;
    reg bitmap_write_q, bitmap_commit_q;
    reg [11:0] bitmap_address_q, bitmap_width_q;
    reg [15:0] bitmap_data_q;
    reg [15:0] missing_code_q;
    wire second_tick = second_count_q == SECOND_CYCLES-1;
    wire found = dictionary_q == character_q;
    wire exhausted = low_q > high_q ||
        (character_q < dictionary_q && middle_q == 0) ||
        (character_q > dictionary_q && middle_q == 2047);
    wire [12:0] lower_middle_sum = {1'b0,low_q} + {2'd0,middle_q} - 13'd1;
    wire [12:0] upper_middle_sum = {1'b0,high_q} + {2'd0,middle_q} + 13'd1;
    wire [31:0] expanded_row;
    wire [7:0] text_read_address = {render_bank_q,character_index_q};
    genvar column;
    generate for(column=0;column<16;column=column+1) begin: g_double_columns
        assign expanded_row[column*2 +: 2] = {2{font_row_q[15-column]}};
    end endgenerate
    fixed_subtitle_font u_fixed_font (
        .clk(clk), .code_address(middle_q), .glyph_address(font_address_q),
        .builtin_address({builtin_q,character_index_q}),
        .code_data(dictionary_q), .glyph_data(font_row_q), .builtin_data(builtin_code)
    );
    // Private host inputs and bank/ready are POS registers; retain the POS write edge.
    reg text_write_stage;
    reg [7:0] text_address_stage;
    reg [15:0] text_code_stage;
    always @(negedge clk) begin
        if (!rst_n) begin text_write_stage<=0; text_address_stage<=0; text_code_stage<=0; end
        else begin
            text_write_stage<=text_write && ready;
            text_address_stage<={upload_urgent_q ? 2'd2 : {1'b0,!normal_bank_q},text_address};
            text_code_stage<=text_code;
        end
    end
    always @(posedge clk) begin
        if (rst_n && text_write_stage) text_memory[text_address_stage] <= text_code_stage;
    end
    assign ready = state_q == IDLE && bitmap_ready && (!initial_pending_q || upload_in_progress) && !return_pending_q;
    assign done = done_q;
    assign result = result_q;
    assign interrupt_active = interrupt_q;
    assign diagnostic = {missing_code_q,remaining_q,source_q,builtin_q,custom_valid_q,interrupt_q,2'd0};
    assign bitmap_write = bitmap_write_q;
    assign bitmap_address = bitmap_address_q;
    assign bitmap_data = bitmap_data_q;
    assign bitmap_width = bitmap_width_q;
    assign bitmap_commit = bitmap_commit_q;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) state_q <= IDLE;
        else state_q <= state_d;
    end
    always @(*) begin
        state_d = state_q;
        case(state_q)
            IDLE: if(bitmap_ready && ((initial_pending_q && !upload_in_progress) || return_pending_q ||
                       text_commit || restore_default || cancel_urgent)) state_d = CLEAR;
            CLEAR: if(clear_address_q == 4095) state_d = FETCH_WAIT;
            FETCH_WAIT: state_d = CHARACTER;
            CHARACTER: state_d = LOOK_WAIT;
            LOOK_WAIT: state_d = LOOK_COMPARE;
            LOOK_COMPARE: if(found) state_d = ROW_WAIT;
                          else if(exhausted) state_d = IDLE;
                          else state_d = LOOK_WAIT;
            ROW_WAIT: state_d = ROW_WRITE;
            ROW_WRITE: if(half_q && repeat_q) begin
                if(row_q != 15) state_d = ROW_WAIT;
                else if({1'b0,character_index_q} + 7'd1 < length_q) state_d = FETCH_WAIT;
                else state_d = COMMIT;
            end
            COMMIT: state_d = ACK;
            ACK: if(bitmap_done) state_d = IDLE;
            default: state_d = IDLE;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            middle_q<=0;low_q<=0;high_q<=2047;character_q<=0;font_address_q<=0;
            clear_address_q<=0;character_index_q<=0;row_q<=0;half_q<=0;repeat_q<=0;
            normal_bank_q<=0;custom_valid_q<=0;upload_urgent_q<=0;
            upload_length_q<=1;normal_length_q<=1;length_q<=17;
            upload_seconds_q<=10;remaining_q<=0;source_q<=0;render_bank_q<=0;builtin_q<=0;
            second_count_q<=0;initial_pending_q<=1;return_pending_q<=0;
            interrupt_q<=0;done_q<=0;result_q<=0;missing_code_q<=0;
            bitmap_write_q<=0;bitmap_commit_q<=0;bitmap_address_q<=0;bitmap_data_q<=0;bitmap_width_q<=544;
        end else begin
            done_q<=0;bitmap_write_q<=0;bitmap_commit_q<=0;
            if(second_tick) begin
                second_count_q<=0;
                if(interrupt_q && remaining_q != 0) begin
                    remaining_q<=remaining_q-1'b1;
                    if(remaining_q==1) return_pending_q<=1;
                end
            end else second_count_q<=second_count_q+1'b1;
            // A new builtin sentence starts only after the whole previous pass.
            if(bitmap_scroll_done && !custom_valid_q && !interrupt_q &&
               !upload_in_progress && state_q==IDLE) begin
                builtin_q<=builtin_q+1'b1;initial_pending_q<=1;
            end
            if(text_begin && ready) begin
                upload_urgent_q<=upload_urgent;
                upload_length_q<=upload_length;
                upload_seconds_q<=upload_seconds;
            end
            case(state_q)
                IDLE: if(state_d==CLEAR) begin
                    clear_address_q<=0;character_index_q<=0;result_q<=0;
                    if(text_commit) begin
                        source_q<=upload_urgent_q ? 2'd2 : 2'd1;
                        render_bank_q<=upload_urgent_q ? 2'd2 : {1'b0,!normal_bank_q};
                        length_q<=upload_length_q;
                        bitmap_width_q<={upload_length_q,5'd0};
                        if(upload_urgent_q) begin interrupt_q<=1;remaining_q<=0;end
                    end else begin
                        source_q<=restore_default ? 2'd0 : (custom_valid_q ? 2'd1 : 2'd0);
                        render_bank_q<={1'b0,normal_bank_q};
                        if(restore_default) custom_valid_q<=0;
                        if(custom_valid_q && !restore_default) begin
                            length_q<=normal_length_q;bitmap_width_q<={normal_length_q,5'd0};
                        end else begin
                            case(builtin_q)
                                0:begin length_q<=17;bitmap_width_q<=544;end
                                1:begin length_q<=15;bitmap_width_q<=480;end
                                2:begin length_q<=14;bitmap_width_q<=448;end
                                default:begin length_q<=15;bitmap_width_q<=480;end
                            endcase
                        end
                    end
                    initial_pending_q<=0;return_pending_q<=0;
                end
                CLEAR: begin
                    bitmap_write_q<=1;bitmap_address_q<=clear_address_q;bitmap_data_q<=0;
                    clear_address_q<=clear_address_q+1'b1;
                end
                CHARACTER: begin
                    character_q<=source_q==0 ? builtin_code : text_memory[text_read_address];
                    low_q<=0;high_q<=2047;middle_q<=1023;row_q<=0;half_q<=0;repeat_q<=0;
                end
                LOOK_COMPARE: begin
                    if(found) font_address_q<={middle_q,4'd0};
                    else if(exhausted) begin
                        result_q<=5;missing_code_q<=character_q;done_q<=1;
                        // A failed background render never commits a partial frame.
                        if(source_q==2) begin interrupt_q<=0;remaining_q<=0;end
                    end else if(character_q < dictionary_q) begin
                        high_q<={1'b0,middle_q}-1'b1;middle_q<=lower_middle_sum[11:1];
                    end else begin
                        low_q<={1'b0,middle_q}+1'b1;middle_q<=upper_middle_sum[11:1];
                    end
                end
                ROW_WRITE: begin
                    bitmap_write_q<=1;bitmap_address_q<={row_q,repeat_q,character_index_q,half_q};
                    bitmap_data_q<=half_q ? expanded_row[31:16] : expanded_row[15:0];
                    half_q<=!half_q;
                    if(half_q) begin
                        repeat_q<=!repeat_q;
                        if(repeat_q) begin
                            row_q<=row_q+1'b1;
                            if(row_q != 15) font_address_q<=font_address_q+1'b1;
                            else character_index_q<=character_index_q+1'b1;
                        end
                    end
                end
                COMMIT: bitmap_commit_q<=1;
                ACK: if(bitmap_done) begin
                    done_q<=1;second_count_q<=0;
                    if(source_q==2) remaining_q<=upload_seconds_q;
                    else begin
                        interrupt_q<=0;remaining_q<=0;
                        if(source_q==1) begin
                            normal_bank_q<=render_bank_q[0];normal_length_q<=length_q;custom_valid_q<=1;
                        end
                    end
                end
                default: begin end
            endcase
        end
    end
endmodule
