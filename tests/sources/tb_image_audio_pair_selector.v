`timescale 1ns/1ps
module tb_image_audio_pair_selector;
    reg  pair_mode;
    reg  [4:0] image_index;
    reg  [4:0] image_count;
    reg  [4:0] audio_count;
    wire [4:0] audio_index;
    wire pair_valid;
    wire audio_present;
    wire audio_missing;
    integer checks;

    image_audio_pair_selector dut (
        .pair_mode(pair_mode),
        .image_index(image_index),
        .image_count(image_count),
        .audio_count(audio_count),
        .audio_index(audio_index),
        .pair_valid(pair_valid),
        .audio_present(audio_present),
        .audio_missing(audio_missing)
    );

    task check_pair;
        input mode;
        input [4:0] image;
        input [4:0] images;
        input [4:0] audios;
        input [4:0] expected_index;
        input expected_valid;
        input expected_present;
        input expected_missing;
        begin
            pair_mode = mode;
            image_index = image;
            image_count = images;
            audio_count = audios;
            #1;
            checks = checks + 1;
            if (audio_index !== expected_index) begin
                $display("FAIL audio_index mode=%b image=%0d actual=%0d",
                         mode, image, audio_index);
                $finish;
            end
            if (pair_valid !== expected_valid ||
                audio_present !== expected_present ||
                audio_missing !== expected_missing) begin
                $display("FAIL flags image=%0d valid=%b present=%b missing=%b",
                         image, pair_valid, audio_present, audio_missing);
                $finish;
            end
        end
    endtask

    initial begin
        checks = 0;
        // Shared soundtrack: every image selects WAV 0 continuously.
        check_pair(1'b0, 5'd0, 5'd8, 5'd8, 5'd0, 1'b1, 1'b1, 1'b0);
        check_pair(1'b0, 5'd6, 5'd8, 5'd8, 5'd0, 1'b1, 1'b1, 1'b0);
        check_pair(1'b0, 5'd7, 5'd8, 5'd1, 5'd0, 1'b1, 1'b1, 1'b0);
        check_pair(1'b0, 5'd0, 5'd0, 5'd8, 5'd0, 1'b0, 1'b0, 1'b0);
        // Per-image soundtrack: image N selects WAV N and never falls back.
        check_pair(1'b1, 5'd0, 5'd8, 5'd8, 5'd0, 1'b1, 1'b1, 1'b0);
        check_pair(1'b1, 5'd1, 5'd8, 5'd8, 5'd1, 1'b1, 1'b1, 1'b0);
        check_pair(1'b1, 5'd7, 5'd8, 5'd8, 5'd7, 1'b1, 1'b1, 1'b0);
        check_pair(1'b1, 5'd3, 5'd8, 5'd3, 5'd3, 1'b1, 1'b0, 1'b1);
        check_pair(1'b1, 5'd8, 5'd8, 5'd8, 5'd8, 1'b0, 1'b0, 1'b0);
        $display("IMAGE_AUDIO_PAIR_MODE_PASS checks=%0d", checks);
        $finish;
    end
endmodule
