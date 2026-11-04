// -----------------------------------------------------------------------------
// sd_card_init.v
// C02: read-only SD-card SPI initialization state machine.
//
// Sequence:
//   1) >=80 idle SPI clocks with CS high;
//   2) CMD0 -> R1=01;
//   3) CMD8 -> R1=01, echo 00 00 01 AA;
//   4) CMD55 + ACMD41(HCS) until R1=00;
//   5) CMD58 -> R1=00, read OCR and require power-up bit set.
//
// This module owns the low-level SPI pins directly so it can provide the
// required CS-high power-up clocks. It has no sector, block, or card
// data-path operation. Only initialization/status commands are generated.
// -----------------------------------------------------------------------------
module sd_card_init #(
    parameter integer CLK_DIV                = 2,
    parameter integer IDLE_CLOCKS            = 80,
    parameter integer RESPONSE_TIMEOUT_BYTES = 32,
    parameter integer CMD_RETRIES            = 2,
    parameter integer ACMD41_RETRIES         = 8,
    parameter integer CS_GAP_CYCLES          = 2,
    parameter integer CS_GAP_CLOCKS          = 8,
    parameter integer ACMD41_N1_CLOCKS       = 8
) (
    input  wire       clk_50m,
    input  wire       rst_n,
    input  wire       sd_miso,
    output reg        sd_clk,
    output reg        sd_mosi,
    output wire       sd_cs_n,
    output reg        init_busy,
    output reg        init_done,
    output reg        sd_init_ok,
    output reg  [7:0] init_error,
    output reg [31:0] ocr_value,
    output reg        sd_high_capacity
);

    localparam [5:0] ST_IDLE       = 6'd0;
    localparam [5:0] ST_CMD0_SEND  = 6'd1;
    localparam [5:0] ST_CMD0_POLL  = 6'd2;
    localparam [5:0] ST_CMD8_SEND  = 6'd3;
    localparam [5:0] ST_CMD8_POLL  = 6'd4;
    localparam [5:0] ST_CMD8_EXTRA = 6'd5;
    localparam [5:0] ST_CMD55_SEND = 6'd6;
    localparam [5:0] ST_CMD55_POLL = 6'd7;
    localparam [5:0] ST_ACMD41_SEND = 6'd8;
    localparam [5:0] ST_ACMD41_POLL = 6'd9;
    localparam [5:0] ST_CMD58_SEND = 6'd10;
    localparam [5:0] ST_CMD58_POLL = 6'd11;
    localparam [5:0] ST_CMD58_EXTRA = 6'd12;
    localparam [5:0] ST_GAP        = 6'd13;
    localparam [5:0] ST_N1_IDLE    = 6'd16;
    localparam [5:0] ST_DONE        = 6'd14;
    localparam [5:0] ST_ERROR       = 6'd15;

    localparam [2:0] CMD_KIND_CMD0  = 3'd0;
    localparam [2:0] CMD_KIND_CMD8  = 3'd1;
    localparam [2:0] CMD_KIND_CMD55 = 3'd2;
    localparam [2:0] CMD_KIND_ACMD41 = 3'd3;
    localparam [2:0] CMD_KIND_CMD58 = 3'd4;

    // Stable error codes for upper layers and diagnostics.
    localparam [7:0] ERR_CMD0  = 8'h01;
    localparam [7:0] ERR_CMD8  = 8'h02;
    localparam [7:0] ERR_CMD8_ECHO = 8'h03;
    localparam [7:0] ERR_CMD55 = 8'h04;
    localparam [7:0] ERR_ACMD41 = 8'h05;
    localparam [7:0] ERR_CMD58 = 8'h06;
    localparam [7:0] ERR_OCR   = 8'h07;

    reg [5:0] state;
    reg [5:0] gap_target;
    reg [2:0] cmd_kind;
    reg [2:0] byte_index;
    reg [2:0] extra_index;
    reg       byte_issued;
    reg       spi_active;
    reg       spi_byte_done;
    reg [31:0] div_count;
    reg [31:0] idle_edges_left;
    reg [31:0] response_count;
    reg [31:0] retry_count;
    reg [31:0] acmd41_count;
    reg [31:0] gap_count;
    reg [31:0] gap_edges_left;
    reg [31:0] n1_edges;
    reg [7:0]  tx_shift;
    reg [7:0]  rx_shift;
    reg [2:0]  bit_index;
    reg [7:0]  rx_byte;
    reg [31:0] ocr_shift;
    wire [7:0] current_command_byte;

    assign current_command_byte = command_byte(cmd_kind, byte_index);

    assign sd_cs_n = (state == ST_IDLE || state == ST_GAP ||
                      state == ST_N1_IDLE ||
                      state == ST_DONE || state == ST_ERROR);

    always @* begin
        init_busy = !(state == ST_DONE || state == ST_ERROR);
    end

    function [7:0] command_byte;
        input [2:0] kind;
        input [2:0] index;
        begin
            command_byte = 8'hFF;
            case (kind)
                CMD_KIND_CMD0: begin
                    case (index)
                        3'd0: command_byte = 8'h40;
                        3'd5: command_byte = 8'h95;
                        default: command_byte = 8'h00;
                    endcase
                end
                CMD_KIND_CMD8: begin
                    case (index)
                        3'd0: command_byte = 8'h48;
                        3'd3: command_byte = 8'h01;
                        3'd4: command_byte = 8'hAA;
                        3'd5: command_byte = 8'h87;
                        default: command_byte = 8'h00;
                    endcase
                end
                CMD_KIND_CMD55: begin
                    if (index == 3'd0) command_byte = 8'h77;
                    else if (index == 3'd5) command_byte = 8'hFF;
                    else command_byte = 8'h00;
                end
                CMD_KIND_ACMD41: begin
                    case (index)
                        3'd0: command_byte = 8'h69;
                        3'd1: command_byte = 8'h40;
                        3'd5: command_byte = 8'hFF;
                        default: command_byte = 8'h00;
                    endcase
                end
                CMD_KIND_CMD58: begin
                    if (index == 3'd0) command_byte = 8'h7A;
                    else if (index == 3'd5) command_byte = 8'hFF;
                    else command_byte = 8'h00;
                end
                default: command_byte = 8'hFF;
            endcase
        end
    endfunction

    function [7:0] expected_cmd8_extra;
        input [2:0] index;
        begin
            case (index)
                3'd0: expected_cmd8_extra = 8'h00;
                3'd1: expected_cmd8_extra = 8'h00;
                3'd2: expected_cmd8_extra = 8'h01;
                default: expected_cmd8_extra = 8'hAA;
            endcase
        end
    endfunction

    task fail_init;
        input [7:0] code;
        begin
            init_error <= code;
            state      <= ST_ERROR;
            sd_init_ok <= 1'b0;
            init_done  <= 1'b0;
            spi_active <= 1'b0;
            byte_issued <= 1'b0;
            sd_clk     <= 1'b0;
            sd_mosi    <= 1'b1;
        end
    endtask

    task start_gap;
        input [5:0] next_state;
        begin
            gap_target     <= next_state;
            gap_count      <= 32'd0;
            gap_edges_left <= CS_GAP_CLOCKS * 2;
            div_count      <= 32'd0;
            state          <= ST_GAP;
            byte_issued    <= 1'b0;
            response_count <= 32'd0;
            spi_active     <= 1'b0;
            sd_clk         <= 1'b0;
            sd_mosi        <= 1'b1;
        end
    endtask

    task start_n1_idle;
        begin
            state          <= ST_N1_IDLE;
            div_count      <= 32'd0;
            n1_edges       <= ACMD41_N1_CLOCKS * 2;
            byte_issued    <= 1'b0;
            response_count <= 32'd0;
            spi_active     <= 1'b0;
            sd_clk         <= 1'b0;
            sd_mosi        <= 1'b1;
        end
    endtask

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            gap_target       <= ST_CMD0_SEND;
            cmd_kind         <= CMD_KIND_CMD0;
            byte_index       <= 3'd0;
            extra_index      <= 3'd0;
            byte_issued      <= 1'b0;
            spi_active       <= 1'b0;
            spi_byte_done    <= 1'b0;
            div_count        <= 32'd0;
            idle_edges_left  <= IDLE_CLOCKS * 2;
            response_count   <= 32'd0;
            retry_count      <= 32'd0;
            acmd41_count     <= 32'd0;
            gap_count        <= 32'd0;
            gap_edges_left   <= 32'd0;
            n1_edges         <= 32'd0;
            tx_shift         <= 8'h00;
            rx_shift         <= 8'h00;
            bit_index        <= 3'd0;
            rx_byte          <= 8'hFF;
            ocr_shift        <= 32'd0;
            ocr_value        <= 32'd0;
            sd_high_capacity <= 1'b0;
            init_done        <= 1'b0;
            sd_init_ok      <= 1'b0;
            init_error       <= 8'h00;
            sd_clk           <= 1'b0;
            sd_mosi          <= 1'b1;
        end else begin
            init_done     <= 1'b0;
            spi_byte_done <= 1'b0;

            if (spi_active) begin
                if ((CLK_DIV <= 1) || (div_count >= CLK_DIV - 1)) begin
                    div_count <= 32'd0;
                    if (sd_clk == 1'b0) begin
                        sd_clk <= 1'b1;
                        rx_shift[bit_index] <= sd_miso;
                    end else begin
                        sd_clk <= 1'b0;
                        if (bit_index == 3'd0) begin
                            spi_active    <= 1'b0;
                            spi_byte_done <= 1'b1;
                            rx_byte       <= rx_shift;
                            sd_mosi       <= 1'b1;
                        end else begin
                            bit_index <= bit_index - 1'b1;
                            sd_mosi   <= tx_shift[bit_index - 1'b1];
                        end
                    end
                end else begin
                    div_count <= div_count + 1'b1;
                end
            end else begin
                case (state)
                    ST_IDLE: begin
                        sd_clk  <= 1'b0;
                        sd_mosi <= 1'b1;
                        if ((IDLE_CLOCKS <= 0) || (idle_edges_left == 0)) begin
                            state          <= ST_CMD0_SEND;
                            cmd_kind       <= CMD_KIND_CMD0;
                            byte_index     <= 3'd0;
                            retry_count    <= 32'd0;
                            response_count <= 32'd0;
                            byte_issued    <= 1'b0;
                        end else if ((CLK_DIV <= 1) || (div_count >= CLK_DIV - 1)) begin
                            div_count       <= 32'd0;
                            sd_clk          <= ~sd_clk;
                            idle_edges_left <= idle_edges_left - 1'b1;
                        end else begin
                            div_count <= div_count + 1'b1;
                        end
                    end

                    ST_CMD0_SEND, ST_CMD8_SEND, ST_CMD55_SEND,
                    ST_ACMD41_SEND, ST_CMD58_SEND: begin
                        if (spi_byte_done) begin
                            byte_issued <= 1'b0;
                            if (byte_index == 3'd5) begin
                                response_count <= 32'd0;
                                byte_index     <= 3'd0;
                                case (state)
                                    ST_CMD0_SEND:   state <= ST_CMD0_POLL;
                                    ST_CMD8_SEND:   state <= ST_CMD8_POLL;
                                    ST_CMD55_SEND:  state <= ST_CMD55_POLL;
                                    ST_ACMD41_SEND: state <= ST_ACMD41_POLL;
                                    default:        state <= ST_CMD58_POLL;
                                endcase
                            end else begin
                                byte_index <= byte_index + 1'b1;
                            end
                        end else if (!byte_issued) begin
                            tx_shift    <= command_byte(cmd_kind, byte_index);
                            rx_shift    <= 8'h00;
                            bit_index   <= 3'd7;
                            sd_mosi     <= current_command_byte[7];
                            spi_active  <= 1'b1;
                            byte_issued <= 1'b1;
                        end
                    end

                    ST_CMD0_POLL, ST_CMD8_POLL, ST_CMD55_POLL,
                    ST_ACMD41_POLL, ST_CMD58_POLL: begin
                        if (spi_byte_done) begin
                            byte_issued <= 1'b0;
                            if ((state == ST_ACMD41_POLL) && (rx_byte == 8'h00)) begin
                                cmd_kind       <= CMD_KIND_CMD58;
                                byte_index     <= 3'd0;
                                retry_count    <= 32'd0;
                                start_gap(ST_CMD58_SEND);
                            end else if ((state == ST_ACMD41_POLL) && (rx_byte == 8'h01)) begin
                                if (acmd41_count >= ACMD41_RETRIES - 1) begin
                                    fail_init(ERR_ACMD41);
                                end else begin
                                    acmd41_count <= acmd41_count + 1'b1;
                                    cmd_kind     <= CMD_KIND_CMD55;
                                    byte_index   <= 3'd0;
                                    start_n1_idle;
                                end
                            end else if (((state == ST_CMD0_POLL) && (rx_byte == 8'h01)) ||
                                         ((state == ST_CMD8_POLL) && (rx_byte == 8'h01)) ||
                                         ((state == ST_CMD55_POLL) && (rx_byte == 8'h01)) ||
                                         ((state == ST_CMD58_POLL) && (rx_byte == 8'h00))) begin
                                if (state == ST_CMD0_POLL) begin
                                    cmd_kind    <= CMD_KIND_CMD8;
                                    byte_index  <= 3'd0;
                                    retry_count <= 32'd0;
                                    start_gap(ST_CMD8_SEND);
                                end else if (state == ST_CMD8_POLL) begin
                                    extra_index <= 3'd0;
                                    byte_issued <= 1'b0;
                                    state       <= ST_CMD8_EXTRA;
                                end else if (state == ST_CMD55_POLL) begin
                                    cmd_kind    <= CMD_KIND_ACMD41;
                                    byte_index  <= 3'd0;
                                    retry_count <= 32'd0;
                                    start_gap(ST_ACMD41_SEND);
                                end else begin
                                    extra_index <= 3'd0;
                                    ocr_shift   <= 32'd0;
                                    byte_issued <= 1'b0;
                                    state       <= ST_CMD58_EXTRA;
                                end
                            end else if (response_count >= RESPONSE_TIMEOUT_BYTES - 1) begin
                                if (state == ST_ACMD41_POLL) begin
                                    if (acmd41_count >= ACMD41_RETRIES - 1) begin
                                        fail_init(ERR_ACMD41);
                                    end else begin
                                        acmd41_count <= acmd41_count + 1'b1;
                                        response_count <= 32'd0;
                                        byte_index <= 3'd0;
                                        cmd_kind <= CMD_KIND_CMD55;
                                        start_n1_idle;
                                    end
                                end else if (retry_count >= CMD_RETRIES - 1) begin
                                    if (state == ST_CMD0_POLL) fail_init(ERR_CMD0);
                                    else if (state == ST_CMD8_POLL) fail_init(ERR_CMD8);
                                    else if (state == ST_CMD55_POLL) fail_init(ERR_CMD55);
                                    else fail_init(ERR_CMD58);
                                end else begin
                                    retry_count <= retry_count + 1'b1;
                                    response_count <= 32'd0;
                                    byte_index <= 3'd0;
                                    if (state == ST_CMD0_POLL) begin cmd_kind <= CMD_KIND_CMD0; start_gap(ST_CMD0_SEND); end
                                    else if (state == ST_CMD8_POLL) begin cmd_kind <= CMD_KIND_CMD8; start_gap(ST_CMD8_SEND); end
                                    else if (state == ST_CMD55_POLL) begin cmd_kind <= CMD_KIND_CMD55; start_gap(ST_CMD55_SEND); end
                                    else begin cmd_kind <= CMD_KIND_CMD58; start_gap(ST_CMD58_SEND); end
                                end
                            end else begin
                                response_count <= response_count + 1'b1;
                            end
                        end else if (!byte_issued) begin
                            tx_shift    <= 8'hFF;
                            rx_shift    <= 8'h00;
                            bit_index   <= 3'd7;
                            sd_mosi     <= 1'b1;
                            spi_active  <= 1'b1;
                            byte_issued <= 1'b1;
                        end
                    end

                    ST_CMD8_EXTRA: begin
                        if (spi_byte_done) begin
                            byte_issued <= 1'b0;
                            if (rx_byte != expected_cmd8_extra(extra_index)) begin
                                fail_init(ERR_CMD8_ECHO);
                            end else if (extra_index == 3'd3) begin
                                cmd_kind    <= CMD_KIND_CMD55;
                                byte_index  <= 3'd0;
                                retry_count <= 32'd0;
                                start_gap(ST_CMD55_SEND);
                            end else begin
                                extra_index <= extra_index + 1'b1;
                            end
                        end else if (!byte_issued) begin
                            tx_shift    <= 8'hFF;
                            rx_shift    <= 8'h00;
                            bit_index   <= 3'd7;
                            sd_mosi     <= 1'b1;
                            spi_active  <= 1'b1;
                            byte_issued <= 1'b1;
                        end
                    end

                    ST_CMD58_EXTRA: begin
                        if (spi_byte_done) begin
                            byte_issued <= 1'b0;
                            ocr_shift   <= {ocr_shift[23:0], rx_byte};
                            if (extra_index == 3'd3) begin
                                ocr_value        <= {ocr_shift[23:0], rx_byte};
                                sd_high_capacity <= ocr_shift[22];
                                if (!ocr_shift[31-8]) begin
                                    fail_init(ERR_OCR);
                                end else begin
                                    sd_init_ok <= 1'b1;
                                    init_done  <= 1'b1;
                                    state      <= ST_DONE;
                                end
                            end else begin
                                extra_index <= extra_index + 1'b1;
                            end
                        end else if (!byte_issued) begin
                            tx_shift    <= 8'hFF;
                            rx_shift    <= 8'h00;
                            bit_index   <= 3'd7;
                            sd_mosi     <= 1'b1;
                            spi_active  <= 1'b1;
                            byte_issued <= 1'b1;
                        end
                    end

                    ST_N1_IDLE: begin
                        sd_mosi <= 1'b1;
                        if (n1_edges == 0) begin
                            sd_clk         <= 1'b0;
                            state          <= ST_CMD55_SEND;
                            response_count <= 32'd0;
                            byte_issued    <= 1'b0;
                        end else if ((CLK_DIV <= 1) || (div_count >= CLK_DIV - 1)) begin
                            div_count <= 32'd0;
                            sd_clk   <= ~sd_clk;
                            n1_edges <= n1_edges - 1'b1;
                        end else begin
                            div_count <= div_count + 1'b1;
                        end
                    end

                    ST_GAP: begin
                        sd_mosi <= 1'b1;
                        if (gap_edges_left != 0) begin
                            if ((CLK_DIV <= 1) || (div_count >= CLK_DIV - 1)) begin
                                div_count      <= 32'd0;
                                sd_clk         <= ~sd_clk;
                                gap_edges_left <= gap_edges_left - 1'b1;
                            end else begin
                                div_count <= div_count + 1'b1;
                            end
                        end else begin
                            sd_clk <= 1'b0;
                            if ((CS_GAP_CYCLES <= 1) || (gap_count >= CS_GAP_CYCLES - 1)) begin
                                state     <= gap_target;
                                gap_count <= 32'd0;
                            end else begin
                                gap_count <= gap_count + 1'b1;
                            end
                        end
                    end

                    ST_DONE: begin
                        sd_clk  <= 1'b0;
                        sd_mosi <= 1'b1;
                    end

                    default: begin
                        sd_clk  <= 1'b0;
                        sd_mosi <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule
