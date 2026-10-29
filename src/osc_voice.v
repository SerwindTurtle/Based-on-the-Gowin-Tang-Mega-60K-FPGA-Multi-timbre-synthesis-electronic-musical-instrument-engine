// ============================================================
// osc_voice.v - 单声部振荡器 + ADSR
//
// 24 位相位累加器，wave_sel 选择方波/锯齿/三角/正弦/钢琴/FM。
// pcm = wave * env * vel >> 23，16 位有符号输出。
// ============================================================

module osc_voice #(
    parameter PHASE_BITS = 24
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,     // 采样率使能
    // ---- 来自 voice_alloc 的该声部信息 ----
    input  wire [6:0]         note,          // 音符号 0~127
    input  wire               gate,          // 开关
    input  wire [6:0]         velocity,      // 力度 0~127
    // ---- 波形选择与 ADSR 参数 ----
    //  必须是 3 位：值为 4 表示"钢琴"（单查表 + 波形整形）
    input  wire [2:0]         wave_sel,
    // FM 调制比 / 调制深度 / 钢琴泛音衰减（都来自 param_regs）
    input  wire [2:0]         fm_ratio,      // 0:0.5 1:1.0 2:1.5 3:2.0 4:2.5 5:3.0 6:3.5 7:4.0
    input  wire [2:0]         fm_depth,      // 调制深度 = m_ext >>> fm_depth
    input  wire [7:0]         harm_att,      // 4 个泛音各 2 位衰减：[1:0]基波 … [7:6]四次
    // 演奏效果
    input  wire               glide_en,      // 1 = 滑音
    input  wire [3:0]         glide_shift,   // 滑音速率：每拍逼近差值的 1/2^N
    input  wire [7:0]         vib_delta,     // 全局 LFO 的颤音调制量（带符号，-127..127）
    // PWM 脉宽调制（只作用在方波档）
    input  wire [7:0]         pwm_width,     // 基础占空比 0..255
    input  wire signed [7:0]  pwm_mod,       // 全局 PWM LFO（-127..127）
    input  wire [6:0]         pwm_depth,     // 调制深度 0..127
    input  wire [3:0]         env_rate,      // 包络速率分频（0=最快；钢琴用大值拉长尾音）
    input  wire [3:0]         env_exp,       // 衰减曲线：0=线性，>0=指数（先快后慢）
    input  wire               env_oneshot,   // 1 = 衰减到 0 自终止（钢琴这类打击音色）
    // 延音踏板
    input  wire               pedal_en,
    input  wire [15:0]        pedal_step,
    input  wire [15:0]        atk_step,      // 起音步长
    input  wire [15:0]        dec_step,      // 衰减步长（线性模式用）
    input  wire [15:0]        sus_level,     // 延音电平
    input  wire [15:0]        rel_step,      // 释音步长
    // ---- 输出 ----
    output wire signed [15:0] pcm,           // PCM 采样值
    output wire [15:0]        env_out,       // 调试用：包络值
    output wire               env_active,    // 包络是否还在工作
    output wire [23:0]        inc_out        // 当前相位增量（给 32 声部齐奏用）
);

    // ============================================================
    // 1) 音符号 -> 八度 / 半音
    // ============================================================
    reg [3:0] oct, sem;
    always @(*) begin
        if      (note >= 7'd120) begin oct = 4'd10; sem = note - 7'd120; end
        else if (note >= 7'd108) begin oct = 4'd9;  sem = note - 7'd108; end
        else if (note >= 7'd96 ) begin oct = 4'd8;  sem = note - 7'd96 ; end
        else if (note >= 7'd84 ) begin oct = 4'd7;  sem = note - 7'd84 ; end
        else if (note >= 7'd72 ) begin oct = 4'd6;  sem = note - 7'd72 ; end
        else if (note >= 7'd60 ) begin oct = 4'd5;  sem = note - 7'd60 ; end
        else if (note >= 7'd48 ) begin oct = 4'd4;  sem = note - 7'd48 ; end
        else if (note >= 7'd36 ) begin oct = 4'd3;  sem = note - 7'd36 ; end
        else if (note >= 7'd24 ) begin oct = 4'd2;  sem = note - 7'd24 ; end
        else if (note >= 7'd12 ) begin oct = 4'd1;  sem = note - 7'd12 ; end
        else                     begin oct = 4'd0;  sem = note;          end
    end

    // ============================================================
    // 2) 半音 -> 基准相位增量（note 60~71 这一个八度）
    // inc = 频率 x 2^24 / 48828.125
    // ============================================================
    reg [23:0] base_inc;
    always @(*) begin
        case (sem)
            4'd0  : base_inc = 24'd89894;
            4'd1  : base_inc = 24'd95239;
            4'd2  : base_inc = 24'd100902;
            4'd3  : base_inc = 24'd106902;
            4'd4  : base_inc = 24'd113259;
            4'd5  : base_inc = 24'd119994;
            4'd6  : base_inc = 24'd127129;
            4'd7  : base_inc = 24'd134689;
            4'd8  : base_inc = 24'd142698;
            4'd9  : base_inc = 24'd151183;
            4'd10 : base_inc = 24'd160173;
            4'd11 : base_inc = 24'd169697;
            default: base_inc = 24'd89897;
        endcase
    end

    // ============================================================
    // 3) 八度移位：oct=5 时不移，每高一个八度 x2，低一个八度 /2
    // ============================================================
    wire [23:0] inc_std = (oct >= 4'd5) ? (base_inc << (oct - 4'd5))
                                        : (base_inc >> (4'd5 - oct));

    // 钢琴档（wave_sel=4）必须把增量减半，否则音高会翻一倍。
    // 原因：钢琴波形是用"半角"算的（u=sin(θ/2)、v=cos(θ/2)），
    // 一个真实周期对应 θ 从 0 走到 2π，也就是 phase 要转两圈才响一个周期。
    // 不减半的后果：本该 C5 的音会变成高八度的 C6。
    // 注意用移位而不是 "/2"：除法会被综合成除法器，白吃资源。
    wire [23:0] inc_target = (wave_sel == 3'd4) ? (inc_std >> 1) : inc_std;

    // ============================================================
    // 3.5) 滑音（portamento）：把相位增量"慢慢"逼近目标值
    // ============================================================
    // 滑音作用在相位增量上的原因：
    // 增量直接决定频率，省掉查表；指数逼近听感就是"先快后慢"的滑音。
    // 触键时：
    // - 滑音关闭 / 第一次发声 -> 直接跳到目标（不然会从 0Hz 扫上来）
    // - 滑音打开且已经发过音 -> 保留上一个音高，next几拍慢慢滑过去
    // 单音模式里"按住一个键再按另一个键"时 gate 一直为高，
    // 音符号变了但不会触键 -> 就是"实时变调 + 滑音"。
    reg  [23:0] inc_cur;
    reg         glide_started;
    reg         gate_d;

    wire [24:0] glide_diff = (inc_target >= inc_cur)
                           ? ({1'b0, inc_target} - {1'b0, inc_cur})
                           : ({1'b0, inc_cur} - {1'b0, inc_target});
    wire [24:0] glide_step_raw = glide_diff >>> glide_shift;
    // 至少走 1，否则位移太大时会永远差一点点、音高不准
    wire [23:0] glide_step = (glide_step_raw == 25'd0) ? 24'd1 : glide_step_raw[23:0];
    wire        glide_up   = (inc_target >= inc_cur);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inc_cur       <= 24'd0;
            glide_started <= 1'b0;
        end else if (sample_en) begin
            if (gate & ~gate_d) begin
                if (!glide_en || !glide_started)
                    inc_cur <= inc_target;          // 第一次 / 关闭滑音：直接到位
                glide_started <= 1'b1;
            end else if (!glide_en) begin
                inc_cur <= inc_target;
            end else if (inc_cur != inc_target) begin
                inc_cur <= glide_up ? (inc_cur + glide_step)
                                    : (inc_cur - glide_step);
            end
        end
    end

    // ============================================================
    // 3.6) 颤音：在相位增量上乘一个很小的带符号调制量
    // ============================================================
    // delta 来自全局 LFO（-127..+127），
    // inc_vib = inc_cur + (inc_cur * delta >>> 11)
    // delta=127 时频率偏 ±6.2%（约 ±104 音分）。
    // 因为乘的是"当前增量"，所以低音和高音的音分深度一致。
    wire signed [7:0]  vib_s   = vib_delta;
    wire signed [31:0] vib_mul = $signed({8'd0, inc_cur}) * vib_s;
    wire signed [23:0] inc_vib = $signed({1'b0, inc_cur}) + (vib_mul >>> 11);

    // ============================================================
    // 4) 相位累加器（note_on 时相位归零，避免各声部相位混乱）
    // ============================================================
    reg [PHASE_BITS-1:0] phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase  <= {PHASE_BITS{1'b0}};
            gate_d <= 1'b0;
        end else if (sample_en) begin
            gate_d <= gate;
            if (gate & ~gate_d)
                phase <= {PHASE_BITS{1'b0}};      // 新音符：相位归零
            else if (gate)
                phase <= phase + inc_vib;         // 按下期间累加（含滑音/颤音）
        end
    end

    // ============================================================
    // 5) 波形
    // ============================================================
    wire [15:0] ph16 = phase[PHASE_BITS-1 -: 16];

    // 方波/PWM：占空比 = 基础宽度 + LFO 深度（全部用移位，不占 DSP）
    // pwm_depth[6:4] 选 0..7 档，最大档直接让 LFO 摆到 ±127。
    reg signed [8:0] pwm_off;
    always @(*) begin
        case (pwm_depth[6:4])
            3'd0: pwm_off = 9'sd0;
            3'd1: pwm_off = $signed(pwm_mod) >>> 4;
            3'd2: pwm_off = $signed(pwm_mod) >>> 3;
            3'd3: pwm_off = $signed(pwm_mod) >>> 2;
            3'd4: pwm_off = $signed(pwm_mod) >>> 1;
            default: pwm_off = $signed(pwm_mod);
        endcase
    end
    wire signed [9:0] duty_s = $signed({1'b0, pwm_width}) + pwm_off;
    wire [7:0] duty = (duty_s < 10'sd8)   ? 8'd8 :
                      (duty_s > 10'sd247) ? 8'd247 : duty_s[7:0];
    wire signed [15:0] w_sqr = (phase[PHASE_BITS-1 -: 8] < duty) ? 16'sh7FFF : 16'sh8001;

    // 锯齿：高 16 位做偏移二进制
    wire signed [15:0] w_saw = ph16 ^ 16'h8000;

    // 三角：前半周期上升，后半周期下降
    wire [15:0]        tri_p = {ph16[14:0], 1'b0};
    wire [15:0]        tri_x = phase[PHASE_BITS-1] ? (16'hFFFF - tri_p) : tri_p;
    wire signed [15:0] w_tri = tri_x ^ 16'h8000;

    // ------------------------------------------------------------
    // 正弦查表：8 位精度的 65 点四分之一波 + 象限镜像（等效 256 点）
    // ssin8[i] = round(127 * sin(i*pi/128))，i = 0..64
    // idx[7:6]=象限，idx[5]=0/1 区分上升/下降半象限，idx[6] 决定正负
    // 8 位精度对音频足够（16 位输出时量化噪声 ≈ -48dB，被包络和混音掩盖）
    // ------------------------------------------------------------
    function signed [7:0] ssin8;
        input [7:0] idx;                    // 256 点相位索引（一个整周期）
        reg [7:0] m;                        // 幅度 0..127
        begin
            m = idx[5] ? (8'd64 - {3'b0, idx[4:0]}) : {3'b0, idx[4:0]};
            case (m)
                8'd0 : ssin8 = 8'sd0;
                8'd1 : ssin8 = 8'sd3;
                8'd2 : ssin8 = 8'sd6;
                8'd3 : ssin8 = 8'sd9;
                8'd4 : ssin8 = 8'sd13;
                8'd5 : ssin8 = 8'sd16;
                8'd6 : ssin8 = 8'sd19;
                8'd7 : ssin8 = 8'sd22;
                8'd8 : ssin8 = 8'sd25;
                8'd9 : ssin8 = 8'sd28;
                8'd10: ssin8 = 8'sd31;
                8'd11: ssin8 = 8'sd34;
                8'd12: ssin8 = 8'sd37;
                8'd13: ssin8 = 8'sd40;
                8'd14: ssin8 = 8'sd43;
                8'd15: ssin8 = 8'sd46;
                8'd16: ssin8 = 8'sd49;
                8'd17: ssin8 = 8'sd52;
                8'd18: ssin8 = 8'sd55;
                8'd19: ssin8 = 8'sd58;
                8'd20: ssin8 = 8'sd60;
                8'd21: ssin8 = 8'sd63;
                8'd22: ssin8 = 8'sd66;
                8'd23: ssin8 = 8'sd69;
                8'd24: ssin8 = 8'sd71;
                8'd25: ssin8 = 8'sd74;
                8'd26: ssin8 = 8'sd76;
                8'd27: ssin8 = 8'sd79;
                8'd28: ssin8 = 8'sd81;
                8'd29: ssin8 = 8'sd84;
                8'd30: ssin8 = 8'sd86;
                8'd31: ssin8 = 8'sd88;
                8'd32: ssin8 = 8'sd90;
                8'd33: ssin8 = 8'sd93;
                8'd34: ssin8 = 8'sd95;
                8'd35: ssin8 = 8'sd97;
                8'd36: ssin8 = 8'sd99;
                8'd37: ssin8 = 8'sd101;
                8'd38: ssin8 = 8'sd103;
                8'd39: ssin8 = 8'sd105;
                8'd40: ssin8 = 8'sd106;
                8'd41: ssin8 = 8'sd108;
                8'd42: ssin8 = 8'sd110;
                8'd43: ssin8 = 8'sd111;
                8'd44: ssin8 = 8'sd113;
                8'd45: ssin8 = 8'sd114;
                8'd46: ssin8 = 8'sd116;
                8'd47: ssin8 = 8'sd117;
                8'd48: ssin8 = 8'sd118;
                8'd49: ssin8 = 8'sd119;
                8'd50: ssin8 = 8'sd121;
                8'd51: ssin8 = 8'sd122;
                8'd52: ssin8 = 8'sd122;
                8'd53: ssin8 = 8'sd123;
                8'd54: ssin8 = 8'sd124;
                8'd55: ssin8 = 8'sd125;
                8'd56: ssin8 = 8'sd125;
                8'd57: ssin8 = 8'sd126;
                8'd58: ssin8 = 8'sd126;
                8'd59: ssin8 = 8'sd127;
                8'd60: ssin8 = 8'sd127;
                8'd61: ssin8 = 8'sd127;
                8'd62: ssin8 = 8'sd127;
                8'd63: ssin8 = 8'sd127;
                8'd64: ssin8 = 8'sd127;
                default: ssin8 = 8'sd0;
            endcase
            // idx[6] = 1 表示处于波形的下半周期 -> 取负
            if (idx[6]) ssin8 = -ssin8;
        end
    endfunction

    // 基波
    wire signed [7:0] s_f = ssin8(phase[PHASE_BITS-1 -: 8]);

    // ------------------------------------------------------------
    // FM 合成（wave_sel = 5 / 6 / 7）
    // ------------------------------------------------------------
    // 经典 2 算子 FM：
    // 载波相位 += inc
    // 调制相位 += inc * ratio
    // 输出 = sin(载波相位 + depth * sin(调制相位))
    //
    // ratio（调制器/载波频率比）决定谐波结构，也就是"像什么乐器"：
    // ratio = 1（整数） -> 频谱是完整的谐波列，像拨弦/管乐
    // ratio = 2（整数） -> 只剩奇次谐波，中空感 = 单簧管那类圆管乐器
    // ratio = 3.5（非整数）-> 谐波不成整数倍，发出金属/木质的"铛"声
    //
    // depth（调制深度）决定亮度：越深高次边带越多，音色越亮越"刺"。
    //  这里全部用移位实现，不引入乘法器 --
    // 32 个声部各加一个乘法器会直接把 DSP 撑爆（当前已用 62%）。
    //
    // 三个音色：
    // 5 古筝 : ratio 1.0 depth >>>2 谐波丰富、拨弦感
    // 6 木琴 : ratio 3.5 depth >>>1 非谐分音、敲击感
    // 7 单簧管: ratio 2.0 depth >>>3 奇次谐波、圆润
    // ------------------------------------------------------------

    // 调制器相位增量（ratio 用移位/加法凑，避免除法器/乘法器）
    // ratio 由 param_regs 的 FM_RATIO 决定（默认：古筝 1.0 / 木琴 3.5 / 单簧管 2.0）
    // 原来这里是把 ratio 写死在 wave_sel 的三元表达式里，
    // 现在改成"8 档可选"，全部用移位+加法实现，不额外占 DSP。
    // 0:0.5 1:1.0 2:1.5 3:2.0 4:2.5 5:3.0 6:3.5 7:4.0
    reg [23:0] mod_inc;
    always @(*) begin
        case (fm_ratio)
            3'd0: mod_inc = {1'b0, inc_vib[23:1]};                        // 0.5
            3'd1: mod_inc = inc_vib;                                      // 1.0
            3'd2: mod_inc = inc_vib + {1'b0, inc_vib[23:1]};              // 1.5
            3'd3: mod_inc = inc_vib << 1;                                 // 2.0
            3'd4: mod_inc = (inc_vib << 1) + {1'b0, inc_vib[23:1]};       // 2.5
            3'd5: mod_inc = (inc_vib << 1) + inc_vib;                     // 3.0
            3'd6: mod_inc = (inc_vib << 1) + inc_vib + {1'b0, inc_vib[23:1]}; // 3.5
            default: mod_inc = inc_vib << 2;                              // 4.0
        endcase
    end

    reg [PHASE_BITS-1:0] ph_mod;        // 调制器相位
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph_mod <= {PHASE_BITS{1'b0}};
        end else if (sample_en) begin
            if (gate & ~gate_d)
                ph_mod <= {PHASE_BITS{1'b0}};     // 新音符：调制器相位也归零
            else if (gate)
                ph_mod <= ph_mod + mod_inc;
        end
    end

    // 调制器输出 ±127，符号扩展到 16 位后按 FM_DEPTH 移位
    // 深度改成 0~4 可调（原来写死 古筝>>>2 / 木琴>>>1 / 单簧管>>>3）
    wire signed [7:0]  m_s   = ssin8(ph_mod[PHASE_BITS-1 -: 8]);
    wire signed [15:0] m_ext = {{8{m_s[7]}}, m_s};
    wire signed [15:0] m_dep = m_ext >>> fm_depth;

    // 载波索引 + 调制偏移。
    // 只取低 8 位是有意的：相位调制本来就是"按 2π 取模"，
    // 8 位自然回绕正是我们要的效果，不用额外做模运算。
    wire [7:0]        car_idx = phase[PHASE_BITS-1 -: 8];
    wire [7:0]        fm_idx  = car_idx + m_dep[7:0];
    wire signed [7:0] s_fm    = ssin8(fm_idx);

    // ------------------------------------------------------------
    // 钢琴音色：单查表 + 波形整形（半角恒等式）
    //
    // 实现说明：最初给每个泛音单独查表（3 张表 × 32 声部），
    // LUT 涨到 57% 直接布不通线。现在只查"半角"两个值（其实就是 2 次查表）：
    // u = sin(θ/2)、v = cos(θ/2) （v = 同表索引 +64，几乎不花钱）
    // 再用三角恒等式把前 4 个泛音都算出来：
    // sin(θ) = 2·u·v
    // sin(3θ/2) = u·(3 − 4u²)
    // sin(2θ) = u·(4v·(1−u²) − 2v)
    //
    //  权重写法是关键：系数全部写在"8 位定点（±127 = 满量程）"域里，
    // 所以系数比 = 能量比，一眼能看出配比。下面这组是钢琴的典型比例：
    // 基波 51 : 二次 26 : 三次 16 : 四次 8
    // 即 二次 ≈ 基波的一半、三次 ≈ 1/3、四次 ≈ 1/6（真实钢琴二次很突出）。
    // 之前写成 (u>>4, h2>>5, h3>>6)，等效 基波:二次 = 4:1，能量过度集中在
    // 基波上，所以听着"薄、没有钢琴味"。想更亮就把 26/16/8 继续加大。
    // ------------------------------------------------------------
    wire signed [7:0] u = ssin8({phase[PHASE_BITS-1 -: 7], 1'b0});         // sin(θ/2)
    wire signed [7:0] v = ssin8({phase[PHASE_BITS-1 -: 7], 1'b0} + 8'd64); // cos(θ/2)
    //  u、v 是同一张表的两次查表（索引差 64 = 90°），综合时会共用成一张表。

    wire signed [15:0] uv = u * v;               // u·v（±16129）
    wire signed [15:0] u2 = u * u;               // u²（0..16129）

    // 前 4 个泛音（统一在 u 的 8 位定点量纲里，±127 ≈ 1.0）
    wire signed [16:0] p1 = {u, 8'd0};                                        // 基波 = u
    wire signed [16:0] p2 = uv;                                               // 二次 = u·v/128
    wire signed [16:0] p3 = ({u, 1'b0} * 3) - ({u2 >>> 7} * 8);               // 三次 = 3u−4u³
    wire signed [16:0] p4 = ({uv >>> 3} * 2) - ({uv >>> 6} * (u2 >>> 6));     // 四次

    // 关键：权重必须是常数（全部由移位/加法构成，综合出来只是几个加减法），
    // 不要写成"每个泛音各乘一次包络"--那样 32 声部会直接把器件撑爆
    // （测试：4 个泛音各自加权乘包络 -> 79728 个逻辑 > 59904 上限，综合直接报错）。
    //
    // 音色性格就靠这 4 个数：
    // 电子琴高次泛音要强、频谱要亮而"平"：
    // 51 : 33 : 24 : 17 （二次 0.647×、三次 0.470×、四次 0.333×）
    // 原声钢琴高次泛音弱一些、更暖：（已弃用，留作对照）
    // 51 : 26 : 16 : 8 （二次 0.510×、三次 0.314×、四次 0.157×）
    // 四个泛音的权重现在还能被网页控制台单独衰减
    // （HARM1_ATT..HARM4_ATT，每个 0~3 -> 右移 0~3 位）。
    // 衰减为 0 时，下面的表达式和原来完全一致，不会改变现有音色。
    // 峰值 ≈ 21640，后面总缩放 ÷2 -> ≈ ±10820，不会溢出。
    // 想更亮：把 33/24/17 继续加大（四个数之和别超过 ~300）。
    wire signed [16:0] w1 = (p1 >>> 1) >>> harm_att[1:0];
    wire signed [16:0] w2 = (p2 >>> 1) >>> harm_att[3:2];
    wire signed [16:0] w3 = (p3 >>> 1) >>> harm_att[5:4];
    wire signed [16:0] w4 = (p4 >>> 2) >>> harm_att[7:6];

    wire signed [16:0] wave8 = w1 * 51
                             + w2 * 33
                             + w3 * 24
                             + w4 * 17;

    // ============================================================
    // 6) 独立 ADSR 包络（每声部只需一套，接在合音之后）
    // ============================================================
    wire env_active_w;
    adsr #(.WIDTH(16)) u_adsr (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_en  (sample_en),
        .rate       (env_rate),
        .exp_shift  (env_exp),
        .one_shot   (env_oneshot),
        .gate       (gate),
        .pedal_en   (pedal_en),
        .pedal_step (pedal_step),
        .atk_step   (atk_step),
        .dec_step   (dec_step),
        .sus_level  (sus_level),
        .rel_step   (rel_step),
        .env        (env_out),
        .active     (env_active_w)
    );
    assign env_active = env_active_w;

    wire signed [15:0] wave = (wave_sel == 3'd0) ? w_sqr :
                              (wave_sel == 3'd1) ? w_saw :
                              (wave_sel == 3'd2) ? w_tri :
                              (wave_sel == 3'd3) ? {s_f, 8'd0} :
                              (wave_sel == 3'd4) ? wave8[15:0] :
                                                   {s_fm, 8'd0};   // 5/6/7 = FM

    // ============================================================
    // 7) PCM = 波形 × 包络 × 力度（所有档位统一，只乘两次）
    // 钢琴档的 wave8[15:0] 峰值 ≈ ±16162，与其它波形同一个量纲，
    // 所以这里不需要任何特殊分支。
    // 若觉得整体偏轻：把 wave8 的系数整体放大（见上面注释），
    // 或把 mixer 里的 MIX_SHIFT 调小。
    // ============================================================
    wire signed [32:0] p_env = wave * $signed({1'b0, env_out});
    wire signed [39:0] p_all = p_env * $signed({1'b0, velocity});

    assign pcm = p_all[38:23];
    // 钢琴档的相位增量是"半角"（inc_std>>1），给齐奏的锯齿层要还原成实际音高
    assign inc_out = (wave_sel == 3'd4) ? (inc_vib << 1) : inc_vib;

endmodule