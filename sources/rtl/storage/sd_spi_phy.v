// -----------------------------------------------------------------------------
// sd_spi_phy.v
// C01 read-only SPI byte engine for the hardwood-classroom EG4S20 board.
//
// SPI mode 0:
//   * SD clock idles LOW;
//   * MOSI changes on the falling edge;
//   * MISO is sampled on the rising edge;
//   * bytes are transferred MSB first.
//
// The higher layer may hold cs_active high across several byte transfers.
// tx_valid/tx_data starts one byte when tx_ready is high. rx_valid pulses for
// one clk_50m cycle when rx_data is available.
// -----------------------------------------------------------------------------
module sd_spi_phy #(
    parameter integer CLK_DIV = 2,
    parameter integer RETRY_CLK_DIV = CLK_DIV
) (
    input  wire       clk_50m,
    input  wire       rst_n,
    input  wire       cs_active,
    input  wire       cs_force_high,
    input  wire       slow_mode,
    input  wire       tx_valid,
    input  wire [7:0] tx_data,
    output wire       tx_ready,
    output reg        rx_valid,
    output reg  [7:0] rx_data,
    output reg        busy,
    output reg        sd_clk,
    output reg        sd_mosi,
    input  wire       sd_miso,
    output wire       sd_cs_n
);

    localparam integer DIV_MAX = CLK_DIV > RETRY_CLK_DIV ? CLK_DIV : RETRY_CLK_DIV;
    localparam integer DIV_BITS = DIV_MAX <= 2 ? 1 : $clog2(DIV_MAX);
    reg [DIV_BITS-1:0] div_count;
    wire divider_done = slow_mode ? (div_count >= RETRY_CLK_DIV-1) : (div_count >= CLK_DIV-1);
    reg [7:0]  tx_shift;
    reg [7:0]  rx_shift;
    reg [2:0]  bit_index;

    assign tx_ready = !busy;
    // cs_active keeps the card selected between byte transfers. A transfer
    // also asserts CS automatically, so a one-byte client need not manage it.
    assign sd_cs_n  = cs_force_high ? 1'b1 : !(cs_active || busy);

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            div_count <= {DIV_BITS{1'b0}};
            tx_shift  <= 8'h00;
            rx_shift  <= 8'h00;
            bit_index <= 3'd0;
            rx_valid  <= 1'b0;
            rx_data   <= 8'h00;
            busy      <= 1'b0;
            sd_clk    <= 1'b0;
            sd_mosi   <= 1'b1;
        end else begin
            rx_valid <= 1'b0;

            if (!busy) begin
                div_count <= {DIV_BITS{1'b0}};
                sd_clk    <= 1'b0;
                sd_mosi   <= 1'b1;

                if (tx_valid) begin
                    busy      <= 1'b1;
                    tx_shift  <= tx_data;
                    rx_shift  <= 8'h00;
                    bit_index <= 3'd7;
                    sd_mosi   <= tx_data[7];
                end
            end else if (divider_done) begin
                div_count <= {DIV_BITS{1'b0}};

                if (sd_clk == 1'b0) begin
                    // Rising edge: sample the card's MISO bit.
                    sd_clk            <= 1'b1;
                    rx_shift[bit_index] <= sd_miso;
                end else begin
                    // Falling edge: advance MOSI or finish the byte.
                    sd_clk <= 1'b0;
                    if (bit_index == 3'd0) begin
                        busy    <= 1'b0;
                        rx_data <= rx_shift;
                        rx_valid <= 1'b1;
                        sd_mosi <= 1'b1;
                    end else begin
                        bit_index <= bit_index - 1'b1;
                        sd_mosi   <= tx_shift[bit_index - 1'b1];
                    end
                end
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end

endmodule
