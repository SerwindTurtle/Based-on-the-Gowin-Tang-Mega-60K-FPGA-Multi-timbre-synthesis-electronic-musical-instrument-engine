// ============================================================
// ADC 采样数据后处理：采集 -> 滤波 -> 稳定
// 用途：接在 adc_ctrl 之后，把原始 ADC 采样变成"平滑且不抖"的数值
//
// 一级 采集：在 sample_valid 有效时接收一个采样点，并计数
// 二级 滤波：累加 2^AVG_BITS 个采样后求平均（等效低通，抑制随机噪声）
// 三级 稳定：滞回 + 去抖。新平均值必须"持续"偏离当前输出超过 STABLE_TH，
// 连续 2^STABLE_BITS 个平均窗后才更新输出，避免显示来回跳。
//
// 级联关系：
// adc_ctrl.adc_data/adc_valid -> sample_in/sample_valid
// filtered / filtered_valid -> 滤波后的值（每 2^AVG_BITS 个采样更新一次）
// stable_out / stable -> 稳定后的值 / 稳定标志
// ============================================================
module adc_filter #(
    // 滤波窗口：2^AVG_BITS 个采样求一次平均。越大越平滑、响应越慢
    parameter AVG_BITS    = 4,   // 默认 2^4 = 16（想更快可减到 3 或 2）
    // 稳定阈值：与当前输出的差 > STABLE_TH 才算"输入变化了"（单位：ADC 码值）
    parameter STABLE_TH   = 8,   // 默认 8（约 8/2048 ≈ 4mV）
    // 去抖深度：变化需连续 2^STABLE_BITS 个平均窗才认账
    parameter STABLE_BITS = 1,   // 默认 2^1 = 2 个平均窗
    // 大变化直通：差值 > FAST_TH 时立即更新输出，不等去抖（快速跟随）
    parameter FAST_TH     = 64   // 默认 64 个码值（约 31mV）
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 采集输入（来自 adc_ctrl） ----
    input  wire        sample_valid,    // 新采样有效脉冲
    input  wire [13:0] sample_in,       // 原始采样值
    // ---- 滤波输出 ----
    output reg  [13:0] filtered,        // 平滑后的值
    output reg         filtered_valid,  // filtered 更新脉冲（1 个时钟）
    // ---- 稳定输出 ----
    output reg  [13:0] stable_out,      // 去抖后的稳定值
    output reg         stable           // 1 = 输入已稳定
);

    localparam AVG_SIZE = (1 << AVG_BITS);   // 滤波窗口长度

    // ============================================================
    // 1) 采集 + 2) 滤波：累加 AVG_SIZE 个采样后取平均
    // 平均 = 右移 AVG_BITS 位（代替除法，省资源）
    // ============================================================
    reg [13+AVG_BITS:0] acc;        // 累加器，位宽 = 14 + AVG_BITS 足够
    reg [AVG_BITS-1:0]  win_cnt;    // 窗口内已收采样数

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc            <= 0;
            win_cnt        <= 0;
            filtered       <= 14'd0;
            filtered_valid <= 1'b0;
        end else begin
            filtered_valid <= 1'b0;             // 默认拉低，只脉冲一拍
            if (sample_valid) begin
                if (win_cnt == AVG_SIZE - 1) begin
                    // 窗口已满：把最后一个采样加进去，输出平均值
                    filtered       <= (acc + sample_in) >> AVG_BITS;
                    filtered_valid <= 1'b1;
                    acc            <= 0;
                    win_cnt        <= 0;
                end else begin
                    acc     <= acc + sample_in;
                    win_cnt <= win_cnt + 1'b1;
                end
            end
        end
    end

    // ============================================================
    // 3) 稳定：快速跟随 + 滞回去抖
    // diff = |filtered - stable_out|
    // diff > FAST_TH -> 大变化，立即更新输出（响应快）
    // diff > STABLE_TH -> 小变化，计数器累加，够了才更新（防抖）
    // diff <= STABLE_TH -> 认为没变，计数器清零，稳定标志置 1
    // ============================================================
    wire [13:0] diff = (filtered > stable_out) ? (filtered  - stable_out)
                                               : (stable_out - filtered);
    reg  [STABLE_BITS-1:0] chg_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_out <= 14'd0;
            stable     <= 1'b1;
            chg_cnt    <= 0;
        end else if (filtered_valid) begin
            if (diff > FAST_TH[13:0]) begin
                stable_out <= filtered;         // 大变化：直通，不等去抖
                chg_cnt    <= 0;
                stable     <= 1'b1;
            end else if (diff > STABLE_TH[13:0]) begin
                if (chg_cnt == {STABLE_BITS{1'b1}}) begin
                    stable_out <= filtered;     // 变化连续保持够久 -> 更新
                    chg_cnt    <= 0;
                    stable     <= 1'b1;
                end else begin
                    chg_cnt <= chg_cnt + 1'b1;  // 还在去抖，输出不动
                    stable  <= 1'b0;
                end
            end else begin
                chg_cnt <= 0;                   // 回到阈值内，判定稳定
                stable  <= 1'b1;
            end
        end
    end

endmodule
