`timescale 1ns / 1ps
// Retained curtain request bridge / 保持到实际换帧确认的转场请求桥。
module curtain_request_bridge (
    input wire clk_ctrl,
    input wire rst_ctrl_n,
    input wire clk_pixel,
    input wire rst_pixel_n,
    input wire enable,
    input wire program_transaction,
    input wire swap_command_ctrl,
    input wire swap_ack_ctrl,
    input wire request_error_ctrl,
    input wire curtain_idle_pixel,
    input wire curtain_abort_pixel,
    input wire curtain_ready_pixel,
    output wire pending_ctrl,
    output wire ready_ctrl,
    output wire frame_swap_request_ctrl,
    output wire start_pixel,
    output wire frame_ready_pixel
);
    reg pending_q, grant_sent_q, ready_low_seen_q;
    reg ready_meta_ctrl, ready_sync_ctrl;
    reg pending_meta_pixel, pending_sync_pixel;
    reg accepted_pixel;
    wire bypass= !enable || program_transaction;
    wire grant=pending_q && !grant_sent_q && ready_low_seen_q && ready_sync_ctrl;
    assign pending_ctrl=pending_q;
    assign ready_ctrl=ready_sync_ctrl;
    assign frame_swap_request_ctrl=bypass ? swap_command_ctrl : grant;
    assign frame_ready_pixel=pending_sync_pixel;
    assign start_pixel=enable && pending_sync_pixel && !accepted_pixel &&
        curtain_idle_pixel && !curtain_abort_pixel;

    // Ready is a held level. A new transaction must first observe its low phase.
    always @(posedge clk_ctrl or negedge rst_ctrl_n) begin
        if(!rst_ctrl_n) begin
            ready_meta_ctrl<=0; ready_sync_ctrl<=0;
            pending_q<=0; grant_sent_q<=0; ready_low_seen_q<=0;
        end else begin
            ready_meta_ctrl<=curtain_ready_pixel;
            ready_sync_ctrl<=ready_meta_ctrl;
            if(bypass || request_error_ctrl) begin
                pending_q<=0; grant_sent_q<=0; ready_low_seen_q<=0;
            end else if(swap_command_ctrl) begin
                pending_q<=1; grant_sent_q<=0; ready_low_seen_q<=!ready_sync_ctrl;
            end else if(swap_ack_ctrl) begin
                pending_q<=0; grant_sent_q<=0; ready_low_seen_q<=0;
            end else if(pending_q) begin
                if(!ready_sync_ctrl) ready_low_seen_q<=1;
                if(grant) grant_sent_q<=1;
            end
        end
    end

    // Acceptance and curtain state use the same pixel clock/reset/abort priority.
    // A pending request survives an ignored start, an abort, or a pixel-only reset.
    always @(posedge clk_pixel or negedge rst_pixel_n) begin
        if(!rst_pixel_n) begin
            pending_meta_pixel<=0; pending_sync_pixel<=0; accepted_pixel<=0;
        end else begin
            pending_meta_pixel<=pending_q;
            pending_sync_pixel<=pending_meta_pixel;
            if(!pending_sync_pixel || curtain_abort_pixel || !enable) accepted_pixel<=0;
            else if(start_pixel) accepted_pixel<=1;
        end
    end
endmodule
