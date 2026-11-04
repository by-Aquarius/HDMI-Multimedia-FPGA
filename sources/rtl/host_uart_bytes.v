`timescale 1ns/1ps
// UART byte transport / 串口字节收发。50MHz, 115200, 8N1.
// RX start is checked at its midpoint; invalid stop bits never publish bytes.
module host_uart_bytes #(
    parameter integer BIT_CYCLES = 434
) (
    input wire clk,
    input wire rst_n,
    input wire serial_rx,
    output wire serial_tx,
    output reg [7:0] rx_data,
    output reg rx_valid,
    input wire [7:0] tx_data,
    input wire tx_valid,
    output wire tx_ready
);
    reg rx_meta, rx_sync;
    reg [1:0] rx_state;
    reg [15:0] rx_count;
    reg [2:0] rx_bit;
    reg [7:0] rx_shift;
    reg [15:0] tx_count;
    reg [3:0] tx_bit;
    reg [9:0] tx_shift;
    reg tx_busy;
    assign serial_tx = tx_busy ? tx_shift[0] : 1'b1;
    assign tx_ready = !tx_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_meta <= 1'b1; rx_sync <= 1'b1; end
        else begin rx_meta <= serial_rx; rx_sync <= rx_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= 0; rx_count <= 0; rx_bit <= 0;
            rx_shift <= 0; rx_data <= 0; rx_valid <= 0;
        end else begin
            rx_valid <= 0;
            case (rx_state)
                0: if (!rx_sync) begin rx_count <= BIT_CYCLES/2-1; rx_state <= 1; end
                1: if (rx_count != 0) rx_count <= rx_count-1'b1;
                   else if (!rx_sync) begin rx_count <= BIT_CYCLES-1; rx_bit <= 0; rx_state <= 2; end
                   else rx_state <= 0;
                2: if (rx_count != 0) rx_count <= rx_count-1'b1;
                   else begin
                       rx_shift[rx_bit] <= rx_sync; rx_count <= BIT_CYCLES-1;
                       if (rx_bit == 7) rx_state <= 3; else rx_bit <= rx_bit+1'b1;
                   end
                3: if (rx_count != 0) rx_count <= rx_count-1'b1;
                   else begin rx_state <= 0; if (rx_sync) begin rx_data <= rx_shift; rx_valid <= 1; end end
                default: rx_state <= 0;
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin tx_count <= 0; tx_bit <= 0; tx_shift <= 10'h3ff; tx_busy <= 0; end
        else if (!tx_busy) begin
            if (tx_valid) begin tx_shift <= {1'b1,tx_data,1'b0}; tx_count <= BIT_CYCLES-1; tx_bit <= 0; tx_busy <= 1; end
        end else if (tx_count != 0) tx_count <= tx_count-1'b1;
        else begin
            tx_count <= BIT_CYCLES-1; tx_shift <= {1'b1,tx_shift[9:1]};
            if (tx_bit == 9) tx_busy <= 0; else tx_bit <= tx_bit+1'b1;
        end
    end
endmodule
