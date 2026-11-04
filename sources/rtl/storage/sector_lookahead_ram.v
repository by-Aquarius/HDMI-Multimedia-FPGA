`timescale 1ns / 1ps
// Synchronous sector RAM with write forwarding / 带写转发的同步扇区存储。
// The caller supplies the read pointer AFTER the current pop. A matching write
// forwards its data so empty-to-nonempty and simultaneous push/pop have exactly
// the same head semantics as an asynchronous array, using one ERAM9K instead.
module sector_lookahead_ram (
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire write_valid,
    input wire [9:0] write_address,
    input wire [8:0] write_data,
    input wire [9:0] next_read_address,
    output wire [8:0] head_data
);
    wire [8:0] memory_data;
    reg forwarding_q;
    reg [8:0] forwarded_data_q;
    assign head_data = forwarding_q ? forwarded_data_q : memory_data;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin forwarding_q<=0;forwarded_data_q<=0;end
        else if(clear) forwarding_q<=0;
        else begin
            forwarding_q<=write_valid && write_address==next_read_address;
            if(write_valid) forwarded_data_q<=write_data;
        end
    end
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(9),.DATA_WIDTH_B(9),.ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),
        .DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),.MODE("DP"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("9K"),.FILL_ALL("NONE")
    ) u_sector_ram (
        .dia(write_data),.dib(9'd0),.addra(write_address),.addrb(next_read_address),
        .cea(write_valid && !clear),.ceb(1'b1),.ocea(1'b0),.oceb(1'b0),
        .clka(clk),.clkb(clk),.wea(write_valid && !clear),.web(1'b0),
        .bea(1'b1),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(memory_data)
    );
endmodule
