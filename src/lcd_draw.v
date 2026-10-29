// ============================================================
// lcd_draw.v - LCD 逐像素绘制
//
// 1024x600，顶部复音/键盘，下面波形；不保存整帧，按像素实时计算。
// ============================================================

module lcd_draw #(
    parameter H_ACTIVE  = 1024,
    parameter V_ACTIVE  = 600,
    // 画面旋转（0/1/2/3 = 顺时针 0°/90°/180°/270°）
    // 面板扫描方向和 FPGA 计数器差 90° 时，只有旋转能修（镜像修不了）。
    // 改这一个数字就能试四个方向，不用改其它任何地方。
    parameter ROTATE    = 0,
    // 画面镜像（在旋转之后叠加，做左右/上下微调）
    // MIRROR_X = 1 -> 左右翻转； MIRROR_Y = 1 -> 上下翻转
    parameter MIRROR_X  = 1'b0,
    parameter MIRROR_Y  = 1'b0,
    parameter BUF_AW    = 12,       // 采样缓冲地址位宽（须与 scope_capture 一致）
    parameter DISP_W    = 1024,     // 波形显示宽度
    parameter NUM_VOICES= 32,
    parameter AMP_SHIFT = 8,        // 幅度缩放：采样 >> AMP_SHIFT 得到像素偏移
    parameter TOP_H     = 62,       // 顶部状态栏高度（多了一行"键盘"显示）
    // 键盘显示：8 个键，每键一格，格内画音名（如 C5 / D4）
    parameter KBD_N     = 8,        // 显示的琴键数
    parameter [6:0] KBD_NOTE_LO = 7'd60,   // 最低那个键的音（要和 top.v 保持一致）
    parameter KBD_REVERSE = 1'b1,   // 1 = 第 0 个键是最高音（和 top.v 一致）
    // 复音计数位宽（与 voice_meter 的 CNTW 一致，随 NUM_VOICES 自动变）
    parameter CNTW = ((NUM_VOICES <= 2)  ? 1 :
                      (NUM_VOICES <= 4)  ? 2 :
                      (NUM_VOICES <= 8)  ? 3 :
                      (NUM_VOICES <= 16) ? 4 :
                      (NUM_VOICES <= 32) ? 5 : 6) + 1
) (
    input  wire               pclk,
    input  wire               rst_n,
    // ---- 当前像素 ----
    input  wire [11:0]        x,
    input  wire [11:0]        y,
    input  wire               de,
    // ---- 采样缓冲 ----
    output wire [BUF_AW-1:0]  buf_addr,
    input  wire signed [15:0] buf_data,
    input  wire [BUF_AW-1:0]  wr_ptr,
    // ---- 复音信息 ----
    input  wire [NUM_VOICES-1:0] v_gate,
    input  wire [CNTW-1:0]    active_cnt,
    input  wire [CNTW-1:0]    peak_cnt,
    // ---- 键盘按键状态（接键盘调试用：哪几个键按下了） ----
    input  wire [KBD_N-1:0]   kbd_gate,
    // ---- 调试：8 路 ADS1115 原始读数（每路 8 位 = 高字节）----
    input  wire [63:0]        dbg_force,
    // ---- 输出 RGB666 = {R[5:0], G[5:0], B[5:0]} ----
    // 面板是 TTL-24bit，但板上每通道只接出高 6 位（低位接地），
    // 所以实际驱动的是 RGB666。原来用 RGB565 会丢掉红色的一位。
    // 这是寄存器输出（见文件末的 always @(posedge pclk)）。
    // 之前写成组合输出（always @(*)），从像素坐标到 RGB 的组合链长达 23.6ns，
    // 在 50MHz（20ns）下无法满足 -> 测试 slack -9.4ns。
    // 加一级寄存器打断长链后即可收敛。
    output reg  [17:0]        rgb,
    // 与 rgb 同步延迟 1 拍的 DE（数据使能）
    // 因为 rgb 打了一拍，DE 必须跟着延迟，否则像素和使能错位。
    // 顶层用这个信号而不是原始 de 去驱动面板的 DEN。
    output reg                de_out
);

    // ============================================================
    // 颜色（RGB666：{R[5:0], G[5:0], B[5:0]}）
    // ============================================================
    localparam [17:0] C_BG     = {6'd4,  6'd8,  6'd16};   // 背景 深蓝
    localparam [17:0] C_TOP    = {6'd2,  6'd4,  6'd8 };   // 顶栏 更深的蓝
    localparam [17:0] C_MID    = {6'd16, 6'd32, 6'd16};   // 基准线 暗灰绿
    localparam [17:0] C_WAVE   = {6'd8,  6'd60, 6'd20};   // 波形 亮绿
    localparam [17:0] C_VON    = {6'd63, 6'd40, 6'd0 };   // 声部亮 橙黄
    localparam [17:0] C_VOFF   = {6'd12, 6'd20, 6'd12};   // 声部灭 暗灰
    localparam [17:0] C_DIG    = {6'd63, 6'd63, 6'd63};   // 数字 白
    localparam [17:0] C_CN     = {6'd20, 6'd60, 6'd60};   // 中文标签 亮青
    localparam [17:0] C_PEAK   = {6'd63, 6'd20, 6'd20};   // 峰值标记 红
    // 键盘行用色
    localparam [17:0] C_KON    = {6'd8,  6'd48, 6'd24};   // 按键框（按下）亮青绿
    localparam [17:0] C_KOFF   = {6'd6,  6'd16, 6'd10};   // 按键框（未按）暗灰
    localparam [17:0] C_KTXT_ON= {6'd63, 6'd63, 6'd63};   // 音名文字（按下）白
    localparam [17:0] C_KTXT_OFF={6'd28, 6'd56, 6'd36};   // 音名文字（未按）暗青

    // ============================================================
    // 0) 画面旋转 + 镜像（统一在这里做坐标变换）
    //
    // 把"屏幕扫描坐标 (x,y)"映射成"逻辑绘制坐标 (xd,yd)"，
    // 后面所有绘制逻辑统一用 xd/yd，波形和文字就处在同一个坐标系里。
    //
    // 旋转绘制的实现原因：
    // 面板的扫描方向和 FPGA 的计数器可能差 90°。镜像只能左右/上下翻，
    // 做不出 90° 旋转 -- 这就是之前 A/B/C/D 四个镜像组合都不对的原因。
    //
    // 之前的一个隐藏 bug：波形用原始 x算读地址，
    // 而文字用变换后的 xd/yd，两者坐标系不一致，
    // 于是"文字看起来糊了/转圈"，波形却是另一回事。
    // 现在波形也统一用 xd（见下面 buf_addr 那段）。
    //
    // ROTATE 含义（把屏幕顺时针转 ROTATE×90° 才能看到正常画面）：
    // 0 : xd = x yd = y
    // 1 : xd = y yd = (宽-1) - x
    // 2 : xd = (宽-1) - x yd = (高-1) - y
    // 3 : xd = (高-1) - y yd = x
    // 再叠加 MIRROR_X / MIRROR_Y 做微调。
    // ============================================================
    // 旋转 90°/270° 时，逻辑画面的宽高要对调
    localparam ROT90  = (ROTATE == 1) || (ROTATE == 3);
    localparam DRAWW  = ROT90 ? V_ACTIVE : H_ACTIVE;    // 逻辑画面宽
    localparam DRAWH  = ROT90 ? H_ACTIVE : V_ACTIVE;    // 逻辑画面高
    localparam DW_W   = DRAWW;                          // 波形区宽度（= 逻辑宽）

    wire [11:0] xr, yr;             // 旋转后、镜像前的坐标

    generate
        if (ROTATE == 0) begin : g_r0
            assign xr = x;
            assign yr = y;
        end else if (ROTATE == 1) begin : g_r1
            assign xr = y;
            assign yr = H_ACTIVE[11:0] - 12'd1 - x;
        end else if (ROTATE == 2) begin : g_r2
            assign xr = H_ACTIVE[11:0] - 12'd1 - x;
            assign yr = V_ACTIVE[11:0] - 12'd1 - y;
        end else begin : g_r3
            assign xr = V_ACTIVE[11:0] - 12'd1 - y;
            assign yr = x;
        end
    endgenerate

    wire [11:0] xd, yd;

    generate
        if (MIRROR_X) begin : g_mx
            assign xd = DRAWW[11:0] - 12'd1 - xr;
        end else begin : g_mx_off
            assign xd = xr;
        end
        if (MIRROR_Y) begin : g_my
            assign yd = DRAWH[11:0] - 12'd1 - yr;
        end else begin : g_my_off
            assign yd = yr;
        end
    endgenerate

    // ============================================================
    // 1) 采样缓冲读地址：把最新采样对齐到最右列
    // 用旋转后的 xr（不是原始 x）-- 保证波形和文字在同一坐标系里，
    // 旋转时两者一起转，不会一个横一个竖。
    // 2^BUF_AW 是 2 的幂，减 DISP_W 等价于加 (2^BUF_AW - DISP_W)
    // ============================================================
    localparam [BUF_AW-1:0] WRAP = (1 << BUF_AW) - DISP_W;

    assign buf_addr = wr_ptr + xr[BUF_AW-1:0] + WRAP;

    // ============================================================
    // 2) 波形：本列采样 -> 该亮的行
    // ============================================================
    localparam [11:0] Y_MID = (TOP_H + DRAWH[11:0]) / 2;   // 波形区中线（用逻辑高）

    wire signed [15:0] amp   = buf_data >>> AMP_SHIFT;     // 幅度（有符号）
    wire signed [15:0] ywave = $signed({4'b0, Y_MID}) - amp;
    wire signed [15:0] ycur  = $signed({4'b0, yd[11:0]});

    // 3 像素粗的波形线
    wire wave_lit = (ycur >= (ywave - 16'sd1)) && (ycur <= (ywave + 16'sd1));

    // 中线（只在波形区）
    wire mid_lit = (yd == Y_MID);

    // ============================================================
    // 3) 顶部状态栏布局
    // 状态栏放大到 134 像素高，波形区相应缩小（占 y 134..599 = 466）
    //
    // 排布原则：每块元素之间留 ≥6 像素空隙，绝对不能重叠
    // （上一版把"当前复音"数字放在 y40~68、"峰值复音"标签放 y62~78，
    // 在 y62~68 重叠了 6 像素，导致看起来"数字变两层、糊在一起"）
    //
    // y 0..17 "声部" 标签
    // y 20..38 声部条形图（高 19）
    // y 44..60 "当前复音" 标签
    // y 44..72 当前复音数数字（4 倍放大 20x28，和标签同一行）
    // y 78..94 "峰值复音" 标签
    // y 78..106 峰值复音数数字
    // ============================================================
    // 3) 顶部状态栏布局
    // 状态栏 134 像素高，波形区 466 像素
    //
    // 标签用英文（5x7 点阵放大 3 倍 = 15x21），不用汉字 --
    // 汉字的 16x16 点阵在这块屏上效果不好，英文用现成字模更清晰。
    //
    // y 0..21 "VOICES"（声部）
    // y 24..40 声部条形图（高 17）
    // y 44..72 "CUR" + 当前复音数
    // y 78..106 "PEAK" + 峰值复音数
    // y 110..133 键盘行（高 24）
    //
    // x 0..119 "VOICES"（6 字 x 20）
    // x 64..~576 条形图
    // x 0..59 "CUR" / "PEAK"
    // x 80..127 数字（2 位，4 倍放大）
    // ============================================================
    localparam STEP = 16;                       // 每声部占多少像素
    localparam BARW = NUM_VOICES * STEP;        // 整条的长度 = 32*16 = 512
    localparam BAR_Y0 = 12'd24;                 // 条形图上端 y
    localparam BAR_H  = 12'd17;                 // 条形图高度

    localparam DIG_SCALE = 4;                   // 数字放大倍数
    localparam DIG_W = 5 * DIG_SCALE;           // 单个数字宽 20
    localparam DIG_H = 7 * DIG_SCALE;           // 单个数字高 28

    // 英文字模尺寸在下面 4c) 节定义（ENG_SCALE=4 -> 20x28，字距 24）

    // 字母代码（对应 glyph_lit / eng_pix 里的表）
    localparam [4:0] L_C = 5'd1,  L_E = 5'd3,  L_A = 5'd6,  L_I = 5'd18,
                     L_K = 5'd19, L_O = 5'd20, L_P = 5'd21, L_R = 5'd22,
                     L_S = 5'd23, L_U = 5'd24, L_V = 5'd25;

    localparam [11:0] BAR_X    = 12'd192;       // 条形图左端（再次右移，按要求）
    localparam [11:0] D1X      = 12'd80;        // 当前复音数数字
    localparam [11:0] D2X      = 12'd80;        // 峰值复音数数字
    // 注：ENG_X / ENG_Y1..3 / VW / CW / PW / LBLH 在下面 4c) 节定义

    wire in_top = (yd < TOP_H);
    wire in_wave_area = (yd >= TOP_H) && (yd < DRAWH[11:0]);

    wire [11:0] bx = xd - BAR_X;                // 相对条形图左端
    wire [11:0] by = yd - BAR_Y0;               // 相对条形图上端

    wire [17:0] bar_fill = active_cnt * STEP;   // 已点亮到哪一像素
    wire [17:0] peak_pos = peak_cnt   * STEP;   // 峰值标记位置

    wire bar_bg  = (bx < BARW) && (by < BAR_H);                 // 条形图（高 14）
    wire bar_on  = bar_bg && ({6'b0, bx} < bar_fill);
    wire peak_on = (by < (BAR_H + 12'd4)) && ({6'b0, bx} >= peak_pos) &&
                   ({6'b0, bx} < (peak_pos + 18'd3));

    // ============================================================
    // 4) 顶部状态栏：两位数字（十位 + 个位）
    // 5x7 点阵字体，放大 4 倍 -> 20x28
    // ============================================================
    function [3:0] tens_of;                     // 取十位
        input [CNTW-1:0] c;
        begin
            if      (c >= 10'd30) tens_of = 4'd3;
            else if (c >= 10'd20) tens_of = 4'd2;
            else if (c >= 10'd10) tens_of = 4'd1;
            else                  tens_of = 4'd0;
        end
    endfunction

    function [3:0] ones_of;                     // 取个位
        input [CNTW-1:0] c;
        begin
            if      (c >= 10'd30) ones_of = c - 10'd30;
            else if (c >= 10'd20) ones_of = c - 10'd20;
            else if (c >= 10'd10) ones_of = c - 10'd10;
            else                  ones_of = c;
        end
    endfunction

    function digit_on;                          // 某数字是否点亮当前像素
        input [11:0] px, py, x0, y0;
        input [3:0]  d;
        reg   [11:0] dx, dy;
        begin
            dx = px - x0;
            dy = py - y0;
            // 5x7 字模放大 DIG_SCALE 倍（用常量除法，综合成比较器树）
            digit_on = (dx < DIG_W[11:0]) && (dy < DIG_H[11:0]) &&
                       font_pix(d, dx / DIG_SCALE[11:0], dy / DIG_SCALE[11:0]);
        end
    endfunction

    wire d1_on = digit_on(xd, yd, D1X,              12'd46, tens_of(active_cnt)) ||
                 digit_on(xd, yd, D1X + DIG_W[11:0] + 12'd8, 12'd46, ones_of(active_cnt));
    wire d2_on = digit_on(xd, yd, D2X,              12'd80, tens_of(peak_cnt))   ||
                 digit_on(xd, yd, D2X + DIG_W[11:0] + 12'd8, 12'd80, ones_of(peak_cnt));

    // ============================================================
    // 4b) 键盘行：8 个键，每键一格，格内画音名（C4 / D4 / ...）
    //
    // 排布：y 110..133（状态栏放大后），x 分成 KBD_N 格
    // 每格画 3 个字符：{升号位, 音名字母, 八度数字}
    // - 升号位在 C 大调音阶下永远是空白（白键），留着是为了以后加黑键
    // - 音名字母用扩展字模（A~G），升号 '#' 也在里面
    // 颜色：按下 = 亮青，未按下 = 暗灰
    // ============================================================
    localparam KBD_CELL = DRAWW / KBD_N;        // 每格宽度（旋转后按逻辑宽算）
    localparam KBD_Y0   = 12'd110;              // 键盘行上边
    localparam KBD_H    = 12'd24;               // 键盘行高度

    // 像素是否落在键盘行内
    wire in_kbd = (yd >= KBD_Y0) && (yd < (KBD_Y0 + KBD_H));

    // 当前像素属于第几格（0 .. KBD_N-1），以及格内相对坐标
    // 用 12 位常量做运算，避免 32 位隐式提升带来的截断告警
    localparam [11:0] KBD_CELL12 = KBD_CELL[11:0];
    wire [11:0] kbd_xr = xd / KBD_CELL12;           // 格号（常量除法 -> 综合成比较器树）
    wire [11:0] kbd_xl = xd - (kbd_xr * KBD_CELL12); // 格内 x
    wire [11:0] kbd_yl = yd - KBD_Y0;                // 格内 y

    // 格号 -> 该格的音（ 必须和 keyboard_in.v 的映射一致。）
    // keyboard_in 里用的是白键半音偏移表white_semi：
    // 度数 0..7 -> 偏移 0 2 4 5 7 9 11 12
    // （钢琴白键不是半音阶。C->D 差 2 个半音、E->F 只差 1 个）
    //  曾经这里按"每格 +1 个半音"算，结果屏幕上显示成
    // C C# D D# E F F# G -- 和实际发声对不上。现在改用同一张表。
    wire [2:0]  kbd_cell_i = (kbd_xr < KBD_N[11:0]) ? kbd_xr[2:0] : 3'd0;
    // REVERSE 时把度数反过来（和 keyboard_in 的 DEG_C 一致）
    wire [3:0]  kbd_deg = KBD_REVERSE ? (4'd7 - {1'b0, kbd_cell_i}) : {1'b0, kbd_cell_i};
    wire [6:0]  kbd_cell_note = KBD_NOTE_LO + {2'b0, white_semi(kbd_deg)};
    wire       kbd_cell_on   = (kbd_xr < KBD_N[11:0]) && kbd_gate[kbd_cell_i];

    // ------------------------------------------------------------
    // 调试用：键盘行上把每键压力原始读数画成柱子
    // ------------------------------------------------------------
    // 背景：调 ADS1115 压力传感器时完全没有读数反馈，只能盲调。
    // 这里把每个键的传感器读数画成格子底部的填充高度，一按就能看见。
    //
    // dbg_force[i*8 +: 8] 是第 i 路 ADC 最新读数的高 8 位（0~255）。
    // ADS1115 用 ±4.096V 量程：3.3V 满量程 ≈ 码值 26400，高 8 位 ≈ 103。
    // 所以实际能看到的数值大概 0~103，映射到 20 像素高的柱子。
    // 灵敏度：原来是 force>>2（满柱要 2.56V），现在改成 force>>1
    // 满柱只要 1.28V 左右，轻按就有明显反应，手感更接近真实钢琴。
    // （kbd_force 是 ADC 读数的高字节 0~255）
    wire [7:0]  kbd_force = dbg_force[kbd_cell_i*8 +: 8];

    // 分段线性映射：把"低压力区展开、高压力区压缩"
    // 原来线性映射的问题是：传感器稍一用力就到顶，中间区几乎没有。
    // 这里改成三段，低端斜率小（所以轻按也能看出变化），
    // 高端斜率大（重按才接近满），中间段最细腻。
    //
    // 数值 0~ 16 -> 柱高 0~4 （斜率 1/4，极轻区，防误触）
    // 数值 17~ 64 -> 柱高 4~10 （斜率 1/8）
    // 数值 65~127 -> 柱高 10~17 （斜率 1/8）
    // 数值 128+ -> 柱高 17~20 （斜率 1/32，重按区压缩）
    reg [11:0] kbd_barh;
    always @(*) begin
        if      (kbd_force <= 8'd16)  kbd_barh = {10'd0, kbd_force[7:2]};                    // 0~4
        else if (kbd_force <= 8'd64)  kbd_barh = 12'd4  + {9'd0, (kbd_force - 8'd16) >> 3};  // 4~10
        else if (kbd_force <= 8'd127) kbd_barh = 12'd10 + {9'd0, (kbd_force - 8'd64) >> 3};  // 10~17
        else                          kbd_barh = 12'd17 + {8'd0, (kbd_force - 8'd128) >> 5}; // 17~20
    end
    // 柱子从格子底部往上长（底部 2 像素是边框，从它上面开始）
    wire        kbd_bar   = in_kbd && (kbd_xr < KBD_N[11:0]) &&
                            (kbd_yl >= (KBD_H - 12'd2 - kbd_barh));

    // 音名：半音 0..11 -> 字母；并给出八度（MIDI 60..71 -> 八度 4）
    // 返回的是字符码，不是偏移量：1=C ... 7=G，17=升号（见 glyph_row）
    //  返回位宽必须是 5 位，3 位装不下 17
    function [4:0] letter_of;
        input [3:0] s;                          // 半音 0..11
        begin
            case (s)
                4'd0 : letter_of = 5'd1;        // C
                4'd2 : letter_of = 5'd2;        // D
                4'd4 : letter_of = 5'd3;        // E
                4'd5 : letter_of = 5'd4;        // F
                4'd7 : letter_of = 5'd5;        // G
                4'd9 : letter_of = 5'd6;        // A
                4'd11: letter_of = 5'd7;        // B
                default: letter_of = 5'd17;     // 升号 '#'（黑键用，暂时到不了）
            endcase
        end
    endfunction

    // 钢琴白键的半音偏移（ 必须和 keyboard_in.v 里的那张表一模一样）
    // 度数 0..7 = C D E F G A B C -> 偏移 0 2 4 5 7 9 11 12
    function [4:0] white_semi;
        input [3:0] d;
        begin
            case (d)
                4'd0: white_semi = 5'd0;    // C
                4'd1: white_semi = 5'd2;    // D
                4'd2: white_semi = 5'd4;    // E
                4'd3: white_semi = 5'd5;    // F
                4'd4: white_semi = 5'd7;    // G
                4'd5: white_semi = 5'd9;    // A
                4'd6: white_semi = 5'd11;   // B
                4'd7: white_semi = 5'd12;   // C（高八度）
                default: white_semi = 5'd0;
            endcase
        end
    endfunction

    // 字符绘制：格内坐标 (lx,ly) 是否落在某个字符的笔画上
    // ox/oy = 该字符在格内的起点（x 按 +15 排开）
    // c = 字符码：0~9 数字，1~7 = C D E F G A B，17 = 升号 '#'，其余空白
    // 字模 5x7，放大 3 倍 -> 15x21 像素
    //  不能写成"调 glyph_lit 再调 glyph_row"的嵌套函数：
    // Gowin 综合器不支持在 function 里再调另一个 function（报 EX3818）。
    function glyph_lit;
        input [11:0] lx, ly;
        input [11:0] ox, oy;
        input [4:0]  c;
        reg [11:0] dx, dy;
        reg [2:0]  col, row;
        reg [4:0]  r;
        reg [8:0]  sh;
        begin
            dx  = lx - ox;
            dy  = ly - oy;
            // 键盘行字形放大 3 倍 -> 15x21 像素（状态栏放大后行高 31）
            //  这里原来是 col = dx/3、row = dy/3。
            // 除以 3 不是 2 的幂，综合器会做成一棵巨大的比较树，
            // 测试它把 lcd_draw 的关键路径拖到 ~24ns（50MHz 只剩 6ns 余量，
            // 1080p 的 75MHz 根本跑不动）。
            // 改成"乘幻数再右移"：dx/3 == (dx*43691)>>17（对 0..65535 精确），
            // 综合成 1 个乘法器，延迟从十几 ns 降到 2~3ns。
            col = (dx * 16'd43691) >> 17;
            row = (dy * 16'd43691) >> 17;

            // 超出 5x7 范围直接不算，避免右/下边界多出笔画
            if ((dx >= 12'd15) || (dy >= 12'd21) || (lx < ox) || (ly < oy))
                r = 5'd0;
            else
            case ({c, row})
                // ---- 0~9（和 font_pix 一致）----
                8'd0  : r = 5'b01110;  8'd1  : r = 5'b10001;  8'd2  : r = 5'b10001;
                8'd3  : r = 5'b10001;  8'd4  : r = 5'b10001;  8'd5  : r = 5'b10001;
                8'd6  : r = 5'b01110;
                8'd8  : r = 5'b00100;  8'd9  : r = 5'b01100;  8'd10 : r = 5'b00100;
                8'd11 : r = 5'b00100;  8'd12 : r = 5'b00100;  8'd13 : r = 5'b00100;
                8'd14 : r = 5'b01110;
                8'd16 : r = 5'b01110;  8'd17 : r = 5'b10001;  8'd18 : r = 5'b00001;
                8'd19 : r = 5'b00010;  8'd20 : r = 5'b00100;  8'd21 : r = 5'b01000;
                8'd22 : r = 5'b11111;
                8'd24 : r = 5'b11111;  8'd25 : r = 5'b00010;  8'd26 : r = 5'b00100;
                8'd27 : r = 5'b00010;  8'd28 : r = 5'b00001;  8'd29 : r = 5'b10001;
                8'd30 : r = 5'b01110;
                8'd32 : r = 5'b00010;  8'd33 : r = 5'b00110;  8'd34 : r = 5'b01010;
                8'd35 : r = 5'b10010;  8'd36 : r = 5'b11111;  8'd37 : r = 5'b00010;
                8'd38 : r = 5'b00010;
                8'd40 : r = 5'b11111;  8'd41 : r = 5'b10000;  8'd42 : r = 5'b11110;
                8'd43 : r = 5'b00001;  8'd44 : r = 5'b00001;  8'd45 : r = 5'b10001;
                8'd46 : r = 5'b01110;
                8'd48 : r = 5'b00110;  8'd49 : r = 5'b01000;  8'd50 : r = 5'b10000;
                8'd51 : r = 5'b11110;  8'd52 : r = 5'b10001;  8'd53 : r = 5'b10001;
                8'd54 : r = 5'b01110;
                8'd56 : r = 5'b11111;  8'd57 : r = 5'b00001;  8'd58 : r = 5'b00010;
                8'd59 : r = 5'b00100;  8'd60 : r = 5'b01000;  8'd61 : r = 5'b01000;
                8'd62 : r = 5'b01000;
                8'd64 : r = 5'b01110;  8'd65 : r = 5'b10001;  8'd66 : r = 5'b10001;
                8'd67 : r = 5'b01110;  8'd68 : r = 5'b10001;  8'd69 : r = 5'b10001;
                8'd70 : r = 5'b01110;
                8'd72 : r = 5'b01110;  8'd73 : r = 5'b10001;  8'd74 : r = 5'b10001;
                8'd75 : r = 5'b01111;  8'd76 : r = 5'b00001;  8'd77 : r = 5'b00010;
                8'd78 : r = 5'b01100;
                // ---- 10~16 = A~G（键盘音名用）----
                8'd80 : r = 5'b01110;  8'd81 : r = 5'b10001;  8'd82 : r = 5'b10001;
                8'd83 : r = 5'b11111;  8'd84 : r = 5'b10001;  8'd85 : r = 5'b10001;
                8'd86 : r = 5'b10001;
                8'd88 : r = 5'b11110;  8'd89 : r = 5'b10001;  8'd90 : r = 5'b10001;
                8'd91 : r = 5'b11110;  8'd92 : r = 5'b10001;  8'd93 : r = 5'b10001;
                8'd94 : r = 5'b11110;
                8'd96 : r = 5'b01110;  8'd97 : r = 5'b10001;  8'd98 : r = 5'b10000;
                8'd99 : r = 5'b10000;  8'd100: r = 5'b10000;  8'd101: r = 5'b10001;
                8'd102: r = 5'b01110;
                8'd104: r = 5'b11110;  8'd105: r = 5'b10001;  8'd106: r = 5'b10001;
                8'd107: r = 5'b11110;  8'd108: r = 5'b10001;  8'd109: r = 5'b10001;
                8'd110: r = 5'b11110;
                8'd112: r = 5'b11111;  8'd113: r = 5'b10000;  8'd114: r = 5'b10000;
                8'd115: r = 5'b11110;  8'd116: r = 5'b10000;  8'd117: r = 5'b10000;
                8'd118: r = 5'b11111;
                8'd120: r = 5'b11111;  8'd121: r = 5'b10000;  8'd122: r = 5'b10000;
                8'd123: r = 5'b11110;  8'd124: r = 5'b10000;  8'd125: r = 5'b10000;
                8'd126: r = 5'b10000;
                8'd128: r = 5'b01110;  8'd129: r = 5'b10001;  8'd130: r = 5'b10000;
                8'd131: r = 5'b10111;  8'd132: r = 5'b10001;  8'd133: r = 5'b10001;
                8'd134: r = 5'b01110;
                // ---- 17 = 升号 '#'（简化成两横一竖，5x7 里认得出就行）----
                8'd136: r = 5'b00100;  8'd137: r = 5'b10101;  8'd138: r = 5'b11111;
                8'd139: r = 5'b10101;  8'd140: r = 5'b11111;  8'd141: r = 5'b10100;
                8'd142: r = 5'b00100;
                // ---- 18~26 = I K O P R S U V W（英文标签用）----
                // 18 = I
                8'd144: r = 5'b11111;  8'd145: r = 5'b00100;  8'd146: r = 5'b00100;
                8'd147: r = 5'b00100;  8'd148: r = 5'b00100;  8'd149: r = 5'b00100;
                8'd150: r = 5'b11111;
                // 19 = K
                8'd152: r = 5'b10001;  8'd153: r = 5'b10010;  8'd154: r = 5'b10100;
                8'd155: r = 5'b11000;  8'd156: r = 5'b10100;  8'd157: r = 5'b10010;
                8'd158: r = 5'b10001;
                // 20 = O
                8'd160: r = 5'b01110;  8'd161: r = 5'b10001;  8'd162: r = 5'b10001;
                8'd163: r = 5'b10001;  8'd164: r = 5'b10001;  8'd165: r = 5'b10001;
                8'd166: r = 5'b01110;
                // 21 = P
                8'd168: r = 5'b11110;  8'd169: r = 5'b10001;  8'd170: r = 5'b10001;
                8'd171: r = 5'b11110;  8'd172: r = 5'b10000;  8'd173: r = 5'b10000;
                8'd174: r = 5'b10000;
                // 22 = R
                8'd176: r = 5'b11110;  8'd177: r = 5'b10001;  8'd178: r = 5'b10001;
                8'd179: r = 5'b11110;  8'd180: r = 5'b10100;  8'd181: r = 5'b10010;
                8'd182: r = 5'b10001;
                // 23 = S
                8'd184: r = 5'b01111;  8'd185: r = 5'b10000;  8'd186: r = 5'b10000;
                8'd187: r = 5'b01110;  8'd188: r = 5'b00001;  8'd189: r = 5'b00001;
                8'd190: r = 5'b11110;
                // 24 = U
                8'd192: r = 5'b10001;  8'd193: r = 5'b10001;  8'd194: r = 5'b10001;
                8'd195: r = 5'b10001;  8'd196: r = 5'b10001;  8'd197: r = 5'b10001;
                8'd198: r = 5'b01110;
                // 25 = V
                8'd200: r = 5'b10001;  8'd201: r = 5'b10001;  8'd202: r = 5'b10001;
                8'd203: r = 5'b10001;  8'd204: r = 5'b10001;  8'd205: r = 5'b01010;
                8'd206: r = 5'b00100;
                // 26 = W
                8'd208: r = 5'b10001;  8'd209: r = 5'b10001;  8'd210: r = 5'b10001;
                8'd211: r = 5'b10101;  8'd212: r = 5'b10101;  8'd213: r = 5'b11011;
                8'd214: r = 5'b10001;
                default: r = 5'b00000;                                    // 空白
            endcase

            // 取第 col 位：col 0 = 最左像素（bit4）
            // 不用"变量下标的位选" r[col]，改用"移位 + 固定位"，
            // 避免某些综合器把它当常数（表现为字变实心竖条）。
            sh = {4'b0, r} << dx[3:0];
            glyph_lit = (dx < 12'd15) && (dy < 12'd21) && sh[4];
        end
    endfunction

    // 3 个字符：升号位(永远空白) / 音名字母 / 八度数字
    // 八度 = (note / 12) - 1 ；MIDI 60..71 -> 4
    //  同样避免真除法：note/12 == (note*43691)>>19（对 0..127 精确）
    wire [3:0] kbd_oct = ((kbd_cell_note * 16'd43691) >> 19) - 4'd1;

    // 字形放大 3 倍（15x21），纵向偏移 2 让它在 24 像素高的行里居中
    wire kbd_g1 = glyph_lit(kbd_xl, kbd_yl, 12'd2,  12'd2, 5'd18);              // 升号位：空白
    wire kbd_g2 = glyph_lit(kbd_xl, kbd_yl, 12'd17, 12'd2,
                            letter_of(kbd_cell_note[3:0]));                      // 音名
    wire kbd_g3 = glyph_lit(kbd_xl, kbd_yl, 12'd34, 12'd2,
                            {1'b0, kbd_oct});                                    // 八度

    wire kbd_text = in_kbd && (kbd_xr < KBD_N[11:0]) && (kbd_g1 || kbd_g2 || kbd_g3);
    // 格边框：上边、下边各 2 像素
    wire kbd_edge = in_kbd && (kbd_xr < KBD_N[11:0]) &&
                    ((kbd_yl < 12'd2) || (kbd_yl >= (KBD_H - 12'd2)));

    // ============================================================
    // ============================================================
    // ============================================================
    // ============================================================
    // ============================================================
    // 4c) 英文标签 -- 用位图 ROM显示，不做字模查表
    //
    // 背景：前面试了 5 种字模方案（手写 5x7、SimHei 渲染、
    // 用户图片提取、复用 glyph_lit、常量点阵），在这块屏上都会
    // 出现"缺列/变形"。所以这里改成最直接的办法：
    // 用 System.Drawing + Consolas 把整行文字渲染成位图，
    // 再逐像素导出成 Verilog 常量。显示时只做"查表 + 移位"。
    //
    // 取位方式：{row[31:0], 33'b0} << cx 后取固定位 64 --
    // 全程没有"变量下标的位选"，避免综合器把它当常数。
    // ============================================================
    localparam VW = 96;                 // "VOICES" 宽
    localparam CW = 48;                 // "CUR" 宽
    localparam PW = 64;                 // "PEAK" 宽
    localparam LBLH = 20;               // 标签高

    localparam [11:0] ENG_Y1 = 12'd0;   // VOICES
    localparam [11:0] ENG_Y2 = 12'd46;  // CUR
    localparam [11:0] ENG_Y3 = 12'd80;  // PEAK

    function [23:0] rom_voices;
        input [3:0] r;
        begin
            case (r)
                4'd0 : rom_voices = 24'hF00F07F03FFE;
                4'd1 : rom_voices = 24'hF00F0FF83FFE;
                4'd2 : rom_voices = 24'hF01F1FFC3FFE;
                4'd3 : rom_voices = 24'hF81E3FFE1FFC;
                4'd4 : rom_voices = 24'hF81E7C3E01E0;
                4'd5 : rom_voices = 24'h783E781F01E0;
                4'd6 : rom_voices = 24'h7C3C781F01E0;
                4'd7 : rom_voices = 24'h7C3CF80F01E0;
                4'd8 : rom_voices = 24'h3C3CF80F01E0;
                4'd9 : rom_voices = 24'h3C7CF80F01E0;
                4'd10: rom_voices = 24'h3E78F80F01E0;
                4'd11: rom_voices = 24'h1E78F80F01E0;
                4'd12: rom_voices = 24'h1EF8F80F01E0;
                4'd13: rom_voices = 24'h1FF0781F01E0;
                4'd14: rom_voices = 24'h0FF0781F01E0;
                4'd15: rom_voices = 24'h0FF07C3E01E0;
                default: rom_voices = 24'h000000000000;
            endcase
        end
    endfunction

    function [23:0] rom_cur;
        input [3:0] r;
        begin
            case (r)
                4'd0 : rom_cur = 24'h03F8781E3FE0;
                4'd1 : rom_cur = 24'h0FFC781E3FF8;
                4'd2 : rom_cur = 24'h1FFC781E3FFC;
                4'd3 : rom_cur = 24'h3FFC781E3FFC;
                4'd4 : rom_cur = 24'h7E00781E3C3C;
                4'd5 : rom_cur = 24'h7C00781E3C3C;
                4'd6 : rom_cur = 24'h7800781E3C3C;
                4'd7 : rom_cur = 24'hF800781E3C3C;
                4'd8 : rom_cur = 24'hF000781E3FFC;
                4'd9 : rom_cur = 24'hF000781E3FF8;
                4'd10: rom_cur = 24'hF000781E3FF0;
                4'd11: rom_cur = 24'hF000781E3FF0;
                4'd12: rom_cur = 24'hF800781E3CF8;
                4'd13: rom_cur = 24'hF800781E3C78;
                4'd14: rom_cur = 24'h7800781E3C7C;
                4'd15: rom_cur = 24'h7E007C3C3C3C;
                default: rom_cur = 24'h000000000000;
            endcase
        end
    endfunction

    function [23:0] rom_peak;
        input [3:0] r;
        begin
            case (r)
                4'd0 : rom_peak = 24'hFFC07FFC07E0;
                4'd1 : rom_peak = 24'hFFE07FFC07E0;
                4'd2 : rom_peak = 24'hFFF87FFC0FE0;
                4'd3 : rom_peak = 24'hFFF87FF80FE0;
                4'd4 : rom_peak = 24'hF87C7C000FF0;
                4'd5 : rom_peak = 24'hF87C7C001EF0;
                4'd6 : rom_peak = 24'hF83C7C001EF0;
                4'd7 : rom_peak = 24'hF83C7C001EF8;
                4'd8 : rom_peak = 24'hF87C7FF81C78;
                4'd9 : rom_peak = 24'hF8FC7FF83C78;
                4'd10: rom_peak = 24'hFFF87FF83C7C;
                4'd11: rom_peak = 24'hFFF07FF83C3C;
                4'd12: rom_peak = 24'hFFE07C007FFC;
                4'd13: rom_peak = 24'hFF807C007FFC;
                4'd14: rom_peak = 24'hF8007C007FFE;
                4'd15: rom_peak = 24'hF8007C00FFFE;
                default: rom_peak = 24'h000000000000;
            endcase
        end
    endfunction

    // 取位索引 cx（0 = 最左）到固定位 64：
    // {row24, 33'b0} << cx -> 第 (88-cx) 位 = 该行第 cx 个像素
    // 用 89 位中间值，取固定位 64，全程无变量位选
    function eng_voices_lit;
        input [11:0] px, py, x0, y0;
        reg [11:0] dx, dy;
        reg [88:0] b;
        begin
            dx = px - x0;
            dy = py - y0;
            b = {rom_voices(dy[3:0]), 33'b0} << dx[6:0];
            eng_voices_lit = (dx < VW[11:0]) && (dy < LBLH[11:0]) && b[64];
        end
    endfunction

    function eng_cur_lit;
        input [11:0] px, py, x0, y0;
        reg [11:0] dx, dy;
        reg [88:0] b;
        begin
            dx = px - x0;
            dy = py - y0;
            b = {rom_cur(dy[3:0]), 33'b0} << dx[6:0];
            eng_cur_lit = (dx < CW[11:0]) && (dy < LBLH[11:0]) && b[64];
        end
    endfunction

    function eng_peak_lit;
        input [11:0] px, py, x0, y0;
        reg [11:0] dx, dy;
        reg [88:0] b;
        begin
            dx = px - x0;
            dy = py - y0;
            b = {rom_peak(dy[3:0]), 33'b0} << dx[6:0];
            eng_peak_lit = (dx < PW[11:0]) && (dy < LBLH[11:0]) && b[64];
        end
    endfunction

    localparam [11:0] ENG_X = 12'd8;

    wire lbl_voices = eng_voices_lit(xd, yd, ENG_X, ENG_Y1);
    wire lbl_cur    = eng_cur_lit   (xd, yd, ENG_X, ENG_Y2);
    wire lbl_peak   = eng_peak_lit  (xd, yd, ENG_X, ENG_Y3);
    wire eng_any    = lbl_voices || lbl_cur || lbl_peak;

    // ============================================================
    // 5) 合成颜色（组合计算）
    // ============================================================
    reg [17:0] rgb_c;

    always @(*) begin
        if (!de)
            rgb_c = 18'h00000;                     // 消隐期输出黑
        else if (in_top) begin
            if (peak_on)
                rgb_c = C_PEAK;
            else if (bar_bg)
                rgb_c = bar_on ? C_VON : C_VOFF;
            else if (kbd_edge)
                rgb_c = kbd_cell_on ? C_KON : C_KOFF;
            else if (kbd_text)
                rgb_c = kbd_cell_on ? C_KTXT_ON : C_KTXT_OFF;
            else if (kbd_bar)
                rgb_c = C_KON;                     // 压力柱：用"按下"的亮色
            else if (eng_any)
                rgb_c = C_CN;                      // 英文标签：亮青色
            else if (d1_on || d2_on)
                rgb_c = C_DIG;
            else
                rgb_c = C_TOP;
        end else if (in_wave_area) begin
            if (wave_lit)
                rgb_c = C_WAVE;
            else if (mid_lit)
                rgb_c = C_MID;
            else
                rgb_c = C_BG;
        end else
            rgb_c = C_BG;
    end

    // 输出寄存器：把"像素坐标 -> RGB"的长组合链打断
    // （测试不加这一级时 slack = -9.4ns，加完可收敛到正值）
    // DE 同步延迟一拍，保证像素和使能不错位。
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            rgb    <= 18'h00000;
            de_out <= 1'b0;
        end else begin
            rgb    <= rgb_c;
            de_out <= de;
        end
    end

    // ============================================================
    // 说明：字母/升号字模已经内联在 4b 节的 glyph_lit 里
    // （Gowin 不支持 function 里再调 function，所以合并成一个表）
    // ============================================================

    // ============================================================
    // 5x7 数字字模（0~9），5 列 x 7 行，最高位 = 最左列
    // 索引 = {数字, 行号}
    // 说明：这个函数给复音数显示用；键盘音名用的是上面已经内联的
    // glyph_lit（同一个表 + 字母/升号），不再单独维护一份。
    // ============================================================
    function font_pix;
        input [3:0] d;
        input [2:0] col;
        input [2:0] row;
        reg [4:0] r;
        begin
            case ({d, row})
                // ---- 0 ----
                7'd0 : r = 5'b01110;
                7'd1 : r = 5'b10001;
                7'd2 : r = 5'b10001;
                7'd3 : r = 5'b10001;
                7'd4 : r = 5'b10001;
                7'd5 : r = 5'b10001;
                7'd6 : r = 5'b01110;
                // ---- 1 ----
                7'd8 : r = 5'b00100;
                7'd9 : r = 5'b01100;
                7'd10: r = 5'b00100;
                7'd11: r = 5'b00100;
                7'd12: r = 5'b00100;
                7'd13: r = 5'b00100;
                7'd14: r = 5'b01110;
                // ---- 2 ----
                7'd16: r = 5'b01110;
                7'd17: r = 5'b10001;
                7'd18: r = 5'b00001;
                7'd19: r = 5'b00010;
                7'd20: r = 5'b00100;
                7'd21: r = 5'b01000;
                7'd22: r = 5'b11111;
                // ---- 3 ----
                7'd24: r = 5'b11111;
                7'd25: r = 5'b00010;
                7'd26: r = 5'b00100;
                7'd27: r = 5'b00010;
                7'd28: r = 5'b00001;
                7'd29: r = 5'b10001;
                7'd30: r = 5'b01110;
                // ---- 4 ----
                7'd32: r = 5'b00010;
                7'd33: r = 5'b00110;
                7'd34: r = 5'b01010;
                7'd35: r = 5'b10010;
                7'd36: r = 5'b11111;
                7'd37: r = 5'b00010;
                7'd38: r = 5'b00010;
                // ---- 5 ----
                7'd40: r = 5'b11111;
                7'd41: r = 5'b10000;
                7'd42: r = 5'b11110;
                7'd43: r = 5'b00001;
                7'd44: r = 5'b00001;
                7'd45: r = 5'b10001;
                7'd46: r = 5'b01110;
                // ---- 6 ----
                7'd48: r = 5'b00110;
                7'd49: r = 5'b01000;
                7'd50: r = 5'b10000;
                7'd51: r = 5'b11110;
                7'd52: r = 5'b10001;
                7'd53: r = 5'b10001;
                7'd54: r = 5'b01110;
                // ---- 7 ----
                7'd56: r = 5'b11111;
                7'd57: r = 5'b00001;
                7'd58: r = 5'b00010;
                7'd59: r = 5'b00100;
                7'd60: r = 5'b01000;
                7'd61: r = 5'b01000;
                7'd62: r = 5'b01000;
                // ---- 8 ----
                7'd64: r = 5'b01110;
                7'd65: r = 5'b10001;
                7'd66: r = 5'b10001;
                7'd67: r = 5'b01110;
                7'd68: r = 5'b10001;
                7'd69: r = 5'b10001;
                7'd70: r = 5'b01110;
                // ---- 9 ----
                7'd72: r = 5'b01110;
                7'd73: r = 5'b10001;
                7'd74: r = 5'b10001;
                7'd75: r = 5'b01111;
                7'd76: r = 5'b00001;
                7'd77: r = 5'b00010;
                7'd78: r = 5'b01100;
                default: r = 5'b00000;
            endcase
            // 用 case 取位，避免 col 越界时出现非法位选
            case (col)
                3'd0:    font_pix = r[4];
                3'd1:    font_pix = r[3];
                3'd2:    font_pix = r[2];
                3'd3:    font_pix = r[1];
                3'd4:    font_pix = r[0];
                default: font_pix = 1'b0;
            endcase
        end
    endfunction

endmodule