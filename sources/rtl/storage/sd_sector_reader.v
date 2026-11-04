// -----------------------------------------------------------------------------
// sd_sector_reader.v
// C03: read-only SD SPI single/multi-sector reader.
//
// Address contract:
//   * req_lba is a 32-bit logical block address (LBA), measured in 512-byte
//     sectors, not a byte address.
//   * req_count is the number of consecutive 512-byte LBA sectors to read.
//   * For SDHC/SDXC (sd_high_capacity=1), the LBA is sent directly as the
//     command argument. For SDSC, the module converts LBA to byte address by
//     multiplying by 512.
//
// Protocol contract:
//   * C02 must have completed initialization: sd_init_ok=1.
//   * req_ready accepts a request only while idle or after a recoverable error.
//   * rsp_valid pulses once per data byte; rsp_last is asserted with the final
//     byte of the complete request; rsp_error is latched until the next request.
//   * A single sector uses CMD17. More than one sector uses CMD18 and CMD12.
//   * This module has no card-modification path.
//
// This module reuses the C01 read-only SPI byte engine and has no TF-card
// card-modification operation.
// -----------------------------------------------------------------------------
module sd_sector_reader #(
    parameter integer CLK_DIV                    = 2,
    parameter integer RESPONSE_TIMEOUT_BYTES    = 32,
    parameter integer DATA_TOKEN_TIMEOUT_BYTES  = 1024
) (
    input  wire        clk_50m,
    input  wire        rst_n,

    // C02 initialization status.
    input  wire        sd_init_ok,
    input  wire        sd_high_capacity,

    // Read request. req_lba is a sector/LBA address; req_count is a sector
    // count, with each sector exactly 512 bytes.
    input  wire        req_valid,
    input  wire [31:0] req_lba,
    input  wire [15:0] req_count,
    output wire        req_ready,

    // Read response stream.
    output reg         rsp_valid,
    output reg  [7:0]  rsp_data,
    output reg         rsp_last,
    output reg  [7:0]  rsp_error,
    output wire        busy,

    // SD SPI pins.
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n
);

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_CMD_SEND   = 4'd1;
    localparam [3:0] ST_R1_WAIT    = 4'd2;
    localparam [3:0] ST_TOKEN_WAIT = 4'd3;
    localparam [3:0] ST_DATA       = 4'd4;
    localparam [3:0] ST_CRC1       = 4'd5;
    localparam [3:0] ST_CRC2       = 4'd6;
    localparam [3:0] ST_ERROR      = 4'd7;
    localparam [3:0] ST_STOP_BUSY  = 4'd8;
    localparam [3:0] ST_DESELECT   = 4'd9;
    localparam [3:0] ST_EMIT       = 4'd10;
    localparam [3:0] ST_STARTUP    = 4'd11;

    localparam [1:0] CMD_KIND_SINGLE = 2'd0;
    localparam [1:0] CMD_KIND_MULTI  = 2'd1;
    localparam [1:0] CMD_KIND_STOP   = 2'd2;

    // Stable error codes for the C03 reader.
    localparam [7:0] ERR_BAD_COUNT   = 8'h01;
    localparam [7:0] ERR_R1          = 8'h02;
    localparam [7:0] ERR_DATA_TOKEN  = 8'h03;
    localparam [7:0] ERR_CMD12       = 8'h04;
    localparam [7:0] ERR_CRC16       = 8'h05;
    localparam [7:0] ERR_DATA_TIMEOUT = 8'h06;

    reg [3:0] state;
    reg conservative_rate;
    reg [1:0] cmd_kind;
    reg [2:0] cmd_index;
    reg [31:0] command_arg;
    reg [15:0] total_count;
    reg [15:0] sector_index;
    reg [9:0] data_byte_index;
    reg [31:0] wait_count;
    reg [3:0]  deselect_byte_count;
    reg [3:0]  deselect_next_state;
    reg [8:0]  emit_byte_index;
    reg [1:0]  retry_count;
    reg [3:0]  startup_byte_count;
    reg [31:0] request_lba_q;
    reg        address_mode_retry_done;
    reg [15:0] crc_calc;
    reg [7:0]  crc_received_hi;
    reg [7:0]  pending_error;

    reg        cs_active;
    reg        cs_force_high;
    reg        tx_valid;
    reg [7:0]  tx_data;
    reg        tx_waiting;

    wire       tx_ready;
    wire       phy_rx_valid;
    wire [7:0] phy_rx_data;
    wire       phy_busy;
    wire [7:0] current_command_byte;
    wire [7:0] sector_rd_data;
    wire [8:0] sector_read_addr = (state == ST_EMIT) ?
                                  (emit_byte_index + 1'b1) : 9'd0;
    wire       sector_wr_en = (state == ST_DATA) &&
                              tx_waiting && phy_rx_valid;

    function [15:0] crc16_step;
        input [15:0] crc_value;
        input [7:0]  data_value;
        integer bit_number;
        reg [15:0] crc_work;
        reg        data_bit;
        begin
            crc_work = crc_value;
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                data_bit = data_value[7 - bit_number];
                if (crc_work[15] ^ data_bit)
                    crc_work = (crc_work << 1) ^ 16'h1021;
                else
                    crc_work = crc_work << 1;
            end
            crc16_step = crc_work;
        end
    endfunction

    wire [15:0] crc16_next = crc16_step(crc_calc, phy_rx_data);

    assign req_ready = sd_init_ok && ((state == ST_IDLE) || (state == ST_ERROR));
    assign busy      = !((state == ST_IDLE) || (state == ST_ERROR));

    function [7:0] command_byte;
        input [1:0]  kind;
        input [2:0]  index;
        input [31:0] argument;
        begin
            command_byte = 8'hFF;
            case (kind)
                CMD_KIND_SINGLE: begin
                    case (index)
                        3'd0: command_byte = 8'h51; // CMD17
                        3'd1: command_byte = argument[31:24];
                        3'd2: command_byte = argument[23:16];
                        3'd3: command_byte = argument[15:8];
                        3'd4: command_byte = argument[7:0];
                        3'd5: command_byte = 8'hFF;
                        default: command_byte = 8'hFF;
                    endcase
                end
                CMD_KIND_MULTI: begin
                    case (index)
                        3'd0: command_byte = 8'h52; // CMD18
                        3'd1: command_byte = argument[31:24];
                        3'd2: command_byte = argument[23:16];
                        3'd3: command_byte = argument[15:8];
                        3'd4: command_byte = argument[7:0];
                        3'd5: command_byte = 8'hFF;
                        default: command_byte = 8'hFF;
                    endcase
                end
                CMD_KIND_STOP: begin
                    case (index)
                        3'd0: command_byte = 8'h4C; // CMD12
                        3'd5: command_byte = 8'hFF;
                        default: command_byte = 8'h00;
                    endcase
                end
                default: command_byte = 8'hFF;
            endcase
        end
    endfunction

    assign current_command_byte = command_byte(cmd_kind, cmd_index, command_arg);

    sd_spi_phy #(.CLK_DIV(CLK_DIV), .RETRY_CLK_DIV(4)) u_spi_phy (
        .clk_50m   (clk_50m),
        .rst_n     (rst_n),
        .cs_active (cs_active),
        .cs_force_high(cs_force_high),
        .slow_mode(conservative_rate),
        .tx_valid  (tx_valid),
        .tx_data   (tx_data),
        .tx_ready  (tx_ready),
        .rx_valid  (phy_rx_valid),
        .rx_data   (phy_rx_data),
        .busy      (phy_busy),
        .sd_clk    (sd_clk),
        .sd_mosi   (sd_mosi),
        .sd_miso   (sd_miso),
        .sd_cs_n   (sd_cs_n)
    );

    // Preserve both RAM ports' positive-edge values with a full half-cycle bundle.
    reg buffer_write_stage;
    reg [8:0] buffer_write_address_stage,buffer_read_address_stage;
    reg [7:0] buffer_data_stage;
    always @(negedge clk_50m) begin
        if (!rst_n) begin buffer_write_stage<=0;buffer_write_address_stage<=0;buffer_read_address_stage<=0;buffer_data_stage<=0;end
        else begin
            buffer_write_stage<=sector_wr_en;
            buffer_write_address_stage<=data_byte_index[8:0];
            buffer_read_address_stage<=sector_read_addr;
            buffer_data_stage<=phy_rx_data;
        end
    end
    // The address is already held at zero during the CRC-byte states, so DOB
    // contains byte zero when ST_EMIT starts. Do not add another wait state
    // here: that duplicates byte zero and shifts the entire sector stream.
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .ADDR_WIDTH_A(9), .DATA_DEPTH_A(512),
        .DATA_WIDTH_B(8), .ADDR_WIDTH_B(9), .DATA_DEPTH_B(512),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .FILL_ALL("NONE")
    ) u_sector_buffer (
        .dia(buffer_data_stage), .dib(8'd0),
        .addra(buffer_write_address_stage), .addrb(buffer_read_address_stage),
        .cea(buffer_write_stage && rst_n), .ceb(1'b1),
        .ocea(1'b0), .oceb(1'b0),
        .clka(clk_50m), .clkb(clk_50m),
        .wea(buffer_write_stage && rst_n), .web(1'b0),
        .bea(1'b1), .beb(1'b0),
        .rsta(!rst_n), .rstb(!rst_n),
        .doa(), .dob(sector_rd_data)
    );

    task finish_read;
        begin
            state      <= ST_DESELECT;
            cs_active  <= 1'b0;
            cs_force_high <= 1'b1;
            tx_waiting <= 1'b0;
            deselect_byte_count <= 4'd8;
            deselect_next_state <= ST_IDLE;
        end
    endtask

    task abort_read;
        input [7:0] code;
        begin
            pending_error <= code;
            rsp_error  <= 8'h00;
            state      <= ST_DESELECT;
            cs_active  <= 1'b0;
            cs_force_high <= 1'b1;
            tx_waiting <= 1'b0;
            deselect_byte_count <= 4'd8;
            deselect_next_state <= ST_ERROR;
        end
    endtask

    // A token error on a non-zero single-sector LBA can mean the card capacity
    // mode was decoded incorrectly: LBA0 is valid in both modes, while a
    // partition-start LBA is out of range when block and byte addressing are
    // swapped. Retry exactly once with the opposite read-only address form.
    task retry_token_or_abort;
        input [7:0] final_error;
        begin
            if ((total_count == 16'd1) &&
                (request_lba_q != 32'd0) &&
                !address_mode_retry_done) begin
                address_mode_retry_done <= 1'b1;
                if (sd_high_capacity)
                    command_arg <= (request_lba_q << 9);
                else
                    command_arg <= request_lba_q;
                cmd_kind       <= CMD_KIND_SINGLE;
                cmd_index      <= 3'd0;
                sector_index   <= 16'd0;
                data_byte_index <= 10'd0;
                wait_count     <= 32'd0;
                retry_count    <= 2'd0;
                crc_calc       <= 16'd0;
                state          <= ST_DESELECT;
                cs_active      <= 1'b0;
                cs_force_high  <= 1'b1;
                tx_waiting     <= 1'b0;
                deselect_byte_count <= 4'd8;
                deselect_next_state <= ST_CMD_SEND;
            end else begin
                abort_read(final_error);
            end
        end
    endtask

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            cmd_kind        <= CMD_KIND_SINGLE;
            cmd_index       <= 3'd0;
            command_arg     <= 32'd0;
            total_count     <= 16'd0;
            sector_index    <= 16'd0;
            data_byte_index <= 10'd0;
            wait_count      <= 32'd0;
            deselect_byte_count <= 4'd0;
            deselect_next_state <= ST_IDLE;
            emit_byte_index <= 9'd0;
            retry_count      <= 2'd0;
            startup_byte_count <= 4'd0;
            request_lba_q    <= 32'd0;
            address_mode_retry_done <= 1'b0;
            crc_calc         <= 16'd0;
            crc_received_hi  <= 8'd0;
            pending_error    <= 8'h00;
            conservative_rate <= 1'b0;
            cs_active       <= 1'b0;
            cs_force_high   <= 1'b0;
            tx_valid        <= 1'b0;
            tx_data         <= 8'hFF;
            tx_waiting      <= 1'b0;
            rsp_valid       <= 1'b0;
            rsp_data        <= 8'h00;
            rsp_last        <= 1'b0;
            rsp_error       <= 8'h00;
        end else begin
            // All stream flags are one-clock pulses.
            rsp_valid <= 1'b0;
            rsp_last  <= 1'b0;
            tx_valid  <= 1'b0;

            if ((state == ST_IDLE) || (state == ST_ERROR)) begin
                cs_active  <= 1'b0;
                tx_waiting <= 1'b0;

                if (req_valid && req_ready) begin
                    rsp_error <= 8'h00;
                    pending_error <= 8'h00;
                    if (req_count == 16'd0) begin
                        rsp_error <= ERR_BAD_COUNT;
                        state     <= ST_ERROR;
                    end else begin
                        total_count  <= req_count;
                        sector_index <= 16'd0;
                        data_byte_index <= 10'd0;
                        wait_count   <= 32'd0;
                        deselect_byte_count <= 4'd0;
                        deselect_next_state <= ST_IDLE;
                        emit_byte_index <= 9'd0;
                        retry_count <= 2'd0;
                        request_lba_q <= req_lba;
                        address_mode_retry_done <= 1'b0;
                        crc_calc <= 16'd0;
                        if (sd_high_capacity)
                            command_arg <= req_lba;
                        else
                            command_arg <= (req_lba << 9);
                        if (req_count == 16'd1)
                            cmd_kind <= CMD_KIND_SINGLE;
                        else
                            cmd_kind <= CMD_KIND_MULTI;
                        cmd_index  <= 3'd0;
                        cs_active  <= 1'b0;
                        cs_force_high <= 1'b1;
                        startup_byte_count <= 4'd0;
                        state      <= ST_STARTUP;
                    end
                end
            end else begin
                cs_active <= ((state != ST_DESELECT) && (state != ST_EMIT));

                if (state == ST_EMIT) begin
                    rsp_valid <= 1'b1;
                    rsp_data  <= sector_rd_data;
                    if (emit_byte_index == 9'd511) begin
                        rsp_last <= 1'b1;
                        emit_byte_index <= 9'd0;
                        state <= ST_DESELECT;
                        cs_active <= 1'b0;
                        cs_force_high <= 1'b1;
                        deselect_byte_count <= 4'd8;
                        deselect_next_state <= ST_IDLE;
                    end else begin
                        emit_byte_index <= emit_byte_index + 1'b1;
                    end
                end else if (tx_waiting) begin
                    if (phy_rx_valid) begin
                        tx_waiting <= 1'b0;

                        case (state)
                            ST_CMD_SEND: begin
                                if (cmd_index == 3'd5) begin
                                    cmd_index  <= 3'd0;
                                    wait_count <= 32'd0;
                                    state      <= ST_R1_WAIT;
                                end else begin
                                    cmd_index <= cmd_index + 1'b1;
                                end
                            end

                            ST_STARTUP: begin
                                if (startup_byte_count == 4'd7) begin
                                    startup_byte_count <= 4'd0;
                                    cs_force_high <= 1'b0;
                                    cmd_index <= 3'd0;
                                    wait_count <= 32'd0;
                                    state <= ST_CMD_SEND;
                                end else begin
                                    startup_byte_count <=
                                        startup_byte_count + 1'b1;
                                end
                            end

                            ST_R1_WAIT: begin
                                if (phy_rx_data == 8'hFF) begin
                                    if (wait_count >= RESPONSE_TIMEOUT_BYTES - 1) begin
                                        if (cmd_kind == CMD_KIND_STOP)
                                            abort_read(ERR_CMD12);
                                        else
                                            abort_read(ERR_R1);
                                    end else begin
                                        wait_count <= wait_count + 1'b1;
                                    end
                                end else if (phy_rx_data == 8'h00) begin
                                    wait_count <= 32'd0;
                                    if (cmd_kind == CMD_KIND_STOP) begin
                                        // CMD12 returns R1b in SPI mode; after
                                        // R1 the card may hold MISO low until
                                        // its internal busy period is over.
                                        wait_count <= 32'd0;
                                        state <= ST_STOP_BUSY;
                                    end else begin
                                        state <= ST_TOKEN_WAIT;
                                    end
                                end else begin
                                    if (cmd_kind == CMD_KIND_STOP)
                                        abort_read(ERR_CMD12);
                                    else
                                        abort_read(ERR_R1);
                                end
                            end

                            ST_STOP_BUSY: begin
                                if (phy_rx_data == 8'hFF) begin
                                    finish_read;
                                end else if (wait_count >= RESPONSE_TIMEOUT_BYTES - 1) begin
                                    abort_read(ERR_CMD12);
                                end else begin
                                    wait_count <= wait_count + 1'b1;
                                end
                            end
                            ST_DESELECT: begin
                                if (deselect_byte_count <= 4'd1) begin
                                    deselect_byte_count <= 4'd0;
                                    cs_force_high <= 1'b0;
                                    if (deselect_next_state == ST_ERROR)
                                        rsp_error <= pending_error;
                                    state <= deselect_next_state;
                                end else begin
                                    deselect_byte_count <= deselect_byte_count - 1'b1;
                                end
                            end
                            ST_TOKEN_WAIT: begin
                                if (phy_rx_data == 8'hFE) begin
                                    data_byte_index <= 10'd0;
                                    wait_count      <= 32'd0;
                                    crc_calc        <= 16'd0;
                                    state           <= ST_DATA;
                                end else if (phy_rx_data == 8'hFF) begin
                                    if (wait_count >= DATA_TOKEN_TIMEOUT_BYTES - 1)
                                        retry_token_or_abort(ERR_DATA_TIMEOUT);
                                    else
                                        wait_count <= wait_count + 1'b1;
                                end else begin
                                    retry_token_or_abort(ERR_DATA_TOKEN);
                                end
                            end

                            ST_DATA: begin
                                crc_calc <= crc16_next;
                                if (data_byte_index == 10'd511) begin
                                    data_byte_index <= 10'd0;
                                    state <= ST_CRC1;
                                end else begin
                                    data_byte_index <= data_byte_index + 1'b1;
                                end
                            end

                            ST_CRC1: begin
                                crc_received_hi <= phy_rx_data;
                                state <= ST_CRC2;
                            end

                            ST_CRC2: begin
                                if ({crc_received_hi, phy_rx_data} != crc_calc) begin
                                    conservative_rate <= 1'b1;
                                    if ((total_count == 16'd1) &&
                                        (retry_count < 2'd3)) begin
                                        retry_count <= retry_count + 1'b1;
                                        cmd_kind <= CMD_KIND_SINGLE;
                                        cmd_index <= 3'd0;
                                        sector_index <= 16'd0;
                                        data_byte_index <= 10'd0;
                                        wait_count <= 32'd0;
                                        crc_calc <= 16'd0;
                                        state <= ST_DESELECT;
                                        cs_active <= 1'b0;
                                        cs_force_high <= 1'b1;
                                        deselect_byte_count <= 4'd8;
                                        deselect_next_state <= ST_CMD_SEND;
                                    end else begin
                                        abort_read(ERR_CRC16);
                                    end
                                end else if (total_count == 16'd1) begin
                                    emit_byte_index <= 9'd0;
                                    cs_active <= 1'b0;
                                    cs_force_high <= 1'b0;
                                    state <= ST_EMIT;
                                end else if (sector_index == total_count - 1) begin
                                    if (cmd_kind == CMD_KIND_MULTI) begin
                                        cmd_kind  <= CMD_KIND_STOP;
                                        cmd_index <= 3'd0;
                                        wait_count <= 32'd0;
                                        state <= ST_CMD_SEND;
                                    end else begin
                                        finish_read;
                                    end
                                end else begin
                                    sector_index <= sector_index + 1'b1;
                                    wait_count   <= 32'd0;
                                    state         <= ST_TOKEN_WAIT;
                                end
                            end

                            default: begin
                                abort_read(ERR_R1);
                            end
                        endcase
                    end
                end else if (tx_ready) begin
                    tx_valid   <= 1'b1;
                    tx_waiting <= 1'b1;
                    if ((state == ST_CMD_SEND))
                        tx_data <= current_command_byte;
                    else
                        tx_data <= 8'hFF;
                end
            end
        end
    end

endmodule
