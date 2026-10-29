// ============================================================
// 多声部振荡器组：N 个 (振荡器 + 独立 ADSR)，输出 N 路并行 PCM
//
// 每个声部的音高/开关/力度来自 voice_alloc 的对应槽位，
// 波形和 ADSR 参数这里是共用的（想让每个声部参数不同，
// 把对应输入改成数组、在 generate 里按 i 取即可）。
//
// 输出 pcm_bus：第 i 个声部的 PCM 是 pcm_bus[i*16 +: 16]（16 位有符号）
// 输出 env_bus：第 i 个声部的包络是 env_bus[i*16 +: 16]（调试用）
//
// 这一版不做混音，8 路 PCM 原样并行输出，
// 交给后面的"混音 + 限幅"模块去相加/缩放成最终 PCM。
// ============================================================
module synth_voices #(
    parameter NUM_VOICES = 8,
    parameter PHASE_BITS = 24
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    sample_en,      // 采样率使能
    // ---- 来自 voice_alloc 的各声部状态 ----
    input  wire [NUM_VOICES*7-1:0] v_note,         // 第 i 个：v_note[i*7 +: 7]
    input  wire [NUM_VOICES*7-1:0] v_vel,          // 第 i 个：v_vel [i*7 +: 7]
    input  wire [NUM_VOICES-1:0]   v_gate,         // 第 i 个：v_gate[i]
    // ---- 波形选择 + ADSR 参数（全体共用）----
    input  wire [2:0]              wave_sel,       // 0方波 1锯齿 2三角 3正弦 4钢琴(多泛音) 5FM
    // FM / 泛音参数（来自网页控制台的参数寄存器）
    input  wire [2:0]              fm_ratio,       // FM 调制比档位 0..7
    input  wire [2:0]              fm_depth,       // FM 调制深度 >>>n
    input  wire [7:0]              harm_att,       // 钢琴 4 个泛音各自的衰减
    // 演奏效果
    input  wire                    glide_en,       // 滑音开关
    input  wire [3:0]              glide_shift,    // 滑音速率
    input  wire [7:0]              vib_delta,      // 全局颤音 LFO 调制量
    // PWM 脉宽调制
    input  wire [7:0]              pwm_width,
    input  wire signed [7:0]       pwm_mod,
    input  wire [6:0]              pwm_depth,
    input  wire [3:0]              env_rate,       // 包络速率分频（0=最快）
    input  wire [3:0]              env_exp,        // 衰减曲线：0=线性，>0=指数
    input  wire                    env_oneshot,    // 1 = 衰减到 0 自终止
    // 延音踏板（全局）
    input  wire                    pedal_en,
    input  wire [15:0]             pedal_step,
    input  wire [15:0]             atk_step,
    input  wire [15:0]             dec_step,
    input  wire [15:0]             sus_level,
    input  wire [15:0]             rel_step,
    // ---- 输出：每声部一路 PCM / 包络 ----
    output wire [NUM_VOICES*16-1:0] pcm_bus,
    output wire [NUM_VOICES*16-1:0] env_bus,
    output wire [NUM_VOICES*24-1:0] inc_bus       // 各声部当前相位增量
);

    genvar i;

    generate
        for (i = 0; i < NUM_VOICES; i = i + 1) begin : g_voice
            osc_voice #(
                .PHASE_BITS (PHASE_BITS)
            ) u_osc (
                .clk        (clk),
                .rst_n      (rst_n),
                .sample_en  (sample_en),
                .note       (v_note[i*7 +: 7]),
                .gate       (v_gate[i]),
                .velocity   (v_vel[i*7 +: 7]),
                .wave_sel   (wave_sel),
                .fm_ratio   (fm_ratio),
                .fm_depth   (fm_depth),
                .harm_att   (harm_att),
                .glide_en   (glide_en),
                .glide_shift(glide_shift),
                .vib_delta  (vib_delta),
                .pwm_width  (pwm_width),
                .pwm_mod    (pwm_mod),
                .pwm_depth  (pwm_depth),
                .env_rate   (env_rate),
                .env_exp    (env_exp),
                .env_oneshot(env_oneshot),
                .pedal_en   (pedal_en),
                .pedal_step (pedal_step),
                .atk_step   (atk_step),
                .dec_step   (dec_step),
                .sus_level  (sus_level),
                .rel_step   (rel_step),
                .pcm        (pcm_bus[i*16 +: 16]),
                .env_out    (env_bus[i*16 +: 16]),
                .env_active (),
                .inc_out    (inc_bus[i*24 +: 24])
            );
        end
    endgenerate

endmodule
