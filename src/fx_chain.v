// ============================================================
// fx_chain.v -- 混音 / 效果链总装
//
// 32 声部 PCM
// │
// ▼
// fx_channel_mix（每通道：音量 + 失真 + 4 路发送）
// │ dry │ send_echo │ send_reverb │ send_chorus │ send_phaser
// │ ▼ ▼ ▼ ▼
// │ fx_echo fx_reverb fx_mod（合唱+相位）
// │ │ │ │
// └───────────┴────────────┴──────────────┴──► fx_master
// 失真 -> 5 段 EQ -> 限幅 -> 主音量
// │
// ▼
// PCM 16 位
//
// 效果器是"发送式"：每个通道控制送多少，湿声在 fx_master 里与干声相加。
// 所有参数都来自网页控制台，掉电回默认值。
// ============================================================
module fx_chain #(
    parameter NUM_VOICES = 32,
    parameter MIX_CH     = 8
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     sample_en,
    // 声部 PCM
    input  wire [NUM_VOICES*16-1:0] pcm_bus,
    // 通道参数（32 × 16 位）
    input  wire [511:0]             ch_a,
    input  wire [511:0]             ch_b,
    // 主混音
    input  wire [2:0]               mix_shift,
    input  wire [7:0]               master,
    input  wire                     mute,
    // 回声
    input  wire                     echo_on,
    input  wire [7:0]               echo_time,
    input  wire [3:0]               echo_fb,
    input  wire [6:0]               echo_mix,
    // 混响
    input  wire                     rev_on,
    input  wire [6:0]               rev_size,
    input  wire [6:0]               rev_damp,
    input  wire [6:0]               rev_mix,
    // 合唱
    input  wire                     cho_on,
    input  wire [6:0]               cho_rate,
    input  wire [6:0]               cho_depth,
    input  wire [6:0]               cho_mix,
    // 相位
    input  wire                     pha_on,
    input  wire [6:0]               pha_rate,
    input  wire [6:0]               pha_depth,
    input  wire [3:0]               pha_fb,
    input  wire [6:0]               pha_mix,
    // 失真
    input  wire                     drv_on,
    input  wire [6:0]               drv_drive,
    input  wire [6:0]               drv_tone,
    input  wire [6:0]               drv_mix,
    // 限幅
    input  wire                     lim_on,
    input  wire [7:0]               lim_th,
    input  wire [7:0]               lim_ceil,
    input  wire [6:0]               lim_rel,
    // 均衡
    input  wire                     eq_on,
    input  wire [5:0]               eq_low,
    input  wire [5:0]               eq_lmid,
    input  wire [5:0]               eq_mid,
    input  wire [5:0]               eq_hmid,
    input  wire [5:0]               eq_high,
    input  wire [7:0]               eq_out,
    // 输出
    output wire signed [15:0]       pcm_out,
    output wire                     pcm_valid
);

    wire signed [23:0] dry;
    wire signed [23:0] send_echo, send_reverb, send_chorus, send_phaser;
    wire signed [23:0] echo_out, rev_out, cho_out, pha_out;

    fx_channel_mix #(
        .NUM_CH (MIX_CH)
    ) u_chmix (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_en   (sample_en),
        .pcm_bus     (pcm_bus[MIX_CH*16-1:0]),
        .ch_a        (ch_a),
        .ch_b        (ch_b),
        .dry         (dry),
        .send_echo   (send_echo),
        .send_reverb (send_reverb),
        .send_chorus (send_chorus),
        .send_phaser (send_phaser)
    );

    fx_echo u_echo (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .on        (echo_on),
        .delay_time(echo_time),
        .fb        (echo_fb),
        .mix       (echo_mix),
        .in        (send_echo),
        .out       (echo_out)
    );

    fx_reverb u_reverb (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .on        (rev_on),
        .size      (rev_size),
        .damp      (rev_damp),
        .mix       (rev_mix),
        .in        (send_reverb),
        .out       (rev_out)
    );

    fx_mod u_mod (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .cho_on    (cho_on),
        .cho_rate  (cho_rate),
        .cho_depth (cho_depth),
        .cho_mix   (cho_mix),
        .pha_on    (pha_on),
        .pha_rate  (pha_rate),
        .pha_depth (pha_depth),
        .pha_fb    (pha_fb),
        .pha_mix   (pha_mix),
        .in_cho    (send_chorus),
        .in_pha    (send_phaser),
        .cho_out   (cho_out),
        .pha_out   (pha_out)
    );

    fx_master u_master (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_en (sample_en),
        .dry       (dry),
        .echo      (echo_out),
        .reverb    (rev_out),
        .chorus    (cho_out),
        .phaser    (pha_out),
        .mix_shift (mix_shift),
        .master    (master),
        .mute      (mute),
        .drv_on    (drv_on),
        .drv_drive (drv_drive),
        .drv_tone  (drv_tone),
        .drv_mix   (drv_mix),
        .lim_on    (lim_on),
        .lim_th    (lim_th),
        .lim_ceil  (lim_ceil),
        .lim_rel   (lim_rel),
        .eq_on     (eq_on),
        .eq_low    (eq_low),
        .eq_lmid   (eq_lmid),
        .eq_mid    (eq_mid),
        .eq_hmid   (eq_hmid),
        .eq_high   (eq_high),
        .eq_out    (eq_out),
        .pcm_out   (pcm_out),
        .pcm_valid (pcm_valid)
    );

endmodule
