`timescale 1ns/1ps
// Image-number voice playback / 图片编号语音播放。
// Signed PCM content is prepared offline; only FPGA ROM playback occurs at run time.
module image_voice_prompt (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    input wire enable,
    input wire running,
    input wire trigger,
    input wire [4:0] image_index,
    output wire busy,
    output wire [15:0] pcm,
    output reg [7:0] event_count,
    output reg [4:0] spoken_index
);
    localparam [2:0] IDLE=0, LOAD=1, WARM=2, PLAY=3, ADVANCE=4, RELEASE=5;
    reg [2:0] state, next_state;
    reg pending;
    reg [4:0] pending_index;
    reg [19:0] pending_words, phrase_words;
    reg [13:0] word_begin, word_length;
    reg [13:0] address, remaining;
    reg [2:0] sample_phase;
    reg signed [15:0] pcm_hold;
    wire [31:0] bank_data;
    reg [1:0] bank_select;
    wire signed [7:0] rom_pcm = bank_data[bank_select*8 +: 8];
    wire clip_end = sample_tick && sample_phase==7 && remaining==0;
    wire phrase_end = phrase_words[7:4]==4'hf;
    wire signed [15:0] release_pcm = pcm_hold>16'sd1024 ? pcm_hold-16'sd1024 :
        pcm_hold < -16'sd1024 ? pcm_hold+16'sd1024 : 16'sd0;
    assign pcm = pcm_hold;
    assign busy = state!=IDLE || pending;
    always @(posedge clk) bank_select <= address[13:12];
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8), .ADDR_WIDTH_A(12), .ADDR_WIDTH_B(12),
        .DATA_DEPTH_A(4096), .DATA_DEPTH_B(4096), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"), .IMPLEMENT("32K"),
        .INIT_FILE("../assets/voice_bank_0.dat"), .FILL_ALL("NONE")
    ) u_voice_bank_0 (
        .dia(8'd0), .dib(8'd0), .addra(address[11:0]), .addrb(12'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(bank_data[0 +: 8]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8), .ADDR_WIDTH_A(12), .ADDR_WIDTH_B(12),
        .DATA_DEPTH_A(4096), .DATA_DEPTH_B(4096), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"), .IMPLEMENT("32K"),
        .INIT_FILE("../assets/voice_bank_1.dat"), .FILL_ALL("NONE")
    ) u_voice_bank_1 (
        .dia(8'd0), .dib(8'd0), .addra(address[11:0]), .addrb(12'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(bank_data[8 +: 8]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8), .ADDR_WIDTH_A(12), .ADDR_WIDTH_B(12),
        .DATA_DEPTH_A(4096), .DATA_DEPTH_B(4096), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"), .IMPLEMENT("32K"),
        .INIT_FILE("../assets/voice_bank_2.dat"), .FILL_ALL("NONE")
    ) u_voice_bank_2 (
        .dia(8'd0), .dib(8'd0), .addra(address[11:0]), .addrb(12'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(bank_data[16 +: 8]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8), .ADDR_WIDTH_A(12), .ADDR_WIDTH_B(12),
        .DATA_DEPTH_A(4096), .DATA_DEPTH_B(4096), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"), .IMPLEMENT("32K"),
        .INIT_FILE("../assets/voice_bank_3.dat"), .FILL_ALL("NONE")
    ) u_voice_bank_3 (
        .dia(8'd0), .dib(8'd0), .addra(address[11:0]), .addrb(12'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(bank_data[24 +: 8]), .dob()
    );
    // The trigger carries the already committed index, rather than a requested target.
    always @(*) begin
        case (pending_index)
            5'd0: pending_words=20'hffb10;
            5'd1: pending_words=20'hffb20;
            5'd2: pending_words=20'hffb30;
            5'd3: pending_words=20'hffb40;
            5'd4: pending_words=20'hffb50;
            5'd5: pending_words=20'hffb60;
            5'd6: pending_words=20'hffb70;
            5'd7: pending_words=20'hffb80;
            5'd8: pending_words=20'hffb90;
            5'd9: pending_words=20'hffba0;
            5'd10: pending_words=20'hfb1a0;
            5'd11: pending_words=20'hfb2a0;
            5'd12: pending_words=20'hfb3a0;
            5'd13: pending_words=20'hfb4a0;
            5'd14: pending_words=20'hfb5a0;
            5'd15: pending_words=20'hfb6a0;
            5'd16: pending_words=20'hfb7a0;
            5'd17: pending_words=20'hfb8a0;
            5'd18: pending_words=20'hfb9a0;
            5'd19: pending_words=20'hfba20;
            5'd20: pending_words=20'hb1a20;
            5'd21: pending_words=20'hb2a20;
            5'd22: pending_words=20'hb3a20;
            5'd23: pending_words=20'hb4a20;
            5'd24: pending_words=20'hb5a20;
            5'd25: pending_words=20'hb6a20;
            5'd26: pending_words=20'hb7a20;
            5'd27: pending_words=20'hb8a20;
            5'd28: pending_words=20'hb9a20;
            5'd29: pending_words=20'hfba30;
            5'd30: pending_words=20'hb1a30;
            5'd31: pending_words=20'hb2a30;
            default: pending_words=20'hffb10;
        endcase
    end
    always @(*) begin
        word_begin=0; word_length=1;
        case (phrase_words[3:0])
            4'd0: begin word_begin=14'd0; word_length=14'd894; end
            4'd1: begin word_begin=14'd894; word_length=14'd1088; end
            4'd2: begin word_begin=14'd1982; word_length=14'd1153; end
            4'd3: begin word_begin=14'd3135; word_length=14'd1689; end
            4'd4: begin word_begin=14'd4824; word_length=14'd1483; end
            4'd5: begin word_begin=14'd6307; word_length=14'd1419; end
            4'd6: begin word_begin=14'd7726; word_length=14'd1076; end
            4'd7: begin word_begin=14'd8802; word_length=14'd1380; end
            4'd8: begin word_begin=14'd10182; word_length=14'd1221; end
            4'd9: begin word_begin=14'd11403; word_length=14'd1215; end
            4'd10: begin word_begin=14'd12618; word_length=14'd1683; end
            4'd11: begin word_begin=14'd14301; word_length=14'd1345; end
            default: begin word_begin=0; word_length=1; end
        endcase
    end
    // Independent state register, transition decode, and state datapath processes.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state<=IDLE;
        else state<=next_state;
    end
    always @(*) begin
        next_state=state;
        if (!enable) next_state=RELEASE;
        else if (trigger && state!=IDLE) next_state=RELEASE;
        else case (state)
            IDLE: if (pending && running) next_state=ADVANCE;
            ADVANCE: next_state=LOAD;
            LOAD: next_state=WARM;
            WARM: next_state=PLAY;
            PLAY: if (running && clip_end) begin
                if (phrase_end) next_state=IDLE;
                else next_state=LOAD;
            end
            RELEASE: if (pcm_hold==0) next_state=IDLE;
            default: next_state=IDLE;
        endcase
        if (!enable && pcm_hold==0) next_state=IDLE;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending<=0; pending_index<=0; phrase_words<=20'hfffff;
            address<=0; remaining<=0; sample_phase<=0; pcm_hold<=0;
            event_count<=0; spoken_index<=0;
        end else begin
            case (state)
                IDLE: begin pcm_hold<=0; sample_phase<=0; end
                ADVANCE: begin
                    phrase_words<=pending_words; pending<=0;
                    spoken_index<=pending_index; event_count<=event_count+1'b1;
                end
                LOAD: begin address<=word_begin; remaining<=word_length; sample_phase<=0; end
                PLAY: if (running && sample_tick) begin
                    sample_phase<=sample_phase+1'b1;
                    if (sample_phase==0) begin
                        pcm_hold<={rom_pcm,8'd0}; address<=address+1'b1;
                        remaining<=remaining-1'b1;
                    end
                    if (clip_end) begin
                        phrase_words<={4'hf,phrase_words[19:4]};
                        if (phrase_end) pcm_hold<=0;
                    end
                end
                RELEASE: if(sample_tick) pcm_hold<=release_pcm;
                default: begin end
            endcase
            if (!enable) pending<=0;
            else if (trigger) begin pending<=1; pending_index<=image_index; end
        end
    end
endmodule
