// ============================================================
// 复音数统计：数当前有几个主声部/按键在响，并记录峰值
//
// v_gate[i] = 1 表示第 i 个主声部正在发声。
// 逐位相加（popcount）就得到"当前同时按下几个键/主声部"。
//
// 32 声部齐奏的附加层没有独立 gate（共用主声部），所以这里
// 仍然只数主声部/按键；网页会按"齐奏层数"换算成实际声部数
// （8 键 × 4 层 = 32），不要在这里乘层数--那会多一级
// 32 位 popcount × 层数的组合逻辑，把显示侧时序挤坏。
//
// active_cnt : 当前主声部/按键数 0 ~ NUM_VOICES
// peak_cnt : 上电以来达到过的最大复音数（可用 peak_clr 清零）
//
// 输出位宽 CNTW 由 NUM_VOICES 自动算出，改声部数不用动别的地方。
// NUM_VOICES = 8 -> CNTW = 4（数到 8）
// NUM_VOICES = 32 -> CNTW = 6（数到 32）
// ============================================================
module voice_meter #(
    parameter NUM_VOICES = 32,
    // 声部编号位宽
    parameter VW = (NUM_VOICES <= 2)  ? 1 :
                   (NUM_VOICES <= 4)  ? 2 :
                   (NUM_VOICES <= 8)  ? 3 :
                   (NUM_VOICES <= 16) ? 4 :
                   (NUM_VOICES <= 32) ? 5 : 6,
    // 计数值位宽：最大要能表示 NUM_VOICES 本身，所以比 VW 多 1 位
    parameter CNTW = VW + 1
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_en,     // 采样率使能：用它降速统计，避免高频抖动
    input  wire                  peak_clr,      // 峰值清零（高有效，可用按键接）
    input  wire [NUM_VOICES-1:0] v_gate,        // 各声部开关
    output reg  [CNTW-1:0]       active_cnt,    // 当前主声部/按键数
    output reg  [CNTW-1:0]       peak_cnt       // 峰值主声部/按键数
);

    integer        i;
    reg [CNTW-1:0] cnt_c;       // 组合统计结果

    always @(*) begin
        cnt_c = {CNTW{1'b0}};
        for (i = 0; i < NUM_VOICES; i = i + 1)
            cnt_c = cnt_c + {{(CNTW-1){1'b0}}, v_gate[i]};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_cnt <= {CNTW{1'b0}};
            peak_cnt   <= {CNTW{1'b0}};
        end else if (peak_clr) begin
            active_cnt <= cnt_c;
            peak_cnt   <= cnt_c;
        end else if (sample_en) begin
            active_cnt <= cnt_c;
            if (cnt_c > peak_cnt)
                peak_cnt <= cnt_c;
        end
    end

endmodule
