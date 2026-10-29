// ============================================================
// top.v - 压力感应演奏合成器顶层
// Tang Mega 60K / GW5AT-LV60PG484AC1/I0
//
// 音频链：按键/压力 -> 声部分配 -> 8 路振荡器 + ADSR -> 混音/效果 -> I2S
// 控制：UART 参数寄存器；显示：HDMI 波形/频谱，LCD 保留
// ============================================================

module top (
    input  wire        sys_clk,     // 50MHz 系统时钟（V22）
    input  wire        sys_rst_n,   // 低有效复位（AA13）
    // ---- 串口：板载 DEBUG-USB2（BL616 USB-JTAG&UART，U15/V14）----
    // 115200 8N1。网页控制台通过它读写所有参数（协议见 param_regs.v）。
    //  这一对脚板上已经连到 BL616 调试器，不要再接外部 CH340 的 TX，
    // 否则两个输出会打架（详见 fpga_project.cst 末尾的说明）。
    input  wire        UART_RX,     // 串口接收（V14 <- BL616 UART TX）
    output wire        UART_TX,     // 串口发送（U15 -> BL616 UART RX）
// ============================================================
// 未使用 Gowin 内置 ADC
// ============================================================
// 原因：这颗 GW5AT-60 的 ADC 硬核物理上只引出 2 路模拟输入
// （bus0=Y21 / bus1=Y22），其余可选源都是内部电源轨
// （VDD12M / VCC / VCCIO3，用于电压监控）。
// 所以"8 路 ADC"在这颗芯片上做不到 -- 以后要用模拟量
// 改为外挂 ADC 芯片（计划用两颗 ADS1115，I²C 接口）。
//
// 拆掉 ADC 后，原来被占用的 Y21 / Y22 变成普通 3.3V 数字 IO，
// 正好拿来当按键输入（本设计就是这么做）。
// ============================================================
    // 钢琴键盘：8 个白键 + 2 个八度切换键（共 10 个按键）
    // 极性：所有按键都是按下 = 高电平，不用管正负极。
    // 8 个白键从左到右音高递增（KBD[0] 最左 = 最低）：
    // KBD[0] C KBD[1] D KBD[2] E KBD[3] F
    // KBD[4] G KBD[5] A KBD[6] B KBD[7] C（高八度）
    // 默认 KBD[0] = C4（MIDI 60），按 KBD_UP/KBD_DN 整体升降八度。
    //  接好线之后把 top.v 里的 KBD_ENABLE 改成 1'b1，
    // 并把 fpga_project.cst 里对应的约束取消注释。
    input  wire [7:0]  KBD,         // 8 个白键：KBD[0]=C .. KBD[7]=C
    input  wire        KBD_UP,      // 升八度（按下 = 高）
    input  wire        KBD_DN,      // 降八度（按下 = 高）
    input  wire        KEY0,        // 用户按键 KEY0（AB13，低有效，上拉）用于切换音色
    output wire [2:0]  LEDs,        // 3 个 LED（显示音色号 0~4；原 8 个精简而来）
    // ---- I²C 总线（两颗 ADS1115 力度感应，开漏双向）----
    //  必须外部上拉（4.7kΩ 到 3.3V）。两颗 ADS1115 共用这条总线，
    // 以后接 GT911 触控也挂同一条（地址不冲突：0x48/0x49 vs 0x5D）。
    // 用 inout：Gowin 不允许同一球号约束给多个端口（报 PR2030），
    // 所以"读回"和"拉低"必须共用同一个双向端口。
    inout  wire        ADS_SDA,     // I²C 数据（开漏，需上拉）
    inout  wire        ADS_SCL,     // I²C 时钟（开漏，需上拉）
    // ---- 板载音频输出（I2S -> 立体声 DAC -> NS4263 功放）----
    output wire        HP_BCK,      // I2S 位时钟 (Y17)
    output wire        HP_WS,       // I2S 声道时钟 (AB17)
    output wire        HP_DIN,      // I2S 数据 (AA16)
    output wire        PA_EN,       // 功放使能，低有效：0=开功放 (AB16)
    // ---- RGB LCD（40pin FPC 座 J5）----
    // 球号来自 LCD_test 工程的逐根核对（详见 fpga_project.cst 的说明）：
    // 面板 DCLK = HTACK = L19 / HSYNC = HTREQ = N20 / VSYNC = HTVLD = L15
    //  之前用的 J20/J21/G18 是相机接口的 HRCLK/HRACK/HRVLD，接错了，
    // 症状就是"背光亮但全黑"（面板一个时钟都收不到）。
    // 颜色是 RGB666：板上每通道只接出高 6 位，低位接地。
    output wire        LCD_CLK,     // 面板 DCLK (L19)
    output wire        LCD_HSYNC,   // 面板 HSYNC (N20)
    output wire        LCD_VSYNC,   // 面板 VSYNC (L15)
    output wire        LCD_DEN,     // 面板 DEN (L14 <- HD2)
    output wire [5:0]  LCD_R,       // 面板 R7..R2
    output wire [5:0]  LCD_G,       // 面板 G7..G2
    output wire [5:0]  LCD_B,       // 面板 B7..B2
    output wire        LCD_BL,      // 背光使能 (P20)
    // ---- HDMI 输出（板载 HDMI 座，TMDS 差分）----
    // 引脚和官方 hdmi_colorbar 例程完全一致（同一块板）：
    // 时钟 G15(P)/G16(N) 数据0 J14(P)/H14(N)
    // 数据1 J15(P)/H15(N) 数据2 K17(P)/J17(N)
    // 电平标准用 LVCMOS33D（差分 LVCMOS33），不是 LVDS25 --
    // 这样和板上 3.3V 的 Bank 电压一致，不需要外部端接。
    // 官方 DVI_TX IP 的 P/N 双端口
    // P 端在 cst 里占两个球号（IO_LOC "..." J14,H14），N 端不约束，
    // 和 cam2dvi 例程写法一致。
    output wire        TMDS_CLK_P,
    output wire        TMDS_CLK_N,
    output wire [2:0]  TMDS_D_P,
    output wire [2:0]  TMDS_D_N
);

// ---------- 参数 ----------
// ADC 时钟分频：50MHz / 2^4 = 3.125MHz（SAR ADC 安全时钟）
localparam CLK_DIV_BITS = 4;

// ADC 输入源选择 vsenctl[2:0]（读不到数据时改这里试）
// 现在用 PMOD 普通 IO 当模拟输入，属于 ADC 的 bus4 组。
// vsenctl 与 bus 的对应关系没有公开文档，先用 3'b100(=4，对应 bus4) 试；
// 若读数像内部电源轨(固定不变)或全 0/全满，依次试 3'b000 ~ 3'b111。
localparam [2:0] VSENCTL_VALUE = 3'b100;

// SAR 通道使能 chen[6:0]（对应内部 ADC0_CH0~CH6 通道）
localparam [6:0] CHEN_VALUE = 7'b0000001;

// ---------- 时钟分频：50MHz -> 3.125MHz ----------
reg [CLK_DIV_BITS-1:0] clkdiv_cnt;
wire adc_clk;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        clkdiv_cnt <= {CLK_DIV_BITS{1'b0}};
    else
        clkdiv_cnt <= clkdiv_cnt + 1'b1;
end
assign adc_clk = clkdiv_cnt[CLK_DIV_BITS-1];   // 二分频链输出

// ============================================================
// 原 Gowin 内置 ADC 已拆除
// ============================================================
// 拆除内置 ADC 的原因：这颗 GW5AT-60 的 ADC 硬核物理上只引出 2 路外部模拟输入
// （bus0=Y21 / bus1=Y22），做不到 8 路。以后用模拟量改用外挂 ADC
// 芯片（计划两颗 ADS1115，I²C 接口）。
//
// 拆掉后 Y21/Y22 变成普通数字 IO，已用作 BTN2 / BTN3 按键输入。
//
//  剩余说明：adc_clk / VSENCTL_VALUE / CHEN_VALUE 这几个定义还留着
// （adc_clk 还当"按键去抖时钟"用，频率 3.125MHz 刚好合适），
// 但 Gowin_ADC 例化、adc_ain_* 端口、adc_ctrl/adc_filter/note_gen
// 这一整条模拟通路都已不再使用（综合时会被优化掉）。
// ============================================================

// ---------- ADC 控制器（已停用：ADC 硬核已拆除）----------
// 为了不做大改动，这里保留例化但输入端接固定值：
// adc_ready = 0（永远"没转换完"）-> adc_valid 永远为 0
// -> adc_filter 收不到采样 -> filt_val 保持 0
// 整条链路是死逻辑，综合时会被优化掉，不影响任何功能。
wire        adc_ready = 1'b0;
wire [13:0] adc_value = 14'd0;
wire        adc_start;
wire [13:0] adc_data;
wire        adc_valid;

adc_ctrl u_adc_ctrl (
    .clk        (adc_clk),
    .rst_n      (sys_rst_n),
    .adc_ready  (adc_ready),
    .adc_value  (adc_value),
    .adc_start  (adc_start),
    .adc_data   (adc_data),
    .adc_valid  (adc_valid)
);

// ---------- ADC 数据后处理：采集 -> 滤波 -> 稳定 ----------
// 各级原理和参数说明见 adc_filter.v 文件头
wire [13:0] filt_val;     // 滤波后的值
wire        filt_valid;   // 滤波值更新脉冲
wire [13:0] stab_val;     // 稳定后的值
wire        stab_flag;    // 1 = 输入已稳定

adc_filter #(
    .AVG_BITS    (4),     // 累加平均窗口 = 2^4 = 16 个采样（响应快）
    .STABLE_TH   (8),     // 与当前输出的差 > 8 个码值才算"变化"
    .STABLE_BITS (1),     // 变化需连续 2^1 = 2 个平均窗才更新输出
    .FAST_TH     (64)     // 差值 > 64 个码值时立即更新（大变化直通）
) u_adc_filter (
    .clk            (adc_clk),
    .rst_n          (sys_rst_n),
    .sample_valid   (adc_valid),     // 接 adc_ctrl 的采样有效脉冲
    .sample_in      (adc_data),      // 接 adc_ctrl 锁存的原始采样值
    .filtered       (filt_val),
    .filtered_valid (filt_valid),
    .stable_out     (stab_val),
    .stable         (stab_flag)
);

// ============================================================
// 按键 / 模拟输入配置（按键 OUT 接在 ADC 输入脚 AA20 上）
// ============================================================
// 完整通路：
// 按键 -> AA20(ADC脚) -> ADC -> adc_ctrl -> adc_filter -> note_gen
// -> voice_alloc -> 振荡器+ADSR -> 混音限幅 -> PT8211 -> 耳机/喇叭
//
// 按键只有两个状态，所以 ADC 只读到两个固定码值：
// 松开（0V） -> 码值 ≈ 0 -> 低于 GATE_TH -> 不出声
// 按下（3.3V） -> 码值 ≈ 6758 -> 高于 GATE_TH -> 出声
// 按下时音高 = NOTE_LO + (6758*MULT)>>SHIFT = 72（C5）
// 松开时 note_off，ADSR 进入释音阶段自然收尾。
//
// 按键模块极性测试定论：松开 = 0V，按下 = 3.3V（高有效）
// 高有效（松开 0V，按下 3.3V）：ADC_INVERT = 1'b0 <- 你这颗是这种
// 低有效（按下 0V，松开 3.3V）：ADC_INVERT = 1'b1
// 低有效时把码值取反（0 <-> 6758），这样"按下"永远变成高码值 -> 能触发。
//  注意：现在 USE_BUTTON = 1（走数字按键），这条 ADC 通路暂时没接进来，
// 真正决定极性的是下面 button_in 的 ACTIVE_LOW 参数，两处要保持一致。
localparam [13:0] ADC_FULL   = 14'd6758;   // 3.3V 对应的 ADC 码值
localparam        ADC_INVERT = 1'b0;       // 0 = 按键高有效（按下=3.3V）

// 低有效时把码值反过来（0 <-> 6758），这样"按下"永远是高码值
wire [13:0] note_src = ADC_INVERT ? (ADC_FULL - filt_val) : filt_val;

// ---------- 音符事件生成：电压 -> 音高 / 力度 / 开关 ----------
// 原理和参数算法见 note_gen.v 文件头
wire [6:0] note_val;     // 当前音高（量化到半音）
wire [6:0] vel_val;      // 力度
wire       note_gate;    // 1 = 按下
wire       note_on_p;    // 按下脉冲
wire       note_off_p;   // 松开脉冲

note_gen #(
    .GATE_TH (14'd100),   // 按下阈值（约 0.05V）--按键信号很干净，够用
    .VAL_LO  (14'd0),     // 0V -> NOTE_LO
    .VAL_HI  (14'd6758),  // 3.3V -> NOTE_HI
    .NOTE_LO (7'd48),     // 最低音 MIDI 48 = C3
    .NOTE_HI (7'd72),     // 最高音 MIDI 72 = C5（按键按下时发这个音）
    .MULT    (24'd233),   // = 2^16 * (72-48)/(6758-0) ≈ 233
    .SHIFT   (16),
    .VEL_FIX (7'd100),    // 固定力度
    .REL_CNT (8'd16)      // 松开去抖
) u_note_gen (
    .clk         (adc_clk),
    .rst_n       (sys_rst_n),
    .value       (note_src),     // 滤波后的值（必要时已按按键极性取反）
    .value_valid (filt_valid),
    .note        (note_val),
    .velocity    (vel_val),
    .gate        (note_gate),
    .note_on     (note_on_p),
    .note_off    (note_off_p)
);

// ============================================================
// 按键直接走数字输入（方案 C）-- 不经过 ADC
// ============================================================
// 按键接在 AA20（就是 adc_ain_p 那个脚），但读的是数字电平，不走 ADC。
// 原因：ADC IP 的配置里只把 bus0/bus1 设成了外部引脚，而 AA20 属于 bus4，
// 所以 ADC 无论怎么调 vsenctl/chen 都读不到它。
// 按键本来就是数字信号，直接读 IO 更快、更可靠。
//
// 极性（测试定论，别再改回去）：
// 板子/按键模块的实际电平是松开 = 0V，按下 = 3.3V= 高有效。
// 之前按 CST 注释猜成"低有效"（ACTIVE_LOW=1），电平被反相：
// 松开 -> gate=1 -> 一直响
// 按下 -> gate=0 -> note_off -> 声音消失
// 正好就是"上电一直响、按下才停"的症状。现在改成 ACTIVE_LOW=0 修好。
// 注意 CST 里 BTN 的 PULL_MODE=UP 只是弱上拉兜底（约 50kΩ），
// 按键模块在松开时会把引脚拉到 0V，弱上拉拉不动，所以空闲读 0。
//
// ADC 那一整套（adc_ctrl / adc_filter / note_gen）原样保留没删，
// 以后接压力传感器时把 USE_BUTTON 改回 1'b0 即可（那时要重新生成 ADC IP）。
localparam        USE_BUTTON = 1'b1;    // 1 = 用按键（数字输入）；0 = 用 ADC 模拟输入
localparam [6:0]  BTN_NOTE   = 7'd72;   // 按键按下时发的音（MIDI 72 = C5）
localparam [6:0]  BTN_VEL    = 7'd100;  // 按键力度（固定值）

// ============================================================
// 钢琴键盘：8 个白键 + 2 个八度切换键（共 10 个按键）
// ============================================================
// 接线好后要改两处：
// ① 这里把 KBD_ENABLE 改成 1'b1
// ② fpga_project.cst 里把 KBD[0..7] / KBD_UP / KBD_DN 那几条约束
// 取消注释（并且把 BTN 那条注释掉，避免脚位冲突）
//
// 8 个琴键 = 一个八度的白键，从左到右音高递增：
// KBD[0] C KBD[1] D KBD[2] E KBD[3] F
// KBD[4] G KBD[5] A KBD[6] B KBD[7] C（高八度）
// 基准：KBD[0] 默认发 C4（MIDI 60）。
//  白键不是半音阶。C->D 差 2 个半音，E->F 只差 1 个，
// 半音偏移表在 keyboard_in.v 的 white_semi 里。
//
// 2 个八度切换键（每按一次移 12 个半音，带限幅）：
// KBD_UP 按下 -> 整体升一个八度
// KBD_DN 按下 -> 整体降一个八度
// 限幅范围：基准音 = clamp(60 + 12*shift, 36, 84)
// 即 C2 ~ C6，避免超出 osc_voice 的音域表。
//
// 打开后：8 个键各自独占一个声部（第 i 键 -> 第 i 声部），
// 可以同时按下多个键，每个音独立发声、独立衰减，互不打断。
localparam        KBD_ENABLE  = 1'b1;   // 接好键盘后改成 1'b1
localparam [6:0]  KBD_NOTE_LO = 7'd60;  // 最低那个键的音（MIDI 60 = C4）
localparam [6:0]  KBD_VEL     = 7'd100; // 固定力度
// 键盘方向：0 = KBD[0]（最左 = AB20）发最低音 C4 -- 用户要求低音在左
//  必须是 0。曾经为了测八度临时改成 1，结果整排音高左右颠倒
// （AB20 响 C5、Y21 响 C4、屏幕上 C5 跑到最左边）。
// 这个值同时控制发声音高和屏幕键盘行显示，两者始终一致。
localparam        KBD_REVERSE = 1'b0;
// 八度偏移限幅（以"基准音"为单位，单位是半音）
localparam [6:0]  OCT_MIN_BASE = 7'd36;  // 最低 C2
localparam [6:0]  OCT_MAX_BASE = 7'd84;  // 最高 C6
//
// ---------- 力度：固定值 / 压力传感器（ADS1115 × 2，8 路）----------
// 现在已接入 ADS1115 力度感应
// 两颗 ADS1115 挂在 I²C 总线上（和 GT911 触控共用，地址不冲突：
// 0x48 / 0x49 vs 0x5D），8 个通道分别对应 8 个白键。
// 每键按下时，驱动会在 30~45ms 窗口内抓取该通道的力峰值作为力度。
//
// KBD_VEL_SRC = 1 -> 用传感器力度（每键独立）
// KBD_VEL_SRC = 0 -> 固定力度 KBD_VEL（传感器没接时用这个）
//
//  如果 I²C 通信不正常（接线/地址错），力度会一直是 0，
// 表现为"按键完全不出声"（因为力度 0 = 无声）。
// 调试办法：看 err_cnt（err_cnt 一直涨 = 通信失败），
// 或者临时把 KBD_VEL_SRC 改回 0 确认键盘本身是好的。
localparam        KBD_VEL_SRC = 1'b1;   // 1 = 用 ADS1115 力度感应
// 单传感器模式（当前状态）
// 现在只接了 AIN0 一个压力传感器，还没装到 8 个键下面。
// 1 = 把 AIN0 的实时力度给所有 8 个键用：不管按哪个键，
// 声音都跟着同一个传感器走，方便手里捏着传感器、另一只手按键测试。
// 0 = 原来的"每键独立"（8 个传感器都接好后改回 0）。
localparam        ADS_SINGLE = 1'b1;
// 力度映射参数（16 位原始 ADC 码值 -> 0~127）
// ADS1115 单端 + PGA=±4.096V：3.3V 对应码值 ≈ 3.3/4.096*32767 ≈ 26400
// 薄膜传感器空载有底噪，设一个死区 FORCE_MIN；满量程按实际调
localparam [15:0] FORCE_MIN   = 16'd400;    // 小于它算 0（死区，滤噪）
localparam [15:0] FORCE_MAX   = 16'd26000;  // 大于它算满力度 127

// 压力指示条回落速度（只影响屏幕显示，不影响力度/音量）
// 驱动里上升是"立即跟上"，这里只控制松开后的回落：
// 1 = 每采样点减半（最快，约 2 点 / 4ms 时间常数）
// 2 = 每采样点减 1/4（约 8ms）
// 3 = 每采样点减 1/8（原来的值，约 16ms，调试时明显拖尾）
// 采样率约 500Hz（25kHz I²C，只读 1 路时约 2ms 一个点）。
// 想让指示条更"跟手"就保持 1；如果觉得数值跳得太厉害可以改成 2。
localparam [3:0]  ADS_FILT_SHIFT = 4'd1;

// 力度保底：只要该键装了传感器（ads_seen=1），实际输出力度不小于这个值。
// 目的：按下瞬间 ADC 还没采到（或轻按低于死区）时，力度不会是 0，
// 避免"按了但完全没声 / 偶尔漏音"。20/127 ≈ 16%，听着是轻音但一定有声。
// 想让轻按更明显就调大（如 24~30）；想要更贴近真实力度就调小（如 12）。
localparam [6:0]  VEL_FLOOR = 7'd20;

// 网页八度寄存器（0x27）：声明必须在 oct_shift 的 always 之前，
// 否则 Verilog 会当成隐式 1 位 wire（注意）。
reg signed [2:0] p_octave;
reg        p_oct_tog_s1, p_oct_tog_s2, p_oct_tog_d;
wire       oct_web_edge = p_oct_tog_s2 ^ p_oct_tog_d;

// ---------- 键盘输入（同步 + 去抖 + 位映射音高） ----------
wire [7:0]         kbd_gate, kbd_press, kbd_release;
wire [8*7-1:0]     kb_note, kb_vel;
// 哪些音色用压力力度：起由网页控制台的 VEL_PRESS 寄存器
// （param_regs 的 p_vel_press）决定，不再写死在顶层。
// 预设值仍然是"钢琴/古筝/木琴=1，其它=0"，所以默认听感和之前一致。

// ============================================================
// 按键去抖位宽（三处例化统一用这个值）
// ============================================================
// 去抖时间 = 2^BITS / adc_clk(3.125MHz)
// 15 位 -> 32768/3.125MHz = 10.5 ms <- 原来，占起音延迟的 88%
// 14 位 -> 16384/3.125MHz = 5.2 ms <- 现在（按键界面不稳定，先加稳）
// 13 位 -> 8192/3.125MHz = 2.6 ms （之前的激进值，偶发漏/抖）
// 12 位 -> 4096/3.125MHz = 1.3 ms （更激进，可能偶发误触发）
//  如果 5.2ms 觉得起音慢，可以改回 13；但先确认稳定性。
localparam [3:0] KEY_DBNC_BITS = 4'd14;

keyboard_in #(
    .NKEYS      (8),
    .DBNC_BITS  (KEY_DBNC_BITS),  // 5.2ms（稳定性优先）
    .ACTIVE_LOW (1'b0),         // 测试按键高有效（松开 0V / 按下 3.3V）
    .REVERSE    (KBD_REVERSE),
    .NOTE_BASE  (KBD_NOTE_LO),
    .VELOCITY   (KBD_VEL)
) u_keyboard (
    .clk      (adc_clk),
    .rst_n    (sys_rst_n),
    .key      (KBD),
    .gate     (kbd_gate),
    .press    (kbd_press),
    .released (kbd_release),
    .note_out (kb_note),
    .vel_out  (),// 力度不再用固定值，改由 ADS1115 每键独立提供
    .any_key  ()
);

// ============================================================
// 八度切换键（KBD_UP / KBD_DN）
// 每按一次整体升/降一个八度（12 个半音），带限幅。
// 用和琴键相同的去抖模块，取"按下脉冲"来计数。
// ============================================================
wire kbd_up_gate, kbd_up_press, kbd_up_rel;
wire kbd_dn_gate, kbd_dn_press, kbd_dn_rel;

button_in #(
    .DBNC_BITS  (KEY_DBNC_BITS),  // 5.2ms（稳定性优先）
    .ACTIVE_LOW (1'b0)          // 高有效：按下 = 3.3V
) u_kbd_up (
    .clk     (adc_clk),
    .rst_n   (sys_rst_n),
    .pin     (KBD_UP),
    .gate    (kbd_up_gate),
    .press   (kbd_up_press),
    .released(kbd_up_rel)
);

button_in #(
    .DBNC_BITS  (KEY_DBNC_BITS),  // 5.2ms（稳定性优先）
    .ACTIVE_LOW (1'b0)
) u_kbd_dn (
    .clk     (adc_clk),
    .rst_n   (sys_rst_n),
    .pin     (KBD_DN),
    .gate    (kbd_dn_gate),
    .press   (kbd_dn_press),
    .released(kbd_dn_rel)
);

// 八度偏移：0 = 不偏移；每按一次 ±1（表示 ±12 个半音）
reg signed [2:0] oct_shift;

always @(posedge adc_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        oct_shift <= 3'sd0;
    else if (oct_web_edge)
        oct_shift <= p_octave;              // 网页八度优先
    else if (kbd_up_press && (oct_shift < 3'sd2))
        oct_shift <= oct_shift + 3'sd1;     // 升八度（最多 +2）
    else if (kbd_dn_press && (oct_shift > -3'sd2))
        oct_shift <= oct_shift - 3'sd1;     // 降八度（最多 -2）
end

// 当前基准音 = KBD_NOTE_LO + 12*oct_shift，限幅到 [OCT_MIN_BASE, OCT_MAX_BASE]
wire signed [9:0] oct_offs = oct_shift * 10'sd12;
wire signed [9:0] base_pre = $signed({3'b0, KBD_NOTE_LO}) + oct_offs;
wire        [6:0] base_now = (base_pre < $signed({3'b0, OCT_MIN_BASE})) ? OCT_MIN_BASE :
                             (base_pre > $signed({3'b0, OCT_MAX_BASE})) ? OCT_MAX_BASE :
                             base_pre[6:0];

// ---------- 力度：ADS1115 × 2 读 8 路压力传感器 ----------
// 每键力度来自对应通道的力峰值（30~45ms 窗口取峰值）。
//  如果 I²C 通信不正常，力度会为 0 = 按键不出声。
// 此时把 KBD_VEL_SRC 改回 0，用固定力度先确认键盘本身是好的。
wire [63:0] ads_vel;        // 每键力度 0~127：ads_vel[i*8 +: 8]
wire [7:0]  ads_vel_live;   // 实时力度（不看按键状态）
wire [63:0] ads_force;      // 每键原始力值（调试）
wire        ads_ok;         // I²C 至少成功过一次
wire [7:0]  ads_err;        // I²C 出错计数（一直涨 = 接线/地址不对）
wire [7:0]  ads_seen;       // 每通道"读到过真实压力"标志（0 = 该键还没装传感器）
wire [63:0] ads_raw;       // 调试：每通道最新原始读数（高 8 位），不管按键状态都更新
wire        ads_sda_oe, ads_scl_oe;

// inout 三态：oe=1 时拉低，oe=0 时高阻（靠上拉拉高）
// 已撤掉"引脚直通测试"--它会在调试界面里抢走 SDA/SCL，
// 导致调试界面下 I²C 反而不工作（测试 seen 能变绿，说明 I²C 本来就能通）。
// ============================================================
// I²C 地址扫描器（调试界面专用）
// ============================================================
// 进调试界面（page_dbg=1）时，SDA/SCL 交给扫描器，
// 扫 0x08~0x77，把有应答的地址显示到调试界面的 8 行里。
// 平时（page_dbg=0）扫描器空闲，总线仍归 ADS1115 驱动。
// page_dbg: 0 = 正常界面, 1 = 压力调试界面（KEY0 长按切换，逻辑在下面）
reg        page_dbg;
wire scan_sda_oe, scan_scl_oe;
wire [63:0] scan_addr_ch;
wire [7:0]  scan_found_cnt;
wire        scan_busy;

i2c_scan #(.CLK_DIV(500)) u_scan (
    .clk       (sys_clk),
    .rst_n     (sys_rst_n),
    .sda_in    (ADS_SDA),
    .scl_in    (ADS_SCL),
    .sda_oe    (scan_sda_oe),
    .scl_oe    (scan_scl_oe),
    .addr_ch   (scan_addr_ch),
    .found_cnt (scan_found_cnt),
    .busy      (scan_busy)
);

// ============================================================
// I²C 总线二选一
// ============================================================
// page_dbg=1（调试界面）-> 交给地址扫描器，扫 0x08~0x77 并显示结果
// page_dbg=0（正常界面）-> 交给 ADS1115 驱动，采压力
//
//  实际接线（用户确认）：模块 SDA -> R18，模块 SCL -> T18
// cst 已按这个交换过，所以本文件里 ADS_SDA 就是 R18。
// ============================================================
// I²C 总线：始终交给 ADS1115 驱动
// ============================================================
// （之前为了测空闲电平，在调试界面把总线强制释放，
// 结果调试界面下根本不通信、看不到数据 -- 已撤掉。）
// 测试：接模块后 R18/T18 都是 3.38V，总线电气完全正常。
assign ADS_SDA = ads_sda_oe ? 1'b0 : 1'bz;
assign ADS_SCL = ads_scl_oe ? 1'b0 : 1'bz;

// 调试界面输入 = 实时 ADC 读数 ads_raw（不按键、单捏传感器也有读数）
// dbg_force_draw 内部会对第 0 路再做 100ms 峰值保持，快速轻点也能看到。
wire [63:0] dbg_force_mux = ads_raw;

// 调试页里"绿方块"表示扫描到了至少一个器件；正常页表示 ADS 通信正常
wire i2c_ok_mux = ads_ok;     // 绿方块 = ADS 通信正常

ads1115_ctrl #(
    // I²C 速率：25kHz（CLK_DIV = 50e6/25e3/4 = 500）
      //  测试：100kHz(125) 会全失败、25kHz(500) 才稳定。
      // FPGA 内部上拉太弱（~10-50kΩ），配合杜邦线电容，
      // 100kHz 时 SDA/SCL 上升沿来不及，从机收不到正确数据。
      // -> 想让响应更快，正确做法是减少 I²C 事务数
      // （比如把 ADS 设成连续转换模式，只读结果，不再每次写配置），
      // 而不是硬提速率。
    .CLK_DIV   (500),           // 25kHz：测试只有 25kHz 稳定（50k/100k 都会偶发失败）
    .ADDR_1    (7'h48),         // #1 ADDR 接 GND
    .ADDR_2    (7'h49),         // #2 ADDR 接 VCC
    .DR_SEL    (3'd7),          // 860 SPS（最快档）
    .CH_MASK   (8'b0000_0001),  // 只扫 AIN0（其它通道悬空会采噪声，乱冒柱子）
    .FORCE_MIN (FORCE_MIN),     // 力度死区 / 传感器存在判断
    // 力度曲线现在在 ads1115_ctrl 里按 ADC 高字节分段映射，
    // 不再用 VEL_SHIFT（旧的“每 128 码 +1”在低压力区太钝）
    .FILT_SHIFT(ADS_FILT_SHIFT) // 压力条回落速度（1=最快，3=原来）
) u_ads (
    .clk       (sys_clk),
    .rst_n     (sys_rst_n),
    .sda_in    (ADS_SDA),
    .scl_in    (ADS_SCL),
    .sda_oe    (ads_sda_oe),
    .scl_oe    (ads_scl_oe),
    .key_gate  (kbd_gate),
    // 调试页（长按 KEY0）强制扫描所有使能通道：
    // 这样按其它琴键时，压力条也不会停更（解决"按几下突然不刷新"）
    .force_scan(page_dbg | ADS_SINGLE),
    .vel_ch    (ads_vel),
    .vel_live  (ads_vel_live),
    .force_ch  (ads_force),
    .data_ok   (ads_ok),
    .err_cnt   (ads_err),
    .seen_ch   (ads_seen),
    .raw_ch    (ads_raw)
);

// ============================================================
// 参数影子寄存器（sys_clk -> adc_clk）
// ============================================================
//  必须声明在第一次使用之前。
// Verilog 里"先用后声明"会生成隐式 1 位 wire，多位的信号会被截成 1 位
// （Gowin 报 EX3638）。这里 p_vib_rate(8 位) / p_kvol(64 位) 需要注意。
// 赋值统一在下面 param_regs 那一段的 always 里。
// 参数都是人手拖滑块，变化在毫秒级，直接每拍采样不会有可听影响。
// 加这一级是为了：音频通路（3.125MHz 域）的输入全部来自本域寄存器，
// 综合/时序更干净，也不会出现"某一位刚翻、另一条路径还没翻"的长路径。
reg [2:0]  p_wave, p_fm_ratio, p_fm_depth;
reg [7:0]  p_harm_att;
reg        p_vel_press, p_oneshot;
reg        p_mono, p_glide_en, p_vib_en;
reg [3:0]  p_glide_shift;
reg [7:0]  p_vib_rate;
reg [6:0]  p_vib_depth;
reg signed [5:0] p_transpose;
reg [3:0]  p_rate, p_exp;
reg [15:0] p_atk, p_dec, p_sus, p_rel;
reg [2:0]  p_mix_shift;
reg [7:0]  p_master;
reg        p_mute;
reg [63:0] p_kvol;      // 8 个键的音量，每键 8 位（0..128，128 = 原音量）
// 第三轮：八度 + 32 通道混音台 + 全局效果 / EQ
reg [511:0] p_ch_a;     // 32 × {dist[7:0], vol[7:0]}
reg [511:0] p_ch_b;     // 32 × {pha[3:0], cho[3:0], rev[3:0], echo[3:0]}
reg [511:0] p_fx;       // 32 × 16 位：0x50..0x6F 的效果 / EQ 参数
reg [6:0]   p_sustain;  // 延音踏板 0=关，1..127=释音慢化程度
// 32 声部齐奏 / 超锯齿
reg         p_uni_on;
reg  [2:0]  p_uni_layers;
reg  [6:0]  p_uni_detune;
reg  [6:0]  p_uni_mix;
// PWM 脉宽调制
reg  [7:0]  p_pwm_width;
reg  [7:0]  p_pwm_rate;
reg  [6:0]  p_pwm_depth;
// p_fx 字段下标 = 寄存器地址 - 0x50（每项 16 位）
localparam F_ECHO_ON   = 0,  F_ECHO_TIME = 1,  F_ECHO_FB  = 2,  F_ECHO_MIX  = 3;
localparam F_REV_ON    = 4,  F_REV_SIZE  = 5,  F_REV_DAMP = 6,  F_REV_MIX   = 7;
localparam F_CHO_ON    = 8,  F_CHO_RATE  = 9,  F_CHO_DEPTH= 10, F_CHO_MIX   = 11;
localparam F_PHA_ON    = 12, F_PHA_RATE  = 13, F_PHA_DEPTH= 14, F_PHA_FB    = 15;
localparam F_PHA_MIX   = 16;
localparam F_DRV_ON    = 17, F_DRV_DRIVE = 18, F_DRV_TONE = 19, F_DRV_MIX   = 20;
localparam F_LIM_ON    = 21, F_LIM_TH    = 22, F_LIM_CEIL = 23, F_LIM_REL   = 24;
localparam F_EQ_ON     = 25, F_EQ_LOW    = 26, F_EQ_LMID  = 27, F_EQ_MID    = 28;
localparam F_EQ_HMID   = 29, F_EQ_HIGH   = 30, F_EQ_OUT    = 31;

// 键盘路径的力度：接传感器后用每键独立的力度，
// 否则用固定值。注意 ads_vel 是 8 位，这里取低 7 位（0~127）。
genvar gi;
generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_vel
        // ads_vel 是打包向量：第 gi 个键的力度在 ads_vel[gi*8 +: 8]（0~127）
        //
        // 三层安全兜底（每一层都是为了让"没装传感器"时琴还能响）：
        // ① KBD_VEL_SRC = 0 -> 直接用固定力度
        // ② ads_ok = 0（I²C 不通） -> 退回固定力度
        // ③ ads_seen[gi] = 0（该通道从没读到过超过死区的压力，
        // 说明这个键还没装传感器）-> 退回固定力度
        // 缺了第 ③ 条就会出现"插上 ADS1115 但没接传感器时整台琴没声音"
        // （读回 0 -> 力度 0 -> 音量乘 0 -> 静音）。
        //
        // 第 ④ 层：力度保底。按下瞬间 ADC 还没采到、或轻按低于死区时，
        // ads_vel 可能还是 0；直接乘 0 就是"按了没声"。
        // 这里把最小力度钳到 VEL_FLOOR（默认 20），保证每次按下都有声，
        // 同时仍然是轻音，不会把轻按变成重音。
        //
        // 单传感器模式（ADS_SINGLE=1）
        // 不用 ads_vel[gi]（每键峰值），而是用 ads_vel_live：
        // 驱动每次成功读到 AIN0 都会更新它，不看按键状态。
        // 这样手里捏着传感器、另一只手按任意键，声音都会跟着传感器走，
        // 不会出现"按键界面上随机才大声一次"。
        wire [6:0] ads_v_key  = ads_vel[gi*8 +: 7];
        wire [6:0] ads_v_live = ads_vel_live[6:0];
        wire [6:0] ads_v      = ADS_SINGLE ? ads_v_live : ads_v_key;
        wire       ads_ok_sel = ADS_SINGLE ? (ads_ok && ads_seen[0])
                                           : (ads_ok && ads_seen[gi]);
        // 只在“琴”类音色（钢琴/古筝/木琴）上用压力力度；
        // 正弦、锯齿、单簧管等持续音固定 KBD_VEL，不受传感器影响。
        // vel_press_en 变成网页可控（p_vel_press），
        // 并在最后再乘一个"每键音量"（p_kvol，0~128，128=原音量）。
        wire [6:0] vel_src = (KBD_VEL_SRC && ads_ok_sel && p_vel_press)
                           ? ((ads_v < VEL_FLOOR) ? VEL_FLOOR : ads_v)
                           : KBD_VEL;
        wire [14:0] vel_gain = vel_src * p_kvol[gi*8 +: 8];   // 7bit × 8bit
        wire [7:0]  vel_sc   = vel_gain[14:7];                // 除以 128
        assign kb_vel[gi*7 +: 7] = (vel_sc > 8'd127) ? 7'd127 : vel_sc[6:0];
    end
endgenerate

// ---------- 单键测试路径已停用 ----------
// BTN / BTN2 / BTN3 三个测试按键脚已让位给钢琴键盘（KBD[3] / KBD[7] / KBD[6]），
// 所以这里不再有 button_in 实例。
// voice_alloc 仍然保留（给"键盘没启用"时的 g_alloc 分支用），
// 但它的输入接固定值 -- 在 KBD_ENABLE=1 时整块会被优化掉。
wire       src_gate     = 1'b0;
wire       src_note_on  = 1'b0;
wire       src_note_off = 1'b0;
wire [6:0] src_note     = 7'd0;

// ---------- 声部分配：把音符事件分到 NUM_VOICES 个独立声部 ----------
// 每个声部都有独立的 音高/力度/开关。原理见 voice_alloc.v 文件头
//
// 声部数：改这一个数字即可（voice_alloc / voice_meter / lcd_draw 的
// 编号位宽和计数位宽都会自动跟着变）。
//  资源提醒：每个声部约 25 寄存器 / 190 LUT / 3 DSP
// 8 声部 -> 约 2% LUT、23% DSP
// 32 声部 -> 约 20% LUT、83% DSP（正弦表已优化过，能放下但比较紧）
parameter NUM_VOICES = 32;

// 声部编号位宽（和 voice_alloc 里保持一致）
localparam VOICE_W = (NUM_VOICES <= 2)  ? 1 :
                     (NUM_VOICES <= 4)  ? 2 :
                     (NUM_VOICES <= 8)  ? 3 :
                     (NUM_VOICES <= 16) ? 4 :
                     (NUM_VOICES <= 32) ? 5 : 6;
// 复音计数位宽（和 voice_meter 里保持一致）
localparam POLY_W  = VOICE_W + 1;

wire [NUM_VOICES*7-1:0] alloc_note;     // voice_alloc 输出：各声部音高
wire [NUM_VOICES*7-1:0] alloc_vel;      // voice_alloc 输出：各声部力度
wire [NUM_VOICES-1:0]   alloc_gate;     // voice_alloc 输出：各声部开关
wire [VOICE_W-1:0]      cur_voice;      // 当前分配的声部号
wire                    any_gate;       // 有任一声部在响

// ---- 下面三个是最终送给振荡器组的信号：按键键盘 or 单键/ADC 二选一 ----
wire [NUM_VOICES*7-1:0] v_note;         // 各声部音高（每个 7 位）
wire [NUM_VOICES*7-1:0] v_vel;          // 各声部力度
wire [NUM_VOICES-1:0]   v_gate;         // 各声部开关

// 单键/ADC 路径的力度（这条路径已停用，voice_alloc 只作兜底）
//  必须声明在例化之前：Verilog 里"先用后声明"会被当成隐式 1 位 wire，
// 之后真正的声明会被忽略（Gowin 报 EX3638 / EX1998）。
wire [6:0] src_vel_use = KBD_VEL;

voice_alloc #(
    .NUM_VOICES (NUM_VOICES)
) u_voice_alloc (
    .clk       (adc_clk),
    .rst_n     (sys_rst_n),
    .note_on   (src_note_on),
    .note_off  (src_note_off),
    .gate_in   (src_gate),
    .note_in   (src_note),
    .vel_in    (src_vel_use),       // 键盘/传感器路径的力度（原来固定值也走这里）
    .v_note    (alloc_note),
    .v_vel     (alloc_vel),
    .v_gate    (alloc_gate),
    .cur_voice (cur_voice),
    .any_gate  (any_gate)
);

// ============================================================
// 最终声部信号选择：键盘（每键独占一声部） / 单键+ADC（走 voice_alloc）
// ============================================================
// KBD_ENABLE = 1 时：8 个琴键顺序占用声部 0~7。
// keyboard_in 的 note_out 是"第 i 键 = note_out[i*7 +: 7]"，
// 第 i 键的度数就是 i（0=C..7=高八度 C），所以音高天然从低到高。
// 声部 gv 直接取第 gv 个键即可。
//
// 八度切换：kb_note 里存的是"基准音 + 白键偏移"，
// 这里再统一加上 12*oct_shift，让 8 个键一起升降八度。
// 最后限幅到 osc_voice 支持的音域（48..95）。
//
// KBD_ENABLE = 0 时：完全沿用原来单键/ADC 的行为。
localparam [6:0] NOTE_MIN = 7'd24;      // 音域下限（允许八度 -2 + 变调 -12）
localparam [6:0] NOTE_MAX = 7'd108;     // 音域上限（允许八度 +2 + 变调 +12）

// 把某个声部拿到的原始音加上八度偏移 + 实时变调，并限幅
// tr 是演奏效果里的"实时变调"（有符号 -12..+12 半音）。
// 改成用参数传进来，避免函数里引用后面才声明的寄存器。
function [6:0] apply_oct;
    input [6:0] n;
    input [5:0] tr;
    reg  [8:0] t;
    reg signed [10:0] s;
    begin
        // 必须用完整的 oct_offs（有符号 10 位）：
        // 旧写法只取 oct_offs[7:0] 再补 0，负八度（-12）会变成 +244，
        // 表现为"降八度反而跳到很高"。这里改成 11 位有符号相加。
        s = $signed({4'b0, n}) + $signed(oct_offs) + $signed(tr);
        if (s < $signed({4'b0, NOTE_MIN}))      apply_oct = NOTE_MIN;
        else if (s > $signed({4'b0, NOTE_MAX})) apply_oct = NOTE_MAX;
        else                                    apply_oct = s[6:0];
    end
endfunction

// ============================================================
// 单音模式（Mono）的"最后按键优先"跟踪
// ============================================================
// 所有键共用一条声部：后按的键接管音高。只要还有键按着，
// gate 就保持为高 -> 包络不重触发、相位不归零 -> 音高实时改变。
// 这就是"单音实时变调"；打开滑音后，音高会滑过去。
// 优先级：最后按下的键；它松开后回落到当前按着的、编号最小的键。
function [2:0] low_idx;
    input [7:0] v;
    integer i;
    begin
        low_idx = 3'd0;
        for (i = 7; i >= 0; i = i - 1)
            if (v[i]) low_idx = i[2:0];
    end
endfunction

reg [2:0] mono_idx;
reg       mono_valid;

always @(posedge adc_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        mono_idx   <= 3'd0;
        mono_valid <= 1'b0;
    end else begin
        if (kbd_press != 8'd0) begin
            // 有新键按下：最后按键优先
            mono_idx   <= low_idx(kbd_press);
            mono_valid <= 1'b1;
        end else if (!mono_valid || !kbd_gate[mono_idx]) begin
            // 当前键松开了：回落到还按着的键（没有就整体静音）
            if (kbd_gate != 8'd0) begin
                mono_idx   <= low_idx(kbd_gate);
                mono_valid <= 1'b1;
            end else begin
                mono_valid <= 1'b0;
            end
        end
    end
end

// 只要还有键按着，单音 gate 就保持为高（换键时不重触发包络）
wire        mono_gate = mono_valid && (kbd_gate != 8'd0);
wire [6:0]  mono_note = apply_oct(kb_note[mono_idx*7 +: 7], p_transpose);
wire [6:0]  mono_vel  = kb_vel[mono_idx*7 +: 7];

genvar gv;
generate
    for (gv = 0; gv < NUM_VOICES; gv = gv + 1) begin : g_vsel
        if ((gv < 8) && KBD_ENABLE) begin : g_kbd
            // 键盘接入：第 gv 声部 = 第 gv 个键（KBD[0] 就是最低音）
            // 单音模式：只有 0 号声部发声，音高/力度由 mono_idx 决定；
            // 其余声部强制静音（它们的音符/力度仍接键盘，方便切回复音）。
            if (gv == 0) begin : g_mono0
                assign v_note[gv*7 +: 7] = p_mono ? mono_note : apply_oct(kb_note[0*7 +: 7], p_transpose);
                assign v_vel [gv*7 +: 7] = p_mono ? mono_vel  : kb_vel [0*7 +: 7];
                assign v_gate[gv]        = p_mono ? mono_gate : kbd_gate[0];
            end else begin : g_poly
                assign v_note[gv*7 +: 7] = apply_oct(kb_note[gv*7 +: 7], p_transpose);
                assign v_vel [gv*7 +: 7] = kb_vel [gv*7 +: 7];
                assign v_gate[gv]        = p_mono ? 1'b0 : kbd_gate[gv];
            end
        end else begin : g_alloc
            assign v_note[gv*7 +: 7] = alloc_note[gv*7 +: 7];
            assign v_vel [gv*7 +: 7] = alloc_vel [gv*7 +: 7];
            assign v_gate[gv]        = alloc_gate[gv];
        end
    end
endgenerate

// ---------- 音频采样率使能 ----------
// adc_clk = 3.125MHz，除以 64 -> 48828.125 Hz 采样率
// （若改采样率，osc_voice.v 里的 base_inc[] 要按新采样率重算）
localparam SAMPLE_DIV = 64;

reg [5:0] smp_cnt;
reg       sample_en;

always @(posedge adc_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        smp_cnt   <= 6'd0;
        sample_en <= 1'b0;
    end else if (smp_cnt == SAMPLE_DIV - 1) begin
        smp_cnt   <= 6'd0;
        sample_en <= 1'b1;
    end else begin
        smp_cnt   <= smp_cnt + 1'b1;
        sample_en <= 1'b0;
    end
end

// ============================================================
// 全局颤音 LFO
// ============================================================
// 所有声部共用同一个 LFO；深度/速率来自网页的 VIB_* 寄存器。
// LFO 输出的是一个带符号的"相位增量调制量"，送进每个 osc_voice。
wire signed [7:0] vib_delta;

vib_lfo u_vib_lfo (
    .clk       (adc_clk),
    .rst_n     (sys_rst_n),
    .sample_en (sample_en),
    .rate      (p_vib_rate),
    .depth     (p_vib_depth),
    .enable    (p_vib_en),
    .delta     (vib_delta)
);

// PWM 专用 LFO（速率/深度独立于颤音）
wire signed [7:0] pwm_lfo;
vib_lfo u_pwm_lfo (
    .clk       (adc_clk),
    .rst_n     (sys_rst_n),
    .sample_en (sample_en),
    .rate      (p_pwm_rate),
    .depth     (p_pwm_depth),
    .enable    (1'b1),
    .delta     (pwm_lfo)
);

// ============================================================
// 参数控制：UART + 网页控制台
// ============================================================
// 数据流：
// 网页 --Web Serial--> COMx（板载 DEBUG-USB2 的 BL616 USB-UART）
// --> UART_RX --> uart_rx --> param_regs（协议 / 寄存器 / 预设）
// --> 参数影子寄存器（sys_clk -> adc_clk）
// --> 振荡器 / 包络 / 混音
//
// FPGA --(每 ~42ms)--> param_regs 组遥测帧 --> uart_tx --> UART_TX --> 网页
//
// 寄存器表 / 帧格式 / 音色预设：见 src/param_regs.v 文件头
//
// KEY0 仍然可用：
// 短按 -> 换音色（1锯齿 -> 3正弦 -> 4钢琴 -> 5古筝 -> 6木琴 -> 7单簧管 -> 1）
// 长按 -> 切压力调试界面（HDMI 上显示）
// 换音色的"真值"现在住在 param_regs 里，这里只发一个"换音色请求"。
// ============================================================
wire [7:0] urx_data;
wire       urx_valid;

uart_rx #(
    .CLK_HZ (50_000_000),
    .BAUD   (115_200)
) u_uart_rx (
    .clk   (sys_clk),
    .rst_n (sys_rst_n),
    .rx    (UART_RX),
    .data  (urx_data),
    .valid (urx_valid)
);

wire [7:0] utx_data;
wire       utx_send;
wire       utx_ready;

uart_tx #(
    .CLK_HZ (50_000_000),
    .BAUD   (115_200)
) u_uart_tx (
    .clk   (sys_clk),
    .rst_n (sys_rst_n),
    .data  (utx_data),
    .send  (utx_send),
    .tx    (UART_TX),
    .ready (utx_ready)
);

// KEY0 换音色请求（adc_clk 域 -> param_regs 的 sys_clk 域）
reg        key_timbre_tog;
reg [3:0]  key_timbre_val;

// 遥测快照（adc_clk 域打包，约 24Hz 更新一次）
reg [63:0] telem_snap;
reg        telem_tog;
reg [16:0] telem_div;

// param_regs 输出的实时参数
wire [3:0]  pr_timbre;
wire [2:0]  pr_wave, pr_fm_ratio, pr_fm_depth;
wire [7:0]  pr_harm_att;
wire        pr_vel_press, pr_oneshot;
wire        pr_mono, pr_glide_en, pr_vib_en;
wire [3:0]  pr_glide_shift;
wire [7:0]  pr_vib_rate;
wire [6:0]  pr_vib_depth;
wire [5:0]  pr_transpose;
wire [3:0]  pr_rate, pr_exp;
wire [15:0] pr_atk, pr_dec, pr_sus, pr_rel;
wire [2:0]  pr_mix_shift;
wire [7:0]  pr_master;
wire        pr_mute;
wire [63:0] pr_key_vol;
wire signed [2:0] pr_octave;
wire        pr_oct_tog;
wire [6:0]  pr_sustain;
wire        pr_uni_on;
wire [2:0]  pr_uni_layers;
wire [6:0]  pr_uni_detune, pr_uni_mix;
wire [7:0]  pr_pwm_width, pr_pwm_rate;
wire [6:0]  pr_pwm_depth;
wire [511:0] pr_ch_a, pr_ch_b, pr_fx;
wire [7:0]  pr_rx_err;
wire [15:0] pr_set_cnt;

param_regs #(
    .CLK_HZ (50_000_000)
) u_params (
    .clk            (sys_clk),
    .rst_n          (sys_rst_n),
    .rx_data        (urx_data),
    .rx_valid       (urx_valid),
    .tx_data        (utx_data),
    .tx_send        (utx_send),
    .tx_busy        (~utx_ready),
    .key_timbre_tog (key_timbre_tog),
    .key_timbre_val (key_timbre_val),
    .telem_snap     (telem_snap),
    .telem_tog      (telem_tog),
    .o_timbre       (pr_timbre),
    .o_wave         (pr_wave),
    .o_fm_ratio     (pr_fm_ratio),
    .o_fm_depth     (pr_fm_depth),
    .o_harm_att     (pr_harm_att),
    .o_vel_press    (pr_vel_press),
    .o_oneshot      (pr_oneshot),
    .o_mono         (pr_mono),
    .o_glide_en     (pr_glide_en),
    .o_glide_shift  (pr_glide_shift),
    .o_vib_en       (pr_vib_en),
    .o_vib_rate     (pr_vib_rate),
    .o_vib_depth    (pr_vib_depth),
    .o_transpose    (pr_transpose),
    .o_octave       (pr_octave),
    .o_oct_tog      (pr_oct_tog),
    .o_sustain      (pr_sustain),
    .o_uni_on       (pr_uni_on),
    .o_uni_layers   (pr_uni_layers),
    .o_uni_detune   (pr_uni_detune),
    .o_uni_mix      (pr_uni_mix),
    .o_pwm_width    (pr_pwm_width),
    .o_pwm_rate     (pr_pwm_rate),
    .o_pwm_depth    (pr_pwm_depth),
    .o_ch_a         (pr_ch_a),
    .o_ch_b         (pr_ch_b),
    .o_fx           (pr_fx),
    .o_rate         (pr_rate),
    .o_exp          (pr_exp),
    .o_atk          (pr_atk),
    .o_dec          (pr_dec),
    .o_sus          (pr_sus),
    .o_rel          (pr_rel),
    .o_mix_shift    (pr_mix_shift),
    .o_master       (pr_master),
    .o_mute         (pr_mute),
    .o_key_vol      (pr_key_vol),
    .o_rx_err       (pr_rx_err),
    .o_set_cnt      (pr_set_cnt)
);

// ============================================================
// 参数影子寄存器：赋值（声明在文件靠前的位置，必须在首次使用之前）
// ============================================================
always @(posedge adc_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        p_wave      <= 3'd1;
        p_fm_ratio  <= 3'd1;
        p_fm_depth  <= 3'd2;
        p_harm_att  <= 8'd0;
        p_vel_press <= 1'b0;
        p_oneshot   <= 1'b0;
        p_mono      <= 1'b0;
        p_glide_en  <= 1'b0;
        p_glide_shift <= 4'd10;
        p_vib_en    <= 1'b0;
        p_vib_rate  <= 8'd55;
        p_vib_depth <= 7'd40;
        p_transpose <= 6'sd0;
        p_rate      <= 4'd0;
        p_exp       <= 4'd0;
        p_atk       <= 16'd67;
        p_dec       <= 16'd7;
        p_sus       <= 16'd45874;
        p_rel       <= 16'd4;
        p_mix_shift <= 3'd2;
        p_master    <= 8'd255;
        p_mute      <= 1'b0;
        p_kvol      <= {8{8'd128}};
        p_ch_a      <= {32{16'h0080}};   // 32 通道：音量 128、失真 0
        p_ch_b      <= 512'd0;           // 32 通道：4 路发送全 0
        p_fx        <= 512'd0;           // 下一拍由 param_regs 的出厂值覆盖
        p_octave    <= 3'sd0;
        p_sustain   <= 7'd0;
        p_uni_on    <= 1'b1;
        p_uni_layers<= 3'd4;
        p_uni_detune<= 7'd48;
        p_uni_mix   <= 7'd48;
        p_pwm_width <= 8'd128;
        p_pwm_rate  <= 8'd30;
        p_pwm_depth <= 7'd64;
        p_oct_tog_s1 <= 1'b0;
        p_oct_tog_s2 <= 1'b0;
        p_oct_tog_d  <= 1'b0;
    end else begin
        p_wave      <= pr_wave;
        p_fm_ratio  <= pr_fm_ratio;
        p_fm_depth  <= pr_fm_depth;
        p_harm_att  <= pr_harm_att;
        p_vel_press <= pr_vel_press;
        p_oneshot   <= pr_oneshot;
        p_mono      <= pr_mono;
        p_glide_en  <= pr_glide_en;
        p_glide_shift <= pr_glide_shift;
        p_vib_en    <= pr_vib_en;
        p_vib_rate  <= pr_vib_rate;
        p_vib_depth <= pr_vib_depth;
        p_transpose <= pr_transpose;
        p_rate      <= pr_rate;
        p_exp       <= pr_exp;
        p_atk       <= pr_atk;
        p_dec       <= pr_dec;
        p_sus       <= pr_sus;
        p_rel       <= pr_rel;
        p_mix_shift <= pr_mix_shift;
        p_master    <= pr_master;
        p_mute      <= pr_mute;
        p_kvol      <= pr_key_vol;
        p_ch_a      <= pr_ch_a;
        p_ch_b      <= pr_ch_b;
        p_fx        <= pr_fx;
        p_octave    <= pr_octave;
        p_sustain   <= pr_sustain;
        p_uni_on    <= pr_uni_on;
        p_uni_layers<= pr_uni_layers;
        p_uni_detune<= pr_uni_detune;
        p_uni_mix   <= pr_uni_mix;
        p_pwm_width <= pr_pwm_width;
        p_pwm_rate  <= pr_pwm_rate;
        p_pwm_depth <= pr_pwm_depth;
        // 网页八度写入的翻转位：两级同步 + 边沿检测（1 位 CDC，安全）
        p_oct_tog_s1 <= pr_oct_tog;
        p_oct_tog_s2 <= p_oct_tog_s1;
        p_oct_tog_d  <= p_oct_tog_s2;
    end
end


// ============================================================
// KEY0：短按换音色 / 长按切压力调试界面
// ============================================================
// 去抖 21ms（KEY_DBNC_MAX = 65535 @ 3.125MHz）
// 长按判定 0.8s（KEY_LONG = 2.5e6 @ 3.125MHz）
// 音色循环顺序不变：1 -> 3 -> 4 -> 5 -> 6 -> 7 -> 1（跳过 0 方波 / 2 三角）
localparam [15:0] KEY_DBNC_MAX = 16'hFFFF;
localparam [21:0] KEY_LONG     = 22'd2_500_000;

reg [15:0] key_cnt;
reg        key_state, key_prev;
reg [21:0] key_hold;
// 注意：page_dbg 在本文件靠前的位置（I²C 扫描器那段）已经声明过了，
// 这里只负责在 KEY0 长按时翻转它，不要重复声明。

// 下一个音色：0..9 循环
wire [3:0] timbre_next = (pr_timbre >= 4'd9) ? 4'd0 : (pr_timbre + 4'd1);

always @(posedge adc_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        key_cnt        <= 16'd0;
        key_state      <= 1'b1;      // 上拉，未按下 = 1
        key_prev       <= 1'b1;
        key_hold       <= 22'd0;
        page_dbg       <= 1'b0;
        key_timbre_tog <= 1'b0;
        key_timbre_val <= 4'd1;
    end else begin
        // 去抖：电平与当前状态不同就计时，连续满 21ms 才认账
        if (KEY0 != key_state) begin
            if (key_cnt == KEY_DBNC_MAX) begin
                key_state <= KEY0;
                key_cnt   <= 16'd0;
            end else begin
                key_cnt <= key_cnt + 16'd1;
            end
        end else begin
            key_cnt <= 16'd0;
        end

        // 按住时长
        if (!key_state) begin
            if (!(&key_hold)) key_hold <= key_hold + 22'd1;
        end else begin
            key_hold <= 22'd0;
        end

        // 松开沿：短按换音色，长按切调试页
        key_prev <= key_state;
        if (~key_prev & key_state) begin
            if (key_hold >= KEY_LONG) begin
                page_dbg <= ~page_dbg;
            end else begin
                key_timbre_val <= timbre_next;
                key_timbre_tog <= ~key_timbre_tog;
            end
        end
    end
end

// ============================================================
// 遥测快照：给网页的"实时监视"（力度 / 复音数 / I²C 状态 / 按键）
// ============================================================
// 速度：131072 拍 @ 3.125MHz ≈ 41.9ms ≈ 23.8Hz
// 打包格式（64 位，和 param_regs.v 的拆包一一对应）：
// [7:0] ads_vel [15:8] ads_raw
// [21:16] poly [27:22] poly_peak
// [30:28] oct_shift [38:31] key_mask
// [39] ads_ok [40] page_dbg [41] ads_seen[0]
// [49:42] ads_err [63:50] 保留
always @(posedge adc_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        telem_div  <= 17'd0;
        telem_tog  <= 1'b0;
        telem_snap <= 64'd0;
    end else begin
        telem_div <= telem_div + 17'd1;
        if (telem_div == 17'd0) begin
            telem_snap <= { 14'd0,
                            ads_err,
                            ads_seen[0],
                            page_dbg,
                            ads_ok,
                            kbd_gate,
                            oct_shift,
                            poly_peak,
                            poly_now,
                            ads_raw[7:0],
                            ads_vel_live };
            telem_tog <= ~telem_tog;
        end
    end
end

// ---------- 延音踏板：p_sustain 0=关，越大释音越慢 ----------
// 只对 one-shot 音色（钢琴/古筝/木琴）生效；4 倍慢速：
// 步长 32..1、默认 40（步长 22）大致 1.3s..43s（钢琴 env_rate=3）。
wire        pedal_en   = (p_sustain != 7'd0) && p_oneshot;  // 只对 one-shot 音色生效
wire [6:0]  pedal_step7 = (p_sustain >= 7'd4) ? (7'd32 - (p_sustain >> 2)) : 7'd32;
wire [15:0] pedal_step  = {9'd0, pedal_step7};

wire [NUM_VOICES*16-1:0] pcm_bus;        // 第 i 路：pcm_bus[i*16 +: 16]
wire [NUM_VOICES*16-1:0] env_bus;        // 第 i 路包络（调试用）
wire [NUM_VOICES*24-1:0] inc_bus;        // 各声部当前相位增量（给齐奏用）

synth_voices #(
    .NUM_VOICES (NUM_VOICES),
    .PHASE_BITS (24)
) u_synth (
    .clk        (adc_clk),
    .rst_n      (sys_rst_n),
    .sample_en  (sample_en),
    .v_note     (v_note),
    .v_vel      (v_vel),
    .v_gate     (v_gate),
    .wave_sel   (p_wave),       // 0方波 1锯齿 2三角 3正弦 4钢琴(加法) 5FM
    // 下面这些全部来自网页控制台（参数影子寄存器）
    .fm_ratio   (p_fm_ratio),   // FM 调制比档位
    .fm_depth   (p_fm_depth),   // FM 调制深度
    .harm_att   (p_harm_att),   // 钢琴 4 个泛音的独立衰减
    .glide_en   (p_glide_en),   // 滑音
    .glide_shift(p_glide_shift),
    .vib_delta  (vib_delta),    // 全局颤音 LFO
    .pwm_width  (p_pwm_width),
    .pwm_mod    (pwm_lfo),
    .pwm_depth  (p_pwm_depth),
    .env_rate   (p_rate),
    .env_exp    (p_exp),        // 0=线性；>0=指数衰减
    .env_oneshot(p_oneshot),    // 1=衰减到 0 自己结束
    .pedal_en   (pedal_en),     // 延音踏板
    .pedal_step (pedal_step),
    .atk_step   (p_atk),
    .dec_step   (p_dec),
    .sus_level  (p_sus),
    .rel_step   (p_rel),
    .pcm_bus    (pcm_bus),      // 这 8 路 PCM 交给后面的"混音+限幅"模块
    .env_bus    (env_bus),
    .inc_bus    (inc_bus)
);

// ============================================================
// 32 声部齐奏 / 超锯齿（8 键 × 4 层）
// ============================================================
// 主声部仍然是上面的 osc_voice（第 1 层）；unison_saw 再给每个键生成
// 3 个微失谐锯齿层，共用主声部的 env/velocity，所以不需要 24 套 ADSR。
// 附加层 PCM 加回对应声部，再进 fx_chain 的通道条。
wire [8*16-1:0] uni_pcm;

unison_saw #(
    .NUM_KEYS (8)
) u_unison (
    .clk        (adc_clk),
    .rst_n      (sys_rst_n),
    .sample_en  (sample_en),
    .on         (p_uni_on),
    .layers     (p_uni_layers),
    .detune     (p_uni_detune),
    .mix        (p_uni_mix),
    .inc_bus    (inc_bus[8*24-1:0]),
    .gate       (v_gate[7:0]),
    .vel_bus    (v_vel[8*7-1:0]),
    .env_bus    (env_bus[8*16-1:0]),
    .pcm_bus_out(uni_pcm)
);

// 主声部 + 3 个附加层 -> 每键一路（饱和，防止相加溢出）
wire [NUM_VOICES*16-1:0] pcm_fx_bus;
genvar gu;
generate
    for (gu = 0; gu < NUM_VOICES; gu = gu + 1) begin : g_uni_add
        if (gu < 8) begin : g_add
            wire signed [16:0] sum17 = $signed(pcm_bus[gu*16 +: 16])
                                      + $signed(uni_pcm[gu*16 +: 16]);
            assign pcm_fx_bus[gu*16 +: 16] = (sum17 > 17'sd32767)  ? 16'sh7FFF :
                                             (sum17 < -17'sd32768) ? 16'sh8000 :
                                             sum17[15:0];
        end else begin : g_passth
            assign pcm_fx_bus[gu*16 +: 16] = pcm_bus[gu*16 +: 16];
        end
    end
endgenerate

// ---------- LED 显示 ----------
// 现在显示当前音色号：LEDs[2:0] = pr_timbre[2:0]（0~9，8/9 显示 0/1）。
// 按 KEY0 或网页切换音色，LED 都直接反映。
// 000 方波 001 锯齿 010 三角 011 正弦
// 100 钢琴 101 古筝 110 木琴 111 单簧管
// 排查"没声音 / 松手还响"时，可以临时换回：
// assign LEDs = {3{any_gate}};
// 其它常用选择：
// {cur_voice} 当前声部号 / {2'b0, poly_now} 当前复音数
assign LEDs = pr_timbre[2:0];

// ============================================================
// 混音台 + 效果链（第三轮）
// ============================================================
// 32 声部 PCM -> 每通道（音量 / 失真 / 4 路发送）
// -> 全局回声 / 混响 / 合唱 / 相位（发送式）
// -> 主失真 -> 5 段 EQ -> 限幅 -> 主音量
// -> PT8211
//
// 寄存器：0x50..0x6F 全局效果/EQ，0x80..0x9F / 0xA0..0xBF 通道参数。
// 参数含义见 src/fx_chain.v 和 web/README.md。
// ============================================================
wire signed [15:0] mix_pcm;      // 最终 PCM（已含效果 / EQ / 限幅 / 主音量）
wire               mix_valid;

fx_chain #(
    .NUM_VOICES (NUM_VOICES),
    .MIX_CH     (8)              // 当前键盘 8 键；9..32 声部在网页里折叠保留
) u_fx (
    .clk        (adc_clk),
    .rst_n      (sys_rst_n),
    .sample_en  (sample_en),
    .pcm_bus    (pcm_fx_bus),
    .ch_a       (p_ch_a),
    .ch_b       (p_ch_b),
    .mix_shift  (p_mix_shift),
    .master     (p_master),
    .mute       (p_mute),
    // 回声
    .echo_on    (p_fx[F_ECHO_ON  *16]),
    .echo_time  (p_fx[F_ECHO_TIME*16 +: 8]),
    .echo_fb    (p_fx[F_ECHO_FB  *16 +: 4]),
    .echo_mix   (p_fx[F_ECHO_MIX *16 +: 7]),
    // 混响
    .rev_on     (p_fx[F_REV_ON   *16]),
    .rev_size   (p_fx[F_REV_SIZE *16 +: 7]),
    .rev_damp   (p_fx[F_REV_DAMP *16 +: 7]),
    .rev_mix    (p_fx[F_REV_MIX  *16 +: 7]),
    // 合唱
    .cho_on     (p_fx[F_CHO_ON   *16]),
    .cho_rate   (p_fx[F_CHO_RATE *16 +: 7]),
    .cho_depth  (p_fx[F_CHO_DEPTH*16 +: 7]),
    .cho_mix    (p_fx[F_CHO_MIX  *16 +: 7]),
    // 相位
    .pha_on     (p_fx[F_PHA_ON   *16]),
    .pha_rate   (p_fx[F_PHA_RATE *16 +: 7]),
    .pha_depth  (p_fx[F_PHA_DEPTH*16 +: 7]),
    .pha_fb     (p_fx[F_PHA_FB   *16 +: 4]),
    .pha_mix    (p_fx[F_PHA_MIX  *16 +: 7]),
    // 失真
    .drv_on     (p_fx[F_DRV_ON   *16]),
    .drv_drive  (p_fx[F_DRV_DRIVE*16 +: 7]),
    .drv_tone   (p_fx[F_DRV_TONE *16 +: 7]),
    .drv_mix    (p_fx[F_DRV_MIX  *16 +: 7]),
    // 限幅
    .lim_on     (p_fx[F_LIM_ON   *16]),
    .lim_th     (p_fx[F_LIM_TH   *16 +: 8]),
    .lim_ceil   (p_fx[F_LIM_CEIL *16 +: 8]),
    .lim_rel    (p_fx[F_LIM_REL  *16 +: 7]),
    // 均衡
    .eq_on      (p_fx[F_EQ_ON    *16]),
    .eq_low     (p_fx[F_EQ_LOW   *16 +: 6]),
    .eq_lmid    (p_fx[F_EQ_LMID  *16 +: 6]),
    .eq_mid     (p_fx[F_EQ_MID   *16 +: 6]),
    .eq_hmid    (p_fx[F_EQ_HMID  *16 +: 6]),
    .eq_high    (p_fx[F_EQ_HIGH  *16 +: 6]),
    .eq_out     (p_fx[F_EQ_OUT   *16 +: 8]),
    .pcm_out    (mix_pcm),
    .pcm_valid  (mix_valid)
);

// 不再用"没有 gate 就强制静音"的保险门：
// 回声/混响的尾音需要在松手后继续响。声部本身的包络归零后 PCM 就是 0，
// 效果器反馈也都 <1，不会自激。若以后又出现"松手长鸣"，先查 adsr 包络。
wire signed [15:0] mix_out = mix_pcm;
// ---------- PT8211 音频 DAC 发送：-> 立体声 DAC -> NS4263 功放 -> 耳机/扬声器 ----------
//  PT8211 不是标准 I2S：WS 高=左/低=右，MSB 无延迟，每帧 32 个 BCK
// 时钟：BCK = 50MHz/32 = 1.5625MHz，一帧 32 个 BCK -> 采样率 48828.125Hz
i2s_tx u_i2s (
    .clk     (sys_clk),
    .rst_n   (sys_rst_n),
    .pcm_in  (mix_out),
    .bck     (HP_BCK),
    .ws      (HP_WS),
    .din     (HP_DIN)
);

// PA_EN 低有效：拉低开功放（原理图：PA_EN=0 -> PA ON）
assign PA_EN = 1'b0;

// ============================================================
// LCD 显示：音频波形 + 复音数
// ============================================================
// 面板：5 寸 IPS 1024x600（RGB TTL 40pin FPC 座 J5 + GT911 触摸）
//
// 像素时钟 = sys_clk = 50MHz 直接驱动（不分频、不加 PLL）
// 消隐参数 Htotal=1224 / Vtotal=640 -> 刷新率 ≈63.8Hz
// 规格书表 8.3：CLKIN 周期 ≥14ns（最高 71.4MHz），50MHz 完全在范围内。
//
//  时序约束靠 SDC：
// src/fpga_project.sdc 里分别声明 sys_clk=50MHz、adc_clk=3.125MHz。
// 没有 SDC 时工具会把整颗设计（含只有 3.125MHz 的音频链路）
// 都按 50MHz 去优化，那条 36ns 的混音加法链永远不满足，PnR 会卡死/崩溃。
wire pclk = sys_clk;            // 像素时钟 = 50MHz


// ---------- 波形采集：把混音后的 PCM 存进环形缓冲 ----------
//  注意：
// scope_capture 里是组合读的寄存器数组（assign rd_data = mem[rd_addr]），
// 综合器无法把它推断成 BSRAM，只能烧寄存器：
// BUF_AW = 10 -> 1024×16 ≈ 1.0 万寄存器（能放下，但已经很满）
// BUF_AW = 12 -> 4096×16 ≈ 3.3 万寄存器（器件装不下，布局直接失败）
// 测试 BUF_AW=12 时报：
// ERROR (PR0003) : Failed to place with '533 REG(s) unPlaced'
// 所以这里保持 10。想加大缓冲，必须先把 scope_capture 改成
// BSRAM 结构（读地址寄存一拍、输出用同步读），再用 -ram_style block_ram。
localparam BUF_AW = 10;         // 1024 个采样 ≈ 21ms
localparam DISP_W = 800;        // 波形显示宽度（屏幕 1024 宽，这里先铺 800）
                                // 想铺满 1024，要把 DISP_W 改成 1024 且
                                // BUF_AW ≥ 10（WRAP 不能为负）-- 但见上面的坑

wire [BUF_AW-1:0]  buf_addr;      // LCD 绘制用的读地址
wire signed [15:0] buf_data;      // LCD 绘制用的读数据
wire [BUF_AW-1:0]  buf_addr2;     // HDMI 绘制用的读地址（第二读口）
wire signed [15:0] buf_data2;     // HDMI 绘制用的读数据
wire [BUF_AW-1:0]  wr_ptr;

scope_capture #(
    .BUF_AW (BUF_AW)     // 4096 个采样 ≈ 84ms（够填满 1024 像素）
) u_scope (
    .clk          (adc_clk),
    .rst_n        (sys_rst_n),
    .sample_valid (sample_en),
    .sample_in    (mix_pcm),
    .rd_addr      (buf_addr),
    .rd_data      (buf_data),
    .rd_addr2     (buf_addr2),
    .rd_data2     (buf_data2),
    .wr_ptr       (wr_ptr)
);

// ---------- 复音数统计 ----------
wire [POLY_W-1:0] poly_now, poly_peak;   // 当前/峰值复音数

voice_meter #(
    .NUM_VOICES (NUM_VOICES)
) u_meter (
    .clk        (adc_clk),
    .rst_n      (sys_rst_n),
    .sample_en  (sample_en),
    .peak_clr   (1'b0),
    .v_gate     (v_gate),
    .active_cnt (poly_now),
    .peak_cnt   (poly_peak)
);

// ---------- RGB 时序发生器（已恢复）----------
// 恢复的原因：为了做对照实验。
// 22:55 那版LCD + HDMI 彩条同时工作时 HDMI 是正常的；
// 之后我删掉了 LCD 这套，HDMI 就再也点不亮（引脚/时钟/资源都查过没问题）。
// 所以先把 LCD 恢复成完全等价的状态，验证"是不是删 LCD 引起的"。
wire [11:0] lcd_x, lcd_y;
wire        lcd_de;
wire        lcd_frame;
wire        lcd_hsync, lcd_vsync;

lcd_timing #(
    .H_ACTIVE   (1024),
    .H_FP       (24),
    .H_SYNC     (136),
    .H_BP       (160),
    .V_ACTIVE   (600),
    .V_FP       (3),
    .V_SYNC     (6),
    .V_BP       (29),
    .HSYNC_LOW  (1'b1),
    .VSYNC_LOW  (1'b1)
) u_lcd_timing (
    .pclk        (pclk),
    .rst_n       (sys_rst_n),
    .hsync       (lcd_hsync),
    .vsync       (lcd_vsync),
    .de          (lcd_de),
    .x           (lcd_x),
    .y           (lcd_y),
    .frame_start (lcd_frame)
);


// ---------- 帧起点锁存写指针 ----------
// wr_ptr 在 adc_clk 域产生，这里在 pclk 域每帧取一次。
reg [BUF_AW-1:0] wr_ptr_lat;
always @(posedge pclk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        wr_ptr_lat <= {BUF_AW{1'b0}};
    else if (lcd_frame)
        wr_ptr_lat <= wr_ptr;
end

// ---------- 逐像素绘制 ----------
wire [17:0] lcd_rgb;        // RGB666
wire        lcd_de_r;

lcd_draw #(
    .H_ACTIVE   (1024),
    .V_ACTIVE   (600),
    .BUF_AW     (BUF_AW),
    .DISP_W     (DISP_W),
    .NUM_VOICES (NUM_VOICES),
    .AMP_SHIFT  (8),
    .TOP_H      (134),
    .ROTATE     (0),
    .MIRROR_X   (1'b0),
    .MIRROR_Y   (1'b0),
    .KBD_N      (8),
    .KBD_NOTE_LO(KBD_NOTE_LO),
    .KBD_REVERSE(KBD_REVERSE)
) u_lcd_draw (
    .pclk       (pclk),
    .rst_n      (sys_rst_n),
    .x          (lcd_x),
    .y          (lcd_y),
    .de         (lcd_de),
    .buf_addr   (buf_addr),
    .buf_data   (buf_data),
    .wr_ptr     (wr_ptr_lat),
    .v_gate     (v_gate),
    .active_cnt (poly_now),
    .peak_cnt   (poly_peak),
    .kbd_gate   (kbd_gate),
    .dbg_force  (ads_raw),
    .rgb        (lcd_rgb),
    .de_out     (lcd_de_r)
);

// ---------- LCD 输出寄存器 ----------
reg [18:0] lcd_dout_r;
always @(posedge pclk or negedge sys_rst_n) begin
    if (!sys_rst_n) lcd_dout_r <= 19'd0;
    else            lcd_dout_r <= {lcd_rgb, lcd_de_r};
end

assign LCD_CLK   = pclk;
assign LCD_HSYNC = lcd_hsync;
assign LCD_VSYNC = lcd_vsync;
assign LCD_DEN   = lcd_dout_r[0];
assign LCD_R     = lcd_dout_r[18:13];
assign LCD_G     = lcd_dout_r[12:7];
assign LCD_B     = lcd_dout_r[6:1];
assign LCD_BL    = 1'b1;

// ============================================================
// LCD 数据输出：RGB666 -> 面板的 18 根颜色线
//
// 按 LCD_test 工程逐根核对 Dock 原理图（LCD_DPI 页 + SOM_BTB0 页）：
// 面板 R7..R2 (6 位) <- HD4 HD3 HTRDY HD1 HD0 HRVLD
// K21 K22 J22 H22 G17 G18
// 面板 G7..G2 (6 位) <- HD10 HD9 HD8 HD7 HD6 HD5
// L18 N22 M22 M21 L21 K18
// 面板 B7..B2 (6 位) <- HCTS HD15 HD14 HD13 HD12 HD11
// M20 L16 K16 N18 N19 M18
// 面板 DEN(34) <- HD2 = L14
//
// 三个纠正（之前全是错的）
// 1) 控制脚：面板 DCLK=L19(HTACK) / HSYNC=N20(HTREQ) / VSYNC=L15(HTVLD)，
// 不是 J20/J21/G18（那三个是相机接口的 HRCLK/HRACK/HRVLD）。
// 接错的症状就是"背光亮但全黑"。
// 2) 红色不是"只有 4 位可控"：R5 接的是 HTRDY=J22（普通 IO，能驱动）。
// 之前以为接在"只能做输入的 L19"上，是误判 -- L19 其实是 DCLK。
// 所以现在是完整的 RGB666（18 位）。
// 3) 颜色格式从 RGB565 改成 RGB666，不再丢掉红色的中间位。
//
// 数据输出沿：
// 面板在 DCLK 下降沿锁存数据（规格书 CKPOL=0，Default pull Low）。
// 做法是把输出寄存器放在 pclk 上升沿 -- 这样数据在面板采样的那个
// 下降沿之前已经稳定了半个周期（10ns），建立/保持都宽裕。
// （LCD_test 工程测试：上升沿输出工作正常；用下降沿会让工具额外造一个
// 反相时钟，数据与时钟之间多出不确定偏斜，不建议。）
// ============================================================

// ---------- 8 段频谱（给 HDMI 用；真实音频，不占 DSP）----------
wire [31:0] spec_bus;
spectrum4 u_spectrum (
    .clk       (adc_clk),
    .rst_n     (sys_rst_n),
    .sample_en (sample_en),
    .sample_in (mix_pcm),
    .bands     (spec_bus)
);

// ---------- 逐像素绘制 ----------
// 迁移到 HDMI：见下面 hdmi_ui 实例。
// 波形缓冲（scope_capture）只有一个读口，两个绘制实例会抢地址，
// 所以 LCD 这边不再绘制，只保持背光亮、信号线输出黑。


// ============================================================
// HDMI 输出（第 1 阶段：彩条测试）
// ============================================================
// 目的：先验证HDMI 硬件链路能点亮，再谈把 UI 移植过来。
// 现在同时保留 LCD 输出，方便对比；确认 HDMI 正常后再删掉 LCD。
//
// 用的是 Sipeed 官方 hdmi_colorbar 例程的完整 TMDS 发送链：
// PLL 50MHz -> 75MHz 像素 / 375MHz 位时钟
// hdmi_timing 1280x720 (~60.6Hz，从 1080p30 改来)
// dvi_tx_top: TMDS 8b10b 编码 + OSER10 串行化 + ELVDS_OBUF 差分输出
//
//  这里用 sys_clk（50MHz）作为 PLL 参考，和官方例程一致。
// ============================================================
// HDMI 输出（方案 A：原 1024x600 界面居中显示在 1280x720 上）
// ============================================================
// 布局：左右各 128 黑边，上下各 60 黑边。
// UI 绘制改到 HDMI 的 75MHz 像素时钟域，波形缓冲由这里独占读口。
// ============================================================
// HDMI 输出：原 1024x600 界面居中显示在 1280x720 上
// ============================================================
// 重要：LCD 那套逻辑必须保留
// 之前把 LCD 删掉后，sys_clk 上没负载了，工具就用普通布线去走 sys_clk
// （WARN PR1014: Generic routing resource will be used to clock 'sys_clk_d'），
// 导致 PLL 参考时钟带抖动 -> TMDS 不稳 -> 显示器锁不住。
// 所以现在 LCD 和 HDMI 两套并存，LCD 继续当主显示。
// ============================================================
// HDMI 输出（回退到彩条版本，仅用于验证 TMDS 通路）
// ============================================================
//  重要教训：之前看到的彩条是板子出厂 demo跑的，不是我们烧进去的代码。
// 所以本设计的 TMDS 输出其实一直没成功过 -- 需要从头验证。
hdmi_ui #(
    .NUM_VOICES  (NUM_VOICES),
    .BUF_AW      (BUF_AW),
    .DISP_W      (DISP_W),
    .KBD_NOTE_LO (KBD_NOTE_LO),
    .KBD_REVERSE (KBD_REVERSE),
    .TOP_H       (134)
) u_hdmi (
    .clk_50m     (sys_clk),
    .rst_n       (sys_rst_n),
    .buf_data    (buf_data2),
    .wr_ptr      (wr_ptr),
    .v_gate      (v_gate),
    .kbd_gate    (kbd_gate),
    .dbg_force   (dbg_force_mux),
    .active_cnt  (poly_now),
    .peak_cnt    (poly_peak),
    .page        (page_dbg),
    .ads_ok      (i2c_ok_mux),
    .ads_err     (ads_err),
    .ads_seen    (ads_seen),
    .spec_bus    (spec_bus),
    .buf_addr    (buf_addr2),
    .tmds_clk_p  (TMDS_CLK_P),
    .tmds_clk_n  (TMDS_CLK_N),
    .tmds_data_p (TMDS_D_P),
    .tmds_data_n (TMDS_D_N)
);


endmodule