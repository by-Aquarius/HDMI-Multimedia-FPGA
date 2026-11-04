// -----------------------------------------------------------------------------
// playlist_ctrl.v
// E02: media index loop and slideshow timer controlled by B04 speed_level.
//
// The controller only requests a load; E01 owns the actual LOAD/SWAP/TRANSITION
// sequence and active_index. index_commit restarts the interval for the newly
// displayed image. A speed change affects the next interval because timer_ms
// latches its period on restart.
// -----------------------------------------------------------------------------
module playlist_ctrl #(
    parameter integer CLK_HZ = 50000000,
    parameter integer TICK_HZ = 1000
) (
    input  wire        clk,
    input  wire        rst_n,

    // C05 media context.
    input  wire        media_ready,
    input  wire [4:0]  media_count,

    // B04 speed level: 0=10s, 1=8s, 2=6s, 3=4s, 4=2s, 5=1s.
    input  wire [2:0]  speed_level,

    // E01 playback status and index.
    input  wire [4:0]  active_index,
    input  wire        index_commit,
    input  wire        playing,
    input  wire        paused,
    input  wire        e01_busy,
    input  wire        e01_error,

    // E01 explicit load request.
    output reg         load_request,
    output reg  [4:0]  load_request_index,
    output reg         wrap_event,

    // Diagnostics/OSD.
    output wire [4:0]  next_index,
    output wire [31:0] period_ms,
    output wire [31:0] elapsed_ms,
    output wire        timer_busy
);

    reg  [31:0] period_ms_reg;
    reg         timer_restart;
    reg         error_seen;
    wire        timer_done;
    wire [5:0]  next_index_wide;
    wire        timer_enable;

    assign next_index_wide = {1'b0, active_index} + 6'd1;
    assign next_index = (next_index_wide >= {1'b0, media_count}) ?
                        5'd0 : next_index_wide[4:0];
    assign period_ms = period_ms_reg;
    assign timer_enable = playing && !paused && !e01_busy && !e01_error &&
                          media_ready && (media_count != 5'd0);

    always @(*) begin
        case (speed_level)
            3'd0: period_ms_reg = 32'd10000;
            3'd1: period_ms_reg = 32'd8000;
            3'd2: period_ms_reg = 32'd6000;
            3'd3: period_ms_reg = 32'd4000;
            3'd4: period_ms_reg = 32'd2000;
            3'd5: period_ms_reg = 32'd1000;
            default: period_ms_reg = 32'd6000;
        endcase
    end

    timer_ms #(
        .CLK_HZ(CLK_HZ),
        .TICK_HZ(TICK_HZ)
    ) u_timer (
        .clk(clk), .rst_n(rst_n),
        .enable(timer_enable), .restart(timer_restart),
        .period_ms(period_ms_reg),
        .busy(timer_busy), .done(timer_done), .elapsed_ms(elapsed_ms)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_request       <= 1'b0;
            load_request_index <= 5'd0;
            wrap_event         <= 1'b0;
            timer_restart      <= 1'b0;
            error_seen         <= 1'b0;
        end else begin
            load_request  <= 1'b0;
            wrap_event    <= 1'b0;
            timer_restart <= 1'b0;
            error_seen    <= e01_error;

            if (index_commit) begin
                // A displayed index starts a fresh interval. Speed changes
                // after this point are sampled at the next commit.
                timer_restart <= 1'b1;
            end else if (error_seen && !e01_error) begin
                // A failed LOAD never reaches index_commit. Restart the
                // one-shot timer on ERROR release so autoplay can resume
                // after E01 returns to a stable state.
                timer_restart <= 1'b1;
            end else if (timer_done && timer_enable) begin
                load_request       <= 1'b1;
                load_request_index <= next_index;
                wrap_event         <= (next_index == 5'd0);
            end
        end
    end

endmodule
