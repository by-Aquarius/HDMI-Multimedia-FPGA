`timescale 1ns/1ps
// Double-buffered subtitle / 双缓冲字幕。Only the inactive bank is writable.
// Payload is held until the pixel-domain frame-boundary acknowledgement.
module host_subtitle_plane (
    input wire ctrl_clk,
    input wire ctrl_rst_n,
    input wire write_valid,
    input wire [11:0] write_address,
    input wire [15:0] write_data,
    input wire [11:0] write_width,
    input wire commit,
    input wire hide,
    output wire ready,
    output reg commit_done,
    output reg scroll_done,
    input wire pixel_clk,
    input wire pixel_rst_n,
    input wire frame_boundary,
    input wire pixel_valid,
    input wire display_enable,
    input wire [11:0] pixel_x,
    input wire [11:0] pixel_y,
    output wire subtitle_enabled,
    output wire subtitle_alpha,
    output wire [15:0] subtitle_rgb
);
    reg request_toggle, request_show, ctrl_bank;
    reg ack_meta, ack_sync, ack_seen;
    reg req_meta, req_sync, req_settled, req_seen;
    reg show_meta, show_sync;
    reg visible, front_bank;
    reg [11:0] request_width, width_meta, width_sync;
    reg [11:0] scroll_period, scroll_offset;
    reg scroll_toggle;
    reg scroll_meta, scroll_sync, scroll_seen;
    reg [12:0] source_sum, text_end;
    reg [4:0] row_q;
    reg input_area_q;
    wire pixel_bit;
    reg area_q;
    reg [2:0] alpha_pipe, glyph_pipe;
    reg glyph_area_q;
    wire in_area = pixel_valid && visible && display_enable && pixel_x < 1280 && pixel_y >= 680 && pixel_y < 712;
    wire [12:0] source_x = source_sum - 13'd1280;
    wire [16:0] read_address = {front_bank,row_q,source_x[10:0]};
    assign ready = (ack_sync == request_toggle);
    assign subtitle_enabled = visible && display_enable;
    assign subtitle_alpha = alpha_pipe[2];
    assign subtitle_rgb = glyph_pipe[2] ? 16'hffe0 : 16'h0864;
    // The producer and bank/ready state update on the positive edge. Capture the
    // complete write bundle halfway through the cycle, retaining the same RAM write edge.
    reg ram_write_enable_stage;
    reg [12:0] ram_write_address_stage;
    reg [15:0] ram_write_data_stage;
    always @(negedge ctrl_clk) begin
        if(!ctrl_rst_n)begin ram_write_enable_stage<=0;ram_write_address_stage<=0;ram_write_data_stage<=0;end
        else begin
            ram_write_enable_stage<=write_valid&&ready;
            ram_write_address_stage<={!ctrl_bank,write_address};
            ram_write_data_stage<=write_data;
        end
    end
    // Asymmetric ports remove the post-RAM sixteen-bit pixel selector.
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16),.ADDR_WIDTH_A(13),.DATA_DEPTH_A(8192),
        .DATA_WIDTH_B(1),.ADDR_WIDTH_B(17),.DATA_DEPTH_B(131072),
        .MODE("PDPW"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .IMPLEMENT("9K"),.FILL_ALL("NONE")
    ) u_subtitle_ram (
        .dia(ram_write_data_stage),.dib(1'b0),.addra(ram_write_address_stage),.addrb(read_address),
        .cea(ram_write_enable_stage && ctrl_rst_n),.ceb(1'b1),.ocea(1'b0),.oceb(1'b0),
        .clka(ctrl_clk),.clkb(pixel_clk),.wea(ram_write_enable_stage && ctrl_rst_n),.web(1'b0),
        .bea(1'b1),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(pixel_bit)
    );
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            request_toggle <= 0; request_show <= 0; ctrl_bank <= 0; request_width <= 1024;
            ack_meta <= 0; ack_sync <= 0; ack_seen <= 0; commit_done <= 0;
            scroll_meta <= 0; scroll_sync <= 0; scroll_seen <= 0; scroll_done <= 0;
        end else begin
            ack_meta <= req_seen; ack_sync <= ack_meta; commit_done <= 0;
            scroll_meta <= scroll_toggle; scroll_sync <= scroll_meta; scroll_done <= 0;
            if (scroll_sync != scroll_seen) begin scroll_seen <= scroll_sync; scroll_done <= 1; end
            if (ack_sync != ack_seen) begin ack_seen <= ack_sync; commit_done <= 1; end
            if (ready && (commit || hide)) begin
                request_show <= commit;
                if (commit) begin ctrl_bank <= !ctrl_bank; request_width <= write_width; end
                request_toggle <= !request_toggle;
            end
        end
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            req_meta <= 0; req_sync <= 0; req_settled <= 0; req_seen <= 0;
            show_meta <= 0; show_sync <= 0; visible <= 0; front_bank <= 0;
            width_meta <= 1024; width_sync <= 1024;
            scroll_period <= 2368; scroll_offset <= 0; scroll_toggle <= 0; text_end <= 2304;
            source_sum <= 0; row_q <= 0; input_area_q <= 0; glyph_area_q <= 0;
            area_q <= 0; alpha_pipe <= 0; glyph_pipe <= 0;
        end else begin
            req_meta <= request_toggle; req_sync <= req_meta; req_settled <= req_sync;
            show_meta <= request_show; show_sync <= show_meta;
            width_meta <= request_width; width_sync <= width_meta;
            if (frame_boundary && req_settled != req_seen) begin
                req_seen <= req_settled; visible <= show_sync;
                scroll_offset <= 0;
                if (show_sync) begin
                    front_bank <= !front_bank;
                    text_end <= {1'b0,width_sync} + 13'd1280;
                    scroll_period <= width_sync + 12'd1344;
                end
            end else if (frame_boundary && visible && display_enable) begin
                if (scroll_offset >= scroll_period - 12'd4) begin
                    scroll_offset <= 0;
                    scroll_toggle <= !scroll_toggle;
                end else begin
                    scroll_offset <= scroll_offset + 12'd4;
                end
            end
            // Sum, wrapping/RAM lookup, glyph and two matching output stages.
            source_sum <= {1'b0,pixel_x} + {1'b0,scroll_offset};
            row_q <= pixel_y - 12'd680; input_area_q <= in_area;
            area_q <= input_area_q;
            glyph_area_q <= source_sum >= 13'd1280 && source_sum < text_end;
            alpha_pipe <= {alpha_pipe[1:0],area_q};
            glyph_pipe <= {glyph_pipe[1:0],pixel_bit && glyph_area_q};
        end
    end
endmodule
