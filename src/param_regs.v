// ============================================================
// param_regs.v -- 参数寄存器 / UART 协议 / 音色预设 / 遥测上报
//
// 这是"网页控制台 <-> FPGA 合成器"的唯一通道，纯寄存器实现，不占 DSP。
//
// ── 串口 ────────────────────────────────────────────────────
// 115200 8N1（FPGA 50MHz 时钟，分频 434）
//
// ── 帧格式（PC -> FPGA / FPGA -> PC 相同）────────────────────
// A5 5A | TYPE | LEN | PAYLOAD[LEN] | CRC8
// CRC8 = 多项式 0x07、初值 0x00，覆盖 TYPE、LEN、PAYLOAD
// （"123456789" 的 CRC8/ATM = 0xF4，可用来自检）
//
// TYPE = 0x01 SET PAYLOAD = N × {addr, val_lo, val_hi} N<=16
// TYPE = 0x02 GET PAYLOAD = N × {addr} N<=16
// TYPE = 0x03 PING PAYLOAD = 空
// TYPE = 0x81 VALUE （FPGA->PC）N × {addr, lo, hi}
// TYPE = 0x82 TELEM （FPGA->PC）固定 16 字节，约 24Hz 主动上报
// TYPE = 0x83 PONG （FPGA->PC）{主版本, 次版本}
//
// ── 寄存器表（16 位值，小端）────────────────────────────────
// 0x01 VERSION (ro) = 0x0101
// ── 音色 ──────────────────────────────────────────────
// 0x10 TIMBRE 0..9 当前音色号（写入会重新装载该音色的预设。）
// 0x11 WAVE 0..5 0方波 1锯齿 2三角 3正弦 4钢琴(加法) 5FM
// 0x12 FM_RATIO 0..7 0:0.5 1:1.0 2:1.5 3:2.0 4:2.5 5:3.0 6:3.5 7:4.0
// 0x13 FM_DEPTH 0..4 调制深度 = m_ext >>> n
// 0x14 HARM1_ATT 0..3 基波衰减（0=×1,1=×1/2,2=×1/4,3=×1/8）
// 0x15 HARM2_ATT 0..3 二次谐波衰减
// 0x16 HARM3_ATT 0..3 三次谐波衰减
// 0x17 HARM4_ATT 0..3 四次谐波衰减
// 0x18 VEL_PRESS 0/1 1=钢琴/古筝/木琴用压力力度
// 0x19 ENV_ONESHOT 0/1 1=衰减到 0 自终止（打击音）
// ── 演奏效果（全局，不随音色预设变化）──────────────────
// 0x1A MONO 0/1 1=单音模式（最后按键优先，连奏不重触发）
// 0x1B GLIDE_EN 0/1 1=滑音
// 0x1C GLIDE_SHIFT 0..15 滑音时间常数 τ = 2^n / 48.8kHz
// 0x1D VIB_EN 0/1 1=颤音
// 0x1E VIB_RATE 0..255 0.1Hz 单位（55=5.5Hz）
// 0x1F VIB_DEPTH 0..127 峰值约 ±0..±104 音分
// ── 包络 ──────────────────────────────────────────────
// 0x20 ENV_RATE 0..4 包络每 2^n 个采样点更新一次（>4 与 4 相同）
// 0x21 ENV_EXP 0..15 0=线性；>0=每拍减当前值的 1/2^n
// 0x22 ATK_STEP 1..65535
// 0x23 DEC_STEP 0..65535（线性模式用）
// 0x24 SUS_LEVEL 0..65535
// 0x25 REL_STEP 0..65535
// 0x26 TRANSPOSE -12..+12 实时变调（有符号 16 位补码）
// 0x27 OCTAVE -2..+2 八度偏移（有符号；和 KBD_UP/DN 同步）
// 0x28 SUSTAIN 0..127 延音踏板
// 0x2D..0x2F PWM_WIDTH / RATE / DEPTH
// 0x29..0x2C UNISON_ON / LAYERS / DETUNE / MIX（32 声部齐奏）
// ── 混音 ──────────────────────────────────────────────
// 0x30 MIX_SHIFT 0..6 总衰减 = 右移 n 位
// 0x31 MASTER_VOL 0..255 主音量（内含 ~5ms 平滑，不会咔哒）
// 0x32 MUTE 0/1
// 0x38..0x3F KEY_VOL[0..7] 0..128 每键/每声部音量（128=原音量）
// ── 全局效果 / 均衡（第三轮）─────────────────
// 0x50..0x53 ECHO_ON / ECHO_TIME / ECHO_FB / ECHO_MIX
// 0x54..0x57 REV_ON / REV_SIZE / REV_DAMP / REV_MIX
// 0x58..0x5B CHO_ON / CHO_RATE / CHO_DEPTH / CHO_MIX
// 0x5C..0x60 PHA_ON / PHA_RATE / PHA_DEPTH / PHA_FB / PHA_MIX
// 0x61..0x64 DRV_ON / DRV_DRIVE / DRV_TONE / DRV_MIX
// 0x65..0x68 LIM_ON / LIM_TH / LIM_CEIL / LIM_REL
// 0x69..0x6F EQ_ON / EQ_LOW / EQ_LMID / EQ_MID / EQ_HMID / EQ_HIGH / EQ_OUT
// ── 32 声道混音台 ─────────────────────────────────────
// 0x80..0x9F CH_A[0..31] = {dist[7:0], vol[7:0]}
// 0xA0..0xBF CH_B[0..31] = {pha[3:0], cho[3:0], rev[3:0], echo[3:0]}
// ── 只读监视（遥测快照）──────────────────────────────
// 0x40 ADS_VEL 0..127 0x44 OCT_SHIFT（有符号）
// 0x41 ADS_RAW 0..255 0x45 KEY_MASK
// 0x42 POLY 0x46 FLAGS [0]ads_ok [1]page_dbg [2]ads_seen0
// 0x43 POLY_PEAK 0x47 ADS_ERR
//
// ── 遥测 16 字节 ───────────────────────────────────────────
// 0 TIMBRE 1 WAVE 2 ADS_VEL 3 ADS_RAW
// 4 POLY 5 PEAK 6 OCT 7 KEY_MASK
// 8 FLAGS 9 ADS_ERR 10 MASTER 11 {4'b0, MIX_SHIFT, MUTE}
// 12 SET_CNT 13 RX_ERR 14/15 遥测帧计数（小端）
//
//  写 TIMBRE 会"先装预设"，所以一条 SET 帧里如果要带自定义参数，
// TIMBRE 必须放在第一项；网页控制台是分开两帧发（TIMBRE 单独一帧），
// 因此不会有顺序问题。
// ============================================================
module param_regs #(
    parameter integer CLK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 来自 uart_rx ----
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    // ---- 送给 uart_tx ----
    output reg  [7:0]  tx_data,
    output reg         tx_send,
    input  wire        tx_busy,

    // ---- KEY0 换音色请求（adc_clk 域，已去抖）----
    input  wire        key_timbre_tog,
    input  wire [3:0]  key_timbre_val,

    // ---- 遥测快照（adc_clk 域，约 24Hz 更新一次）----
    input  wire [63:0] telem_snap,
    input  wire        telem_tog,

    // ---- 实时参数（sys_clk 域；top.v 会用影子寄存器搬到 adc_clk 域）----
    output reg  [3:0]  o_timbre,
    output reg  [2:0]  o_wave,
    output reg  [2:0]  o_fm_ratio,
    output reg  [2:0]  o_fm_depth,
    output wire [7:0]  o_harm_att,      // [1:0]=H1 [3:2]=H2 [5:4]=H3 [7:6]=H4
    output reg         o_vel_press,
    output reg         o_oneshot,
    // ---- 演奏效果 ----
    output reg         o_mono,          // 1 = 单音模式（所有键共用一条声部）
    output reg         o_glide_en,      // 1 = 滑音
    output reg  [3:0]  o_glide_shift,   // 滑音速率（1/2^N）
    output reg         o_vib_en,        // 1 = 颤音
    output reg  [7:0]  o_vib_rate,      // 0.1Hz 单位
    output reg  [6:0]  o_vib_depth,     // 0..127
    output reg  [5:0]  o_transpose,     // 实时变调：有符号 -12..+12 半音
    output reg signed [2:0] o_octave,   // 网页八度偏移 -2..+2
    output reg         o_oct_tog,       // 每写一次 0x27 翻转一次（adc_clk 域做边沿检测）
    output reg  [6:0]  o_sustain,       // 延音踏板 0=关，1..127=释音慢化程度
    // ---- PWM 脉宽调制 ----
    output reg  [7:0]  o_pwm_width,     // 基础占空比 0..255（128=50%）
    output reg  [7:0]  o_pwm_rate,      // 0.1Hz 单位
    output reg  [6:0]  o_pwm_depth,     // 0..127
    // ---- 32 声部齐奏 / 超锯齿 ----
    output reg         o_uni_on,
    output reg  [2:0]  o_uni_layers,    // 1..4（总层数，含主声部）
    output reg  [6:0]  o_uni_detune,    // 0..127
    output reg  [6:0]  o_uni_mix,       // 0..127
    // ---- 32 通道混音台参数（打包，每通道 16 位）----
    output wire [511:0] o_ch_a,         // {dist[7:0], vol[7:0]}
    output wire [511:0] o_ch_b,         // {pha[3:0], cho[3:0], rev[3:0], echo[3:0]}
    // ---- 全局效果 / 均衡参数（0x50..0x6F，每项 16 位）----
    output wire [511:0] o_fx,
    output reg  [3:0]  o_rate,
    output reg  [3:0]  o_exp,
    output reg  [15:0] o_atk,
    output reg  [15:0] o_dec,
    output reg  [15:0] o_sus,
    output reg  [15:0] o_rel,
    output reg  [2:0]  o_mix_shift,
    output reg  [7:0]  o_master,
    output reg         o_mute,
    output wire [63:0] o_key_vol,       // 8 × 8 位（0..128）

    // ---- 状态上报 ----
    output wire [7:0]  o_rx_err,
    output wire [15:0] o_set_cnt
);

    // ============================================================
    // 常量
    // ============================================================
    localparam [7:0]  SOF0 = 8'hA5, SOF1 = 8'h5A;
    localparam [7:0]  T_SET  = 8'h01, T_GET  = 8'h02, T_PING = 8'h03;
    localparam [7:0]  T_VAL  = 8'h81, T_TLM  = 8'h82, T_PONG = 8'h83;

    localparam [7:0]  A_VERSION = 8'h01;
    localparam [7:0]  A_TIMBRE  = 8'h10, A_WAVE  = 8'h11;
    localparam [7:0]  A_PWM_WIDTH = 8'h2D;
    localparam [7:0]  A_PWM_RATE  = 8'h2E;
    localparam [7:0]  A_PWM_DEPTH = 8'h2F;
    localparam [7:0]  A_FMRAT   = 8'h12, A_FMDEP = 8'h13;
    localparam [7:0]  A_H1      = 8'h14, A_H2    = 8'h15;
    localparam [7:0]  A_H3      = 8'h16, A_H4    = 8'h17;
    localparam [7:0]  A_VELPR   = 8'h18, A_ONESH = 8'h19;
    localparam [7:0]  A_MONO    = 8'h1A, A_GLIDE_EN = 8'h1B, A_GLIDE_SH = 8'h1C;
    localparam [7:0]  A_VIB_EN  = 8'h1D, A_VIB_RATE = 8'h1E, A_VIB_DEPTH = 8'h1F;
    localparam [7:0]  A_RATE    = 8'h20, A_EXP   = 8'h21;
    localparam [7:0]  A_ATK     = 8'h22, A_DEC   = 8'h23;
    localparam [7:0]  A_SUS     = 8'h24, A_REL   = 8'h25;
    localparam [7:0]  A_TRANS   = 8'h26;
    localparam [7:0]  A_OCTSET  = 8'h27;   // 八度偏移（有符号 -2..+2）
    localparam [7:0]  A_SUSTAIN = 8'h28;   // 延音踏板 0..127
    localparam [7:0]  A_UNI_ON  = 8'h29, A_UNI_LAYERS = 8'h2A;
    localparam [7:0]  A_UNI_DET = 8'h2B, A_UNI_MIX   = 8'h2C;
    localparam [7:0]  A_FX0     = 8'h50;   // 0x50..0x6F 全局效果 / EQ
    localparam [7:0]  A_CHA0    = 8'h80;   // 0x80..0x9F 通道 A：音量+失真
    localparam [7:0]  A_CHB0    = 8'hA0;   // 0xA0..0xBF 通道 B：4 路发送
    localparam [7:0]  A_MIXSH   = 8'h30, A_MASTER= 8'h31, A_MUTE = 8'h32;
    localparam [7:0]  A_KV0     = 8'h38;   // 0x38..0x3F
    localparam [7:0]  A_ADSVEL  = 8'h40, A_ADSRAW= 8'h41;
    localparam [7:0]  A_POLY    = 8'h42, A_PEAK  = 8'h43;
    localparam [7:0]  A_OCT     = 8'h44, A_KEYS  = 8'h45;
    localparam [7:0]  A_FLAGS   = 8'h46, A_ADSERR= 8'h47;

    localparam [15:0] FW_VERSION = 16'h0101;

    // 接收状态机
    localparam [2:0] RS_H0 = 3'd0, RS_H1 = 3'd1, RS_T = 3'd2,
                     RS_L  = 3'd3, RS_P  = 3'd4, RS_C = 3'd5;

    // 分发/组帧状态机
    localparam [3:0] D_IDLE    = 4'd0,
                     D_APPLY   = 4'd1,
                     D_GET_HDR = 4'd2, D_GET_BYTE = 4'd3, D_GET_CRC = 4'd4,
                     D_PONG_H  = 4'd5, D_PONG_B0  = 4'd6, D_PONG_B1 = 4'd7,
                     D_PONG_CRC= 4'd8,
                     D_TEL_H   = 4'd9, D_TEL_BYTE = 4'd10, D_TEL_CRC = 4'd11,
                     D_GET_LOAD = 4'd12;

    // ============================================================
    // 寄存器（参数本体）
    // ============================================================
    reg [1:0] h1, h2, h3, h4;
    reg [7:0] k0, k1, k2, k3, k4, k5, k6, k7;   // 每键音量 0..128
    // 32 通道混音台 / 32 项全局效果与 EQ 参数
    reg [15:0] ch_a [0:31];
    reg [15:0] ch_b [0:31];
    reg [15:0] fx   [0:31];
    integer    ri;

    reg       load_p;       // 单拍：重新装载当前音色的预设
    reg       wr_en;
    reg [7:0] wr_addr;
    reg [15:0] wr_data;
    reg [7:0] wr_lo;

    // 有符号解释写数据（实时变调是 -12..+12，用补码发下来）
    wire signed [15:0] wd_s = wr_data;

    reg [15:0] set_cnt;

    // 接收
    reg [2:0]  rstate;
    reg [7:0]  rx_type, rx_len;
    reg [5:0]  rx_idx;
    reg [7:0]  crc_acc;
    reg [7:0]  rxbuf [0:47];
    reg [7:0]  rx_err_cnt;
    reg        frame_ok;
    reg [19:0] rx_to;

    // 分发 / 组帧
    reg [3:0]  dstate;
    reg [7:0]  sbuf [0:63];
    reg [7:0]  slen;
    reg        pending;
    reg [7:0]  tidx;
    reg [7:0]  b_crc;
    reg [5:0]  appl_i;
    reg [1:0]  appl_b;
    reg [4:0]  ent_i;
    reg [1:0]  byte_j;
    reg [7:0]  get_addr_r;
    reg [15:0] get_val_r;
    reg [4:0]  tel_i;
    reg [15:0] telem_cnt;
    reg        req_pending;     // 收到的帧还没处理（正在发遥测/回包时先排队）
    reg [21:0] tx_wait;         // pending 卡死看门狗

    // 遥测 / 按键同步
    reg [63:0] snap;
    reg        tt_s1, tt_s2, tt_d;
    reg        kt_s1, kt_s2, kt_d;
    wire       telem_tick = tt_s2 ^ tt_d;
    wire       key_edge   = kt_s2 ^ kt_d;

    // 遥测快照字段
    wire [7:0]        sn_vel  = snap[7:0];
    wire [7:0]        sn_raw  = snap[15:8];
    wire [5:0]        sn_poly = snap[21:16];
    wire [5:0]        sn_peak = snap[27:22];
    wire signed [2:0] sn_oct  = snap[30:28];
    wire [7:0]        sn_keys = snap[38:31];
    wire              sn_ok   = snap[39];
    wire              sn_dbg  = snap[40];
    wire              sn_seen = snap[41];
    wire [7:0]        sn_err  = snap[49:42];

    assign o_key_vol  = {k7, k6, k5, k4, k3, k2, k1, k0};
    assign o_harm_att = {h4, h3, h2, h1};
    assign o_rx_err   = rx_err_cnt;
    assign o_set_cnt  = set_cnt;

    // 把 32 个通道 / 32 项全局参数的寄存器数组打包成总线
    genvar gch;
    generate
        for (gch = 0; gch < 32; gch = gch + 1) begin : g_pack
            assign o_ch_a[gch*16 +: 16] = ch_a[gch];
            assign o_ch_b[gch*16 +: 16] = ch_b[gch];
            assign o_fx  [gch*16 +: 16] = fx[gch];
        end
    endgenerate

    // ============================================================
    // 函数
    // ============================================================
    // CRC8/ATM：poly 0x07, init 0x00
    function [7:0] crc8_step;
        input [7:0] c_in;
        input [7:0] d;
        integer i;
        reg [7:0] c;
        begin
            c = c_in ^ d;
            for (i = 0; i < 8; i = i + 1)
                c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8_step = c;
        end
    endfunction

    // ---- 音色预设（值来自原 top.v 的 localparam，版）----
    // 0 方波 / 1 锯齿 / 2 三角 / 3 正弦：持续音
    // 4 钢琴 / 5 古筝 / 6 木琴：一次包络 7 单簧管：持续音
    function [2:0] f_wave;
        input [3:0] t;
        begin
            case (t)
                3'd0: f_wave = 3'd0;
                3'd1: f_wave = 3'd1;
                3'd2: f_wave = 3'd2;
                3'd3: f_wave = 3'd3;
                3'd4: f_wave = 3'd4;
                default: f_wave = 3'd5;      // 5/6/7 = FM
            endcase
        end
    endfunction

    function [2:0] f_ratio;
        input [3:0] t;
        begin
            case (t)
                3'd5: f_ratio = 3'd1;        // 1.0
                3'd6: f_ratio = 3'd6;        // 3.5
                3'd7: f_ratio = 3'd3;        // 2.0
                4'd8: f_ratio = 3'd3;        // 颠琴 2.0
                4'd9: f_ratio = 3'd6;        // 钟琴 3.5
                default: f_ratio = 3'd1;     // 1.0
            endcase
        end
    endfunction

    function [2:0] f_depth;
        input [3:0] t;
        begin
            case (t)
                3'd5: f_depth = 3'd2;        // 古筝 >>>2
                3'd6: f_depth = 3'd1;        // 木琴 >>>1
                3'd7: f_depth = 3'd3;        // 单簧管 >>>3
                4'd8: f_depth = 3'd2;        // 颠琴
                4'd9: f_depth = 3'd1;        // 钟琴（更亮）
                default: f_depth = 3'd2;
            endcase
        end
    endfunction

    function f_perc;
        input [3:0] t;
        begin
            f_perc = (t == 3'd4) || (t == 3'd5) || (t == 3'd6) ||
                     (t == 4'd8) || (t == 4'd9);
        end
    endfunction

    function [3:0] f_rate;
        input [3:0] t;
        begin
            case (t)
                3'd4: f_rate = 4'd3;
                3'd5: f_rate = 4'd3;
                3'd6: f_rate = 4'd2;
                4'd8: f_rate = 4'd3;        // 颠琴
                4'd9: f_rate = 4'd2;        // 钟琴
                default: f_rate = 4'd0;
            endcase
        end
    endfunction

    function [3:0] f_exp;
        input [3:0] t;
        begin
            case (t)
                3'd4: f_exp = 4'd9;
                3'd5: f_exp = 4'd10;
                3'd6: f_exp = 4'd8;
                4'd8: f_exp = 4'd8;          // 颠琴
                4'd9: f_exp = 4'd9;          // 钟琴
                default: f_exp = 4'd0;
            endcase
        end
    endfunction

    function [15:0] f_atk;
        input [3:0] t;
        begin
            case (t)
                3'd4: f_atk = 16'd4288;
                3'd5: f_atk = 16'd6144;
                3'd6: f_atk = 16'd16384;
                3'd7: f_atk = 16'd33;
                4'd8: f_atk = 16'd2048;      // 颠琴
                4'd9: f_atk = 16'd1024;      // 钟琴
                default: f_atk = 16'd67;
            endcase
        end
    endfunction

    function [15:0] f_dec;
        input [3:0] t;
        begin
            f_dec = (t == 3'd4 || t == 4'd8 || t == 4'd9) ? 16'd1 : 16'd7;
        end
    endfunction

    function [15:0] f_sus;
        input [3:0] t;
        begin
            if (t == 3'd7) f_sus = 16'd45874;
            else if (f_perc(t)) f_sus = 16'd0;
            else f_sus = 16'd45874;
        end
    endfunction

    function [15:0] f_rel;
        input [3:0] t;
        begin
            if (f_perc(t)) f_rel = 16'd4096;
            else if (t == 3'd7) f_rel = 16'd4;
            else f_rel = 16'd4;
        end
    endfunction

    // ---- 读寄存器（GET 用；只读项返回最近一次遥测快照）----
    function [15:0] reg_read;
        input [7:0] a;
        begin
            if (a >= A_FX0 && a <= (A_FX0 + 8'd31))
                reg_read = fx[a - A_FX0];
            else if (a >= A_CHA0 && a <= (A_CHA0 + 8'd31))
                reg_read = ch_a[a - A_CHA0];
            else if (a >= A_CHB0 && a <= (A_CHB0 + 8'd31))
                reg_read = ch_b[a - A_CHB0];
            else case (a)
                A_VERSION: reg_read = FW_VERSION;
                A_TIMBRE : reg_read = {12'd0, o_timbre};
                A_WAVE   : reg_read = {13'd0, o_wave};
                A_FMRAT  : reg_read = {13'd0, o_fm_ratio};
                A_FMDEP  : reg_read = {13'd0, o_fm_depth};
                A_H1     : reg_read = {14'd0, h1};
                A_H2     : reg_read = {14'd0, h2};
                A_H3     : reg_read = {14'd0, h3};
                A_H4     : reg_read = {14'd0, h4};
                A_VELPR  : reg_read = {15'd0, o_vel_press};
                A_ONESH  : reg_read = {15'd0, o_oneshot};
                A_MONO   : reg_read = {15'd0, o_mono};
                A_GLIDE_EN: reg_read = {15'd0, o_glide_en};
                A_GLIDE_SH: reg_read = {12'd0, o_glide_shift};
                A_VIB_EN : reg_read = {15'd0, o_vib_en};
                A_VIB_RATE: reg_read = {8'd0, o_vib_rate};
                A_VIB_DEPTH: reg_read = {9'd0, o_vib_depth};
                A_TRANS  : reg_read = {{10{o_transpose[5]}}, o_transpose};
                A_OCTSET : reg_read = {{13{o_octave[2]}}, o_octave};
                A_SUSTAIN: reg_read = {9'd0, o_sustain};
                A_UNI_ON : reg_read = {15'd0, o_uni_on};
                A_UNI_LAYERS: reg_read = {13'd0, o_uni_layers};
                A_UNI_DET: reg_read = {9'd0, o_uni_detune};
                A_UNI_MIX: reg_read = {9'd0, o_uni_mix};
                A_PWM_WIDTH: reg_read = {8'd0, o_pwm_width};
                A_PWM_RATE : reg_read = {8'd0, o_pwm_rate};
                A_PWM_DEPTH: reg_read = {9'd0, o_pwm_depth};
                A_RATE   : reg_read = {12'd0, o_rate};
                A_EXP    : reg_read = {12'd0, o_exp};
                A_ATK    : reg_read = o_atk;
                A_DEC    : reg_read = o_dec;
                A_SUS    : reg_read = o_sus;
                A_REL    : reg_read = o_rel;
                A_MIXSH  : reg_read = {13'd0, o_mix_shift};
                A_MASTER : reg_read = {8'd0, o_master};
                A_MUTE   : reg_read = {15'd0, o_mute};
                A_KV0 + 8'd0: reg_read = {8'd0, k0};
                A_KV0 + 8'd1: reg_read = {8'd0, k1};
                A_KV0 + 8'd2: reg_read = {8'd0, k2};
                A_KV0 + 8'd3: reg_read = {8'd0, k3};
                A_KV0 + 8'd4: reg_read = {8'd0, k4};
                A_KV0 + 8'd5: reg_read = {8'd0, k5};
                A_KV0 + 8'd6: reg_read = {8'd0, k6};
                A_KV0 + 8'd7: reg_read = {8'd0, k7};
                A_ADSVEL : reg_read = {8'd0, sn_vel};
                A_ADSRAW : reg_read = {8'd0, sn_raw};
                A_POLY   : reg_read = {10'd0, sn_poly};
                A_PEAK   : reg_read = {10'd0, sn_peak};
                A_OCT    : reg_read = {{13{sn_oct[2]}}, sn_oct};
                A_KEYS   : reg_read = {8'd0, sn_keys};
                A_FLAGS  : reg_read = {5'd0, sn_seen, sn_dbg, sn_ok};
                A_ADSERR : reg_read = {8'd0, sn_err};
                default  : reg_read = 16'h0000;
            endcase
        end
    endfunction

    // ---- 遥测字节 ----
    function [7:0] tel_byte;
        input [4:0] i;
        begin
            case (i)
                5'd0 : tel_byte = {4'd0, o_timbre};
                5'd1 : tel_byte = {5'd0, o_wave};
                5'd2 : tel_byte = sn_vel;
                5'd3 : tel_byte = sn_raw;
                5'd4 : tel_byte = {2'd0, sn_poly};
                5'd5 : tel_byte = {2'd0, sn_peak};
                5'd6 : tel_byte = {{5{sn_oct[2]}}, sn_oct};
                5'd7 : tel_byte = sn_keys;
                5'd8 : tel_byte = {5'd0, sn_seen, sn_dbg, sn_ok};
                5'd9 : tel_byte = sn_err;
                5'd10: tel_byte = o_master;
                5'd11: tel_byte = {4'd0, o_mix_shift, o_mute};
                5'd12: tel_byte = set_cnt[7:0];
                5'd13: tel_byte = rx_err_cnt;
                5'd14: tel_byte = telem_cnt[7:0];
                default: tel_byte = telem_cnt[15:8];
            endcase
        end
    endfunction

    // ---- GET 组帧时的取数（要看 reg_read，所以放在函数之后）----
    wire [7:0]  get_addr = rxbuf[ent_i];
    wire [15:0] get_val  = reg_read(get_addr);
    // 用打拍后的 get_addr_r/get_val_r，避免 rxbuf -> reg_read -> sbuf/CRC 一条长组合路径
    wire [7:0]  get_byte = (byte_j == 2'd0) ? get_addr_r :
                           (byte_j == 2'd1) ? get_val_r[7:0] : get_val_r[15:8];

    // ============================================================
    // 1) 接收状态机
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate     <= RS_H0;
            rx_type    <= 8'd0;
            rx_len     <= 8'd0;
            rx_idx     <= 6'd0;
            crc_acc    <= 8'd0;
            rx_err_cnt <= 8'd0;
            frame_ok   <= 1'b0;
            rx_to      <= 20'd0;
        end else begin
            frame_ok <= 1'b0;

            // 帧内 20ms 没收到下一个字节 -> 丢弃，重新找帧头
            if (rstate == RS_H0) begin
                rx_to <= 20'd0;
            end else if (rx_to != 20'd999_999) begin
                rx_to <= rx_to + 20'd1;
            end else begin
                rstate     <= RS_H0;
                rx_to      <= 20'd0;
                rx_err_cnt <= rx_err_cnt + 8'd1;
            end

            if (rx_valid) begin
                case (rstate)
                    RS_H0: begin
                        if (rx_data == SOF0) rstate <= RS_H1;
                    end
                    RS_H1: begin
                        if (rx_data == SOF1)      rstate <= RS_T;
                        else if (rx_data == SOF0) rstate <= RS_H1;
                        else                      rstate <= RS_H0;
                    end
                    RS_T: begin
                        rx_type <= rx_data;
                        crc_acc <= crc8_step(8'd0, rx_data);
                        rstate  <= RS_L;
                    end
                    RS_L: begin
                        rx_len  <= rx_data;
                        crc_acc <= crc8_step(crc_acc, rx_data);
                        rx_idx  <= 6'd0;
                        if (rx_data == 8'd0) begin
                            rstate <= RS_C;              // PING 这类空负载
                        end else if (rx_data <= 8'd48) begin
                            rstate <= RS_P;
                        end else begin
                            rstate     <= RS_H0;
                            rx_err_cnt <= rx_err_cnt + 8'd1;
                        end
                    end
                    RS_P: begin
                        rxbuf[rx_idx] <= rx_data;
                        crc_acc       <= crc8_step(crc_acc, rx_data);
                        if (rx_idx == rx_len - 8'd1) rstate <= RS_C;
                        else                         rx_idx <= rx_idx + 6'd1;
                    end
                    RS_C: begin
                        if (rx_data == crc_acc) frame_ok <= 1'b1;
                        else rx_err_cnt <= rx_err_cnt + 8'd1;
                        rstate <= RS_H0;
                    end
                    default: rstate <= RS_H0;
                endcase
            end
        end
    end

    // ============================================================
    // 2) 分发 / 组帧 / 发送引擎
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dstate    <= D_IDLE;
            wr_en     <= 1'b0;
            wr_addr   <= 8'd0;
            wr_data   <= 16'd0;
            wr_lo     <= 8'd0;
            appl_i    <= 6'd0;
            appl_b    <= 2'd0;
            ent_i     <= 5'd0;
            byte_j    <= 2'd0;
            tel_i     <= 5'd0;
            b_crc     <= 8'd0;
            slen      <= 8'd0;
            pending   <= 1'b0;
            tidx      <= 8'd0;
            tx_data   <= 8'd0;
            tx_send   <= 1'b0;
            telem_cnt <= 16'd0;
            req_pending <= 1'b0;
            tx_wait    <= 22'd0;
        end else begin
            tx_send <= 1'b0;      // 默认不发送
            wr_en   <= 1'b0;      // 默认不写寄存器

            // 收到一帧就记一笔：正在发遥测/回包时先排队，
            // 等总线空了再执行（否则用户点一下按钮刚好撞上遥测，命令就丢了）
            if (frame_ok) req_pending <= 1'b1;

            // pending 看门狗：若 84ms 没有任何字节发出，强制释放总线，
            // 防止某个坏 GET/回包把遥测和 PING 永久堵死。
            if (!pending) begin
                tx_wait <= 22'd0;
            end else if (tx_send) begin
                tx_wait <= 22'd0;
            end else if (tx_wait == 22'h3FFFFF) begin
                pending <= 1'b0;
                tidx    <= 8'd0;
                dstate  <= D_IDLE;
                tx_wait <= 22'd0;
            end else begin
                tx_wait <= tx_wait + 22'd1;
            end

            // ---------- 发送引擎：uart_tx 空闲就喂一个字节 ----------
            if (pending && !tx_busy && (tidx < slen)) begin
                tx_data <= sbuf[tidx];
                tx_send <= 1'b1;
                tidx    <= tidx + 8'd1;
                if (tidx + 8'd1 == slen) pending <= 1'b0;
            end

            // ---------- 分发 ----------
            case (dstate)
                D_IDLE: begin
                    if ((frame_ok || req_pending) && !pending) begin
                        req_pending <= 1'b0;
                        if (rx_type == T_SET && rx_len >= 8'd3) begin
                            appl_i <= 6'd0;
                            appl_b <= 2'd0;
                            dstate <= D_APPLY;
                        end else if (rx_type == T_GET && rx_len >= 8'd1 && rx_len <= 8'd16) begin
                            ent_i  <= 5'd0;
                            byte_j <= 2'd0;
                            dstate <= D_GET_HDR;
                        end else if (rx_type == T_PING) begin
                            dstate <= D_PONG_H;
                        end else begin
                            // 帧格式不支持 / 长度越界：直接丢掉（不额外计数，避免和接收计数器抢驱动）
                            dstate <= D_IDLE;
                        end
                    end else if (telem_tick && !pending) begin
                        tel_i  <= 5'd0;
                        dstate <= D_TEL_H;
                    end
                end

                // ---- SET：三个字节一条，写寄存器 ----
                D_APPLY: begin
                    case (appl_b)
                        2'd0: begin
                            if (appl_i + 6'd3 <= rx_len) begin
                                wr_addr <= rxbuf[appl_i];
                                appl_i  <= appl_i + 6'd1;
                                appl_b  <= 2'd1;
                            end else begin
                                dstate <= D_IDLE;
                            end
                        end
                        2'd1: begin
                            wr_lo  <= rxbuf[appl_i];
                            appl_i <= appl_i + 6'd1;
                            appl_b <= 2'd2;
                        end
                        default: begin
                            wr_data <= {rxbuf[appl_i], wr_lo};
                            wr_en   <= 1'b1;
                            appl_i  <= appl_i + 6'd1;
                            appl_b  <= 2'd0;
                            if (appl_i + 6'd1 >= rx_len) dstate <= D_IDLE;
                        end
                    endcase
                end

                // ---- GET：组 VALUE 帧 ----
                D_GET_HDR: begin
                    if (!pending) begin
                        sbuf[0] <= SOF0;
                        sbuf[1] <= SOF1;
                        sbuf[2] <= T_VAL;
                        sbuf[3] <= rx_len * 8'd3;
                        b_crc   <= crc8_step(crc8_step(8'd0, T_VAL), rx_len * 8'd3);
                        ent_i   <= 5'd0;
                        byte_j  <= 2'd0;
                        dstate  <= D_GET_LOAD;
                    end
                end
                // 先花一拍把地址/数值打进寄存器，切断 reg_read 的长组合路径
                D_GET_LOAD: begin
                    if (!pending) begin
                        get_addr_r <= rxbuf[ent_i];
                        get_val_r  <= reg_read(rxbuf[ent_i]);
                        byte_j     <= 2'd0;
                        dstate     <= D_GET_BYTE;
                    end
                end
                D_GET_BYTE: begin
                    if (!pending) begin
                        sbuf[4 + ent_i * 3 + byte_j] <= get_byte;
                        b_crc <= crc8_step(b_crc, get_byte);
                        if (byte_j == 2'd2) begin
                            byte_j <= 2'd0;
                            if (ent_i + 5'd1 == rx_len) dstate <= D_GET_CRC;
                            else begin
                                ent_i  <= ent_i + 5'd1;
                                dstate <= D_GET_LOAD;
                            end
                        end else begin
                            byte_j <= byte_j + 2'd1;
                        end
                    end
                end
                D_GET_CRC: begin
                    sbuf[4 + rx_len * 3] <= b_crc;
                    slen    <= 8'd5 + rx_len * 8'd3;
                    pending <= 1'b1;
                    tidx    <= 8'd0;
                    dstate  <= D_IDLE;
                end

                // ---- PING -> PONG ----
                D_PONG_H: begin
                    if (!pending) begin
                        sbuf[0] <= SOF0;
                        sbuf[1] <= SOF1;
                        sbuf[2] <= T_PONG;
                        sbuf[3] <= 8'd2;
                        b_crc   <= crc8_step(crc8_step(8'd0, T_PONG), 8'd2);
                        dstate  <= D_PONG_B0;
                    end
                end
                D_PONG_B0: begin
                    sbuf[4] <= 8'h01;
                    b_crc   <= crc8_step(b_crc, 8'h01);
                    dstate  <= D_PONG_B1;
                end
                D_PONG_B1: begin
                    sbuf[5] <= 8'h01;
                    b_crc   <= crc8_step(b_crc, 8'h01);
                    dstate  <= D_PONG_CRC;
                end
                D_PONG_CRC: begin
                    sbuf[6] <= b_crc;
                    slen    <= 8'd7;
                    pending <= 1'b1;
                    tidx    <= 8'd0;
                    dstate  <= D_IDLE;
                end

                // ---- 遥测：16 字节 ----
                D_TEL_H: begin
                    if (!pending) begin
                        sbuf[0] <= SOF0;
                        sbuf[1] <= SOF1;
                        sbuf[2] <= T_TLM;
                        sbuf[3] <= 8'd16;
                        b_crc   <= crc8_step(crc8_step(8'd0, T_TLM), 8'd16);
                        tel_i   <= 5'd0;
                        dstate  <= D_TEL_BYTE;
                    end
                end
                D_TEL_BYTE: begin
                    if (!pending) begin
                        sbuf[4 + tel_i] <= tel_byte(tel_i);
                        b_crc <= crc8_step(b_crc, tel_byte(tel_i));
                        if (tel_i == 5'd15) dstate <= D_TEL_CRC;
                        else                tel_i  <= tel_i + 5'd1;
                    end
                end
                D_TEL_CRC: begin
                    sbuf[20]  <= b_crc;
                    slen      <= 8'd21;
                    pending   <= 1'b1;
                    tidx      <= 8'd0;
                    telem_cnt <= telem_cnt + 16'd1;
                    dstate    <= D_IDLE;
                end

                default: dstate <= D_IDLE;
            endcase
        end
    end

    // ============================================================
    // 3) 参数寄存器 + 预设装载
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_timbre    <= 4'd1;
            o_wave      <= 3'd1;
            o_fm_ratio  <= 3'd1;
            o_fm_depth  <= 3'd2;
            h1 <= 2'd0; h2 <= 2'd0; h3 <= 2'd0; h4 <= 2'd0;
            o_vel_press <= 1'b0;
            o_oneshot   <= 1'b0;
            o_mono      <= 1'b0;
            o_glide_en  <= 1'b0;
            o_glide_shift <= 4'd10;      // τ ≈ 21ms
            o_vib_en    <= 1'b0;
            o_vib_rate  <= 8'd55;        // 5.5 Hz
            o_vib_depth <= 7'd40;        // ≈ ±33 音分
            o_transpose <= 6'sd0;
            o_octave    <= 3'sd0;
            o_oct_tog   <= 1'b0;
            o_sustain   <= 7'd40;   // 默认给钢琴类一个约 0.5s 的拖尾，可调到 0 关闭
    o_pwm_width <= 8'd128;  // 50% 占空比
    o_pwm_rate  <= 8'd30;   // 3.0Hz
    o_pwm_depth <= 7'd96;   // 默认有较明显的脉宽调制
            o_uni_on    <= 1'b1;    // 默认打开 32 声部齐奏（可关）
            o_uni_layers<= 3'd4;    // 8 键 × 4 层 = 32
            o_uni_detune<= 7'd64;   // ≈1.56%
            o_uni_mix   <= 7'd100;   // ≈79% 附加层
            o_rate      <= 4'd0;
            o_exp       <= 4'd0;
            o_atk       <= 16'd67;
            o_dec       <= 16'd7;
            o_sus       <= 16'd45874;
            o_rel       <= 16'd4;
            o_mix_shift <= 3'd2;
            o_master    <= 8'd255;
            o_mute      <= 1'b0;
            k0 <= 8'd128; k1 <= 8'd128; k2 <= 8'd128; k3 <= 8'd128;
            k4 <= 8'd128; k5 <= 8'd128; k6 <= 8'd128; k7 <= 8'd128;

            // 通道条出厂值：音量 128、失真 0、4 路发送 0
            for (ri = 0; ri < 32; ri = ri + 1) begin
                ch_a[ri] <= {8'd0, 8'd128};
                ch_b[ri] <= 16'd0;
            end
            // 全局效果 / EQ 出厂值（下标 0..31 对应 0x50..0x6F）
            fx[0]  <= 16'd0;     // ECHO_ON
            fx[1]  <= 16'd110;   // ECHO_TIME
            fx[2]  <= 16'd6;     // ECHO_FB
            fx[3]  <= 16'd64;    // ECHO_MIX
            fx[4]  <= 16'd0;     // REV_ON
            fx[5]  <= 16'd64;    // REV_SIZE
            fx[6]  <= 16'd64;    // REV_DAMP
            fx[7]  <= 16'd64;    // REV_MIX
            fx[8]  <= 16'd0;     // CHO_ON
            fx[9]  <= 16'd40;    // CHO_RATE
            fx[10] <= 16'd40;    // CHO_DEPTH
            fx[11] <= 16'd64;    // CHO_MIX
            fx[12] <= 16'd0;     // PHA_ON
            fx[13] <= 16'd40;    // PHA_RATE
            fx[14] <= 16'd40;    // PHA_DEPTH
            fx[15] <= 16'd4;     // PHA_FB
            fx[16] <= 16'd64;    // PHA_MIX
            fx[17] <= 16'd0;     // DRV_ON
            fx[18] <= 16'd0;     // DRV_DRIVE
            fx[19] <= 16'd64;    // DRV_TONE
            fx[20] <= 16'd64;    // DRV_MIX
            fx[21] <= 16'd1;     // LIM_ON
            fx[22] <= 16'd224;   // LIM_TH
            fx[23] <= 16'd255;   // LIM_CEIL
            fx[24] <= 16'd64;    // LIM_REL
            fx[25] <= 16'd1;     // EQ_ON
            fx[26] <= 16'd16;    // EQ_LOW
            fx[27] <= 16'd16;    // EQ_LMID
            fx[28] <= 16'd16;    // EQ_MID
            fx[29] <= 16'd16;    // EQ_HMID
            fx[30] <= 16'd16;    // EQ_HIGH
            fx[31] <= 16'd255;   // EQ_OUT
            load_p  <= 1'b1;      // 复位后自动装一次预设
            set_cnt <= 16'd0;
        end else begin
            load_p <= 1'b0;

            // ---- 预设装载（放最前面，后面的单参数写入可以覆盖它）----
            if (load_p) begin
                o_wave      <= f_wave(o_timbre);
                o_fm_ratio  <= f_ratio(o_timbre);
                o_fm_depth  <= f_depth(o_timbre);
                h1 <= 2'd0; h2 <= 2'd0; h3 <= 2'd0; h4 <= 2'd0;
                o_vel_press <= f_perc(o_timbre);
                o_oneshot   <= f_perc(o_timbre);
                o_rate      <= f_rate(o_timbre);
                o_exp       <= f_exp(o_timbre);
                o_atk       <= f_atk(o_timbre);
                o_dec       <= f_dec(o_timbre);
                o_sus       <= f_sus(o_timbre);
                o_rel       <= f_rel(o_timbre);
            end

            // ---- KEY0 短按：换音色号，下一拍装预设 ----
            if (key_edge) begin
                o_timbre <= key_timbre_val;
                load_p   <= 1'b1;
            end

            // ---- 串口写入 ----
            if (wr_en) begin
                set_cnt <= set_cnt + 16'd1;
                if (wr_addr >= A_FX0 && wr_addr <= (A_FX0 + 8'd31)) begin
                    // 0x50..0x6F：全局效果 / EQ（模块内部按位宽截取/钳位）
                    fx[wr_addr - A_FX0] <= wr_data;
                end else if (wr_addr >= A_CHA0 && wr_addr <= (A_CHA0 + 8'd31)) begin
                    // 0x80..0x9F：{dist[15:8], vol[7:0]}；音量钳到 128
                    ch_a[wr_addr - A_CHA0] <= {wr_data[15:8],
                        (wr_data[7:0] > 8'd128) ? 8'd128 : wr_data[7:0]};
                end else if (wr_addr >= A_CHB0 && wr_addr <= (A_CHB0 + 8'd31)) begin
                    // 0xA0..0xBF：4 路发送，每路 4 位
                    ch_b[wr_addr - A_CHB0] <= wr_data;
                end else case (wr_addr)
                    A_TIMBRE: begin
                        o_timbre <= (wr_data > 16'd9) ? 4'd1 : wr_data[3:0];
                        load_p   <= 1'b1;
                    end
                    A_WAVE:   o_wave     <= (wr_data > 16'd5) ? 3'd1 : wr_data[2:0];
                    A_FMRAT:  o_fm_ratio <= (wr_data > 16'd7) ? 3'd1 : wr_data[2:0];
                    A_FMDEP:  o_fm_depth <= (wr_data > 16'd4) ? 3'd2 : wr_data[2:0];
                    A_H1:     h1 <= (wr_data > 16'd2) ? 2'd3 : wr_data[1:0];
                    A_H2:     h2 <= (wr_data > 16'd2) ? 2'd3 : wr_data[1:0];
                    A_H3:     h3 <= (wr_data > 16'd2) ? 2'd3 : wr_data[1:0];
                    A_H4:     h4 <= (wr_data > 16'd2) ? 2'd3 : wr_data[1:0];
                    A_VELPR:  o_vel_press <= wr_data[0];
                    A_ONESH:  o_oneshot   <= wr_data[0];
                    A_MONO:   o_mono      <= wr_data[0];
                    A_GLIDE_EN: o_glide_en <= wr_data[0];
                    A_GLIDE_SH: o_glide_shift <= (wr_data > 16'd15) ? 4'd15 : wr_data[3:0];
                    A_VIB_EN: o_vib_en    <= wr_data[0];
                    A_VIB_RATE: o_vib_rate <= wr_data[7:0];
                    A_VIB_DEPTH: o_vib_depth <= (wr_data > 16'd127) ? 7'd127 : wr_data[6:0];
                    A_TRANS:  o_transpose <= (wd_s > 16'sd12)  ? 6'sd12 :
                                             (wd_s < -16'sd12) ? -6'sd12 : wd_s[5:0];
                    A_OCTSET: begin
                        o_octave <= (wd_s > 16'sd2)  ? 3'sd2 :
                                    (wd_s < -16'sd2) ? -3'sd2 : wd_s[2:0];
                        // 即使写的是同一个值也要翻转，保证"点一下就能回正"
                        o_oct_tog <= ~o_oct_tog;
                    end
                    A_SUSTAIN: o_sustain <= (wr_data > 16'd127) ? 7'd127 : wr_data[6:0];
                    A_UNI_ON: o_uni_on <= wr_data[0];
                    A_UNI_LAYERS: o_uni_layers <= (wr_data < 16'd1) ? 3'd1 :
                                                  (wr_data > 16'd4) ? 3'd4 : wr_data[2:0];
                    A_UNI_DET: o_uni_detune <= (wr_data > 16'd127) ? 7'd127 : wr_data[6:0];
                    A_UNI_MIX: o_uni_mix <= (wr_data > 16'd127) ? 7'd127 : wr_data[6:0];
                A_PWM_WIDTH: o_pwm_width <= wr_data[7:0];
                A_PWM_RATE : o_pwm_rate  <= (wr_data > 16'd127) ? 8'd127 : wr_data[7:0];
                A_PWM_DEPTH: o_pwm_depth <= (wr_data > 16'd127) ? 7'd127 : wr_data[6:0];
                    A_RATE:   o_rate <= (wr_data > 16'd4) ? 4'd4 : wr_data[3:0];
                    A_EXP:    o_exp  <= (wr_data > 16'd15) ? 4'd15 : wr_data[3:0];
                    A_ATK:    o_atk  <= (wr_data == 16'd0) ? 16'd1 : wr_data;
                    A_DEC:    o_dec  <= wr_data;
                    A_SUS:    o_sus  <= wr_data;
                    A_REL:    o_rel  <= wr_data;
                    A_MIXSH:  o_mix_shift <= (wr_data > 16'd6) ? 3'd6 : wr_data[2:0];
                    A_MASTER: o_master <= wr_data[7:0];
                    A_MUTE:   o_mute   <= wr_data[0];
                    A_KV0 + 8'd0: k0 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    A_KV0 + 8'd1: k1 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    A_KV0 + 8'd2: k2 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    A_KV0 + 8'd3: k3 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    A_KV0 + 8'd4: k4 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    A_KV0 + 8'd5: k5 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    A_KV0 + 8'd6: k6 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    A_KV0 + 8'd7: k7 <= (wr_data > 16'd128) ? 8'd128 : wr_data[7:0];
                    default: ;   // 只读/保留地址：忽略
                endcase
            end
        end
    end

    // ============================================================
    // 4) 跨时钟域同步：按键请求 / 遥测快照
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kt_s1 <= 1'b0; kt_s2 <= 1'b0; kt_d <= 1'b0;
            tt_s1 <= 1'b0; tt_s2 <= 1'b0; tt_d <= 1'b0;
            snap  <= 64'd0;
        end else begin
            kt_s1 <= key_timbre_tog;
            kt_s2 <= kt_s1;
            kt_d  <= kt_s2;

            tt_s1 <= telem_tog;
            tt_s2 <= tt_s1;
            tt_d  <= tt_s2;

            if (tt_s2 ^ tt_d) snap <= telem_snap;
        end
    end

endmodule
