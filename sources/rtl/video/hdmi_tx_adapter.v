// -----------------------------------------------------------------------------
// hdmi_tx_adapter.v
// D06: RGB565 pixel interface adapter for the existing 1280x1024 HDMI TX.
//
// timing_hs/timing_vs/timing_de are supplied by the already-verified A03 timing
// path. They are not regenerated and their mode/frequency/polarity are not
// changed. The adapter delays the timing signals by one pxlclk so they align
// with the synchronous pixel response from video_prefetch.
//
// RGB565 expands to the 24-bit RGB bus consumed by A03 hdmi_tx. Invalid pixels
// and underflow display black. Underflow is exposed as a one-cycle event and a
// sticky status bit until reset. pixel_rd_en requests one pixel per active DE.
// -----------------------------------------------------------------------------
module hdmi_tx_adapter (
    input  wire        pxlclk,
    input  wire        rst_n,

    input  wire        timing_hs,
    input  wire        timing_vs,
    input  wire        timing_de,
    input  wire [11:0] timing_x,
    input  wire [11:0] timing_y,

    output wire        pixel_rd_en,
    input  wire        pixel_valid,
    input  wire [15:0] pixel_rgb565,
    input  wire        pixel_underflow,

    output reg         vga_hs,
    output reg         vga_vs,
    output reg         vga_de,
    output reg  [23:0] vga_rgb,
    output reg         underflow_latched,
    output reg         underflow_event
);

    wire [4:0] red5   = pixel_rgb565[15:11];
    wire [5:0] green6 = pixel_rgb565[10:5];
    wire [4:0] blue5  = pixel_rgb565[4:0];
    wire [23:0] expanded_rgb = {red5, red5[4:2],
                                green6, green6[5:4],
                                blue5, blue5[4:2]};
    wire active_pixel = timing_de && pixel_valid && !pixel_underflow;

    assign pixel_rd_en = timing_de;

    always @(posedge pxlclk or negedge rst_n) begin
        if (!rst_n) begin
            vga_hs           <= 1'b0;
            vga_vs           <= 1'b0;
            vga_de           <= 1'b0;
            vga_rgb          <= 24'h000000;
            underflow_latched <= 1'b0;
            underflow_event   <= 1'b0;
        end else begin
            // The presentation pipeline supplies RGB, DE, HS and VS aligned
            // at one register boundary. Delay the complete video stream by
            // one common pixel clock into the HDMI transmitter.
            vga_hs <= timing_hs;
            vga_vs <= timing_vs;
            vga_de <= timing_de;

            if (active_pixel)
                vga_rgb <= expanded_rgb;
            else
                vga_rgb <= 24'h000000;

            underflow_event <= 1'b0;
            if (pixel_underflow || (timing_de && !pixel_valid)) begin
                underflow_latched <= 1'b1;
                underflow_event   <= 1'b1;
            end
        end
    end
endmodule
