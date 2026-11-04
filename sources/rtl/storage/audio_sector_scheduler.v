`timescale 1ns / 1ps
// Sector scheduling / 扇区调度。Ownership never changes within a sector.
module audio_sector_scheduler (
    input wire clk,
    input wire rst_n,
    input wire owner_free,
    input wire request_accepted,
    input wire boot_request,
    input wire scan_request,
    input wire image_request,
    input wire audio_request,
    input wire audio_active,
    input wire audio_metadata,
    input wire [11:0] audio_fill,
    output wire choose_image,
    output wire choose_audio,
    output wire urgent,
    output wire [15:0] audio_grants,
    output wire [15:0] image_grants
);
    reg refill_q;
    reg [15:0] audio_grants_q;
    reg [15:0] image_grants_q;
    wire available = owner_free && !boot_request && !scan_request;
    assign urgent = (audio_request && audio_metadata) ||
                    (audio_active && (refill_q || audio_fill < 12'd768));
    assign choose_audio = available && audio_request && (!image_request || urgent);
    assign choose_image = available && image_request && !choose_audio;
    assign audio_grants = audio_grants_q;
    assign image_grants = image_grants_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refill_q <= 0;
            audio_grants_q <= 0;
            image_grants_q <= 0;
        end else begin
            if (!audio_active || audio_fill >= 12'd1536) refill_q <= 0;
            else if (audio_fill < 12'd768) refill_q <= 1;
            if (request_accepted && choose_audio && audio_grants_q != 16'hffff)
                audio_grants_q <= audio_grants_q + 1'b1;
            if (request_accepted && choose_image && image_grants_q != 16'hffff)
                image_grants_q <= image_grants_q + 1'b1;
        end
    end
endmodule
