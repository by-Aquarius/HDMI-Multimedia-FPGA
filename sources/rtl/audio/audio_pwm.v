`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// audio_pwm.v
// F03: signed PCM to Audio_PWM modulation for the F3 low-pass/amplifier path.
// -----------------------------------------------------------------------------
module audio_pwm #(
    parameter [7:0] SILENCE_DUTY = 8'd128,
    parameter [7:0] MIN_DUTY     = 8'd8,
    parameter [7:0] MAX_DUTY     = 8'd247
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_valid,
    input  wire [15:0] sample_pcm,
    input  wire        underrun,
    input  wire        pwm_enable,

    output reg         audio_pwm,
    output wire [7:0]  duty_debug
);

    reg [7:0] pwm_counter;
    reg [7:0] duty_q;
    reg [7:0] pending_duty;
    reg       pending_valid;

    wire [16:0] sample_biased = {1'b0, sample_pcm} + 17'h08000;
    wire [7:0]  sample_duty = sample_biased[15:8];
    wire [7:0]  desired_duty =
        (!pwm_enable || underrun) ? SILENCE_DUTY :
        (sample_duty < MIN_DUTY) ? MIN_DUTY :
        (sample_duty > MAX_DUTY) ? MAX_DUTY : sample_duty;

    assign duty_debug = duty_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pwm_counter   <= 8'd0;
            duty_q        <= SILENCE_DUTY;
            pending_duty  <= SILENCE_DUTY;
            pending_valid <= 1'b0;
            audio_pwm     <= 1'b0;
        end else begin
            if (pwm_counter == 8'd255)
                pwm_counter <= 8'd0;
            else
                pwm_counter <= pwm_counter + 1'b1;

            if (sample_valid) begin
                pending_duty  <= desired_duty;
                pending_valid <= 1'b1;
            end

            if ((pwm_counter == 8'd0) && pending_valid) begin
                duty_q        <= pending_duty;
                pending_valid <= 1'b0;
            end

            audio_pwm <= (pwm_counter < duty_q);
        end
    end

endmodule
