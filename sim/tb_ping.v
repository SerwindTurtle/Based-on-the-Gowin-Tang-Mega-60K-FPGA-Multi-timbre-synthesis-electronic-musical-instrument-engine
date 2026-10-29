`timescale 1ns/1ps
module tb_ping;
    reg clk = 0;
    reg rst_n = 0;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0;
    wire [7:0] tx_data;
    wire tx_send;
    reg tx_busy = 0;
    reg key_timbre_tog = 0;
    reg [3:0] key_timbre_val = 4'd1;
    reg [63:0] telem_snap = 0;
    reg telem_tog = 0;

    wire [3:0] o_timbre;
    wire [2:0] o_wave, o_fm_ratio, o_fm_depth;
    wire [7:0] o_harm_att;
    wire o_vel_press, o_oneshot, o_mono, o_glide_en, o_vib_en, o_oct_tog;
    wire [3:0] o_glide_shift;
    wire [7:0] o_vib_rate, o_pwm_width, o_pwm_rate, o_master;
    wire [6:0] o_vib_depth, o_sustain, o_pwm_depth, o_uni_detune, o_uni_mix;
    wire [5:0] o_transpose;
    wire signed [2:0] o_octave;
    wire o_uni_on;
    wire [2:0] o_uni_layers;
    wire [511:0] o_ch_a, o_ch_b, o_fx;
    wire [3:0] o_rate, o_exp;
    wire [15:0] o_atk, o_dec, o_sus, o_rel;
    wire [2:0] o_mix_shift;
    wire o_mute;
    wire [63:0] o_key_vol;
    wire [7:0] o_rx_err;
    wire [15:0] o_set_cnt;

    param_regs dut (
        .clk(clk), .rst_n(rst_n),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .tx_data(tx_data), .tx_send(tx_send), .tx_busy(tx_busy),
        .key_timbre_tog(key_timbre_tog), .key_timbre_val(key_timbre_val),
        .telem_snap(telem_snap), .telem_tog(telem_tog),
        .o_timbre(o_timbre), .o_wave(o_wave), .o_fm_ratio(o_fm_ratio), .o_fm_depth(o_fm_depth),
        .o_harm_att(o_harm_att), .o_vel_press(o_vel_press), .o_oneshot(o_oneshot),
        .o_mono(o_mono), .o_glide_en(o_glide_en), .o_glide_shift(o_glide_shift),
        .o_vib_en(o_vib_en), .o_vib_rate(o_vib_rate), .o_vib_depth(o_vib_depth),
        .o_transpose(o_transpose), .o_octave(o_octave), .o_oct_tog(o_oct_tog),
        .o_sustain(o_sustain), .o_pwm_width(o_pwm_width), .o_pwm_rate(o_pwm_rate),
        .o_pwm_depth(o_pwm_depth), .o_uni_on(o_uni_on), .o_uni_layers(o_uni_layers),
        .o_uni_detune(o_uni_detune), .o_uni_mix(o_uni_mix),
        .o_ch_a(o_ch_a), .o_ch_b(o_ch_b), .o_fx(o_fx),
        .o_rate(o_rate), .o_exp(o_exp), .o_atk(o_atk), .o_dec(o_dec),
        .o_sus(o_sus), .o_rel(o_rel), .o_mix_shift(o_mix_shift),
        .o_master(o_master), .o_mute(o_mute), .o_key_vol(o_key_vol),
        .o_rx_err(o_rx_err), .o_set_cnt(o_set_cnt)
    );

    always #10 clk = ~clk;

    integer i;
    integer n;
    reg [7:0] pong [0:7];

    task send_byte(input [7:0] b);
        begin
            @(posedge clk);
            rx_data <= b;
            rx_valid <= 1;
            @(posedge clk);
            rx_valid <= 0;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        // PING = A5 5A 03 00 3F
        send_byte(8'hA5);
        send_byte(8'h5A);
        send_byte(8'h03);
        send_byte(8'h00);
        send_byte(8'h3F);

        n = 0;
        for (i = 0; i < 2000; i = i + 1) begin
            @(posedge clk);
            if (tx_send) begin
                pong[n] = tx_data;
                $display("TX[%0d] = %02X", n, tx_data);
                n = n + 1;
            end
            if (n >= 7) i = 2000;
        end
        $display("TX count = %0d", n);
        if (n >= 7 && pong[0]==8'hA5 && pong[1]==8'h5A && pong[2]==8'h83 &&
            pong[3]==8'h02 && pong[4]==8'h01 && pong[5]==8'h01 && pong[6]==8'hCF)
            $display("PING PONG OK");
        else
            $display("PING PONG FAIL");
        $finish;
    end
endmodule
