// ============================================================
// 音符事件生成：模拟电压 -> (音高 / 力度 / 开关 / note_on / note_off)
//
// 用途：接在 adc_filter 之后，把"稳定的电压值"翻译成音乐事件。
// 单点压力传感器用法：
// 沿传感器滑动/按压 -> 电压变化 -> 量化成半音音高
// 电压超过阈值 -> note_on（按下）
// 电压回落到阈值下 -> note_off（松开），带去抖
//
// ── 音高映射 ──
// pitch = NOTE_LO + ((value - VAL_LO) * MULT) >> SHIFT
// 把 [VAL_LO, VAL_HI] 这段电压线性映射到 [NOTE_LO, NOTE_HI] 这些半音。
//
// MULT / SHIFT 怎么算：
// MULT = 2^SHIFT * (NOTE_HI - NOTE_LO) / (VAL_HI - VAL_LO)
// 例（本模块默认值）：把 0~6758（0~3.3V）映射到 24 个半音（两个八度 C3~C5）
// 24 / 6758 = 0.0035520
// SHIFT = 16 -> MULT = 0.0035520 * 65536 ≈ 233
// 换个音域时按这个公式重算 MULT 即可。
//
// ── 力度 ──
// 本版固定 VEL_FIX。以后接压力/上升速度测力度时，把 velocity 的赋值
// 改成你想用的量即可（接口不用动）。
// ============================================================
module note_gen #(
    // 开关阈值：value 高于它算"按下"，低于它算"松开"
    parameter [13:0] GATE_TH  = 14'd100,
    // 音高映射区间（电压侧）与对应的音符号区间（音乐侧）
    parameter [13:0] VAL_LO   = 14'd0,      // 0V -> NOTE_LO
    parameter [13:0] VAL_HI   = 14'd6758,   // 3.3V -> NOTE_HI
    parameter [6:0]  NOTE_LO  = 7'd48,      // 最低音：MIDI 48 = C3
    parameter [6:0]  NOTE_HI  = 7'd72,      // 最高音：MIDI 72 = C5
    // 定点斜率：MULT = 2^SHIFT * (NOTE_HI-NOTE_LO)/(VAL_HI-VAL_LO)
    parameter [23:0] MULT     = 24'd233,
    parameter        SHIFT    = 16,
    // 固定力度（以后接压力/速度再改）
    parameter [6:0]  VEL_FIX  = 7'd100,
    // 松开去抖：连续多少次低于阈值才真正 note_off
    parameter [7:0]  REL_CNT  = 8'd16
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 来自 adc_filter 的稳定电压值 ----
    input  wire [13:0] value,        // 稳定后的 ADC 值
    input  wire        value_valid,  // 值更新脉冲（用 adc_filter.filtered_valid 即可）
    // ---- 音符事件输出 ----
    output reg  [6:0]  note,         // 当前音高（量化到半音）
    output reg  [6:0]  velocity,     // 力度
    output reg         gate,         // 1 = 按下
    output reg         note_on,      // 按下 / 换音：1 个时钟脉冲
    output reg         note_off      // 松开：1 个时钟脉冲
);

    // ---------- 音高计算（定点乘 + 移位，代替除法） ----------
    wire [13:0] v_clamp = (value < VAL_LO) ? VAL_LO :
                          (value > VAL_HI) ? VAL_HI : value;
    wire [13:0] v_rel   = v_clamp - VAL_LO;
    wire [37:0] prod    = v_rel * MULT;          // 14 + 24 = 38 位够用
    wire [21:0] p_off   = prod >> SHIFT;
    wire [21:0] span    = NOTE_HI - NOTE_LO;
    wire [21:0] p_lim   = (p_off > span) ? span : p_off;
    wire [6:0]  pitch   = NOTE_LO + p_lim[6:0];

    // ---------- 开关 + 事件 ----------
    reg [7:0] rel_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note      <= NOTE_LO;
            velocity  <= VEL_FIX;
            gate      <= 1'b0;
            note_on   <= 1'b0;
            note_off  <= 1'b0;
            rel_cnt   <= 8'd0;
        end else begin
            note_on  <= 1'b0;          // 事件默认拉低，只脉冲一拍
            note_off <= 1'b0;
            if (value_valid) begin
                if (value > GATE_TH) begin
                    // ---- 按下：跟随音高 ----
                    rel_cnt <= 8'd0;
                    note    <= pitch;
                    if (!gate) begin
                        gate     <= 1'b1;       // 新音符
                        velocity <= VEL_FIX;
                        note_on  <= 1'b1;
                    end
                end else if (gate) begin
                    // ---- 松开：去抖后发 note_off ----
                    if (rel_cnt == REL_CNT - 1'b1) begin
                        gate     <= 1'b0;
                        note_off <= 1'b1;
                        rel_cnt  <= 8'd0;
                    end else begin
                        rel_cnt <= rel_cnt + 1'b1;
                    end
                end
            end
        end
    end

endmodule
