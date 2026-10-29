// ============================================================
// RGB LCD 时序发生器（TTL 并口）
//
// 现在配的是1024x600面板（5 寸 IPS，GT911 触摸，TTL-24bit 接口）
// 像素时钟 = sys_clk = 50MHz 直接驱动（不分频、不加 PLL）
// 刷新率 ≈ 63.8Hz
//
// 输出标准 RGB 时序：
// |<-- 有效像素 -->|<-- 前肩 -->|<-- 同步 -->|<-- 后肩 -->|
// DE 高 低 低 低
// HSYNC 低 低 有效 低
//
// 参数都是"屏决定的"，改屏只要改这几个参数（或在 top.v 例化时传参）：
// H_ACTIVE/H_FP/H_SYNC/H_BP 水平：有效像素/前肩/同步宽度/后肩
// V_ACTIVE/V_FP/V_SYNC/V_BP 垂直：有效行/前肩/同步宽度/后肩
//
// 1024x600 这套值（按常见 1024x600 TTL 面板的典型消隐，兼容性优先）：
// Htotal = 1024+40+20+140 = 1224
// Vtotal = 600+20+3+17 = 640
// 50MHz / (1224*640) ≈ 63.8Hz
//
//  如果屏还是不亮，按这个顺序试（每次只改一处，重新综合布线约 5 分钟）：
// 1) 把 top.v 里 HSYNC_LOW / VSYNC_LOW 改成 1'b0（同步极性反了）
// 2) 换一组消隐值：H_FP/H_SYNC/H_BP = 24/136/160、V_FP/V_SYNC/V_BP = 3/6/29
// 3) 向卖家要这块屏的时序表（Hsync/Vsync 前后肩、极性、最小刷新率）
// ============================================================
module lcd_timing #(
    parameter H_ACTIVE = 1024,
    parameter H_FP     = 40,
    parameter H_SYNC   = 20,
    parameter H_BP     = 140,
    parameter V_ACTIVE = 600,
    parameter V_FP     = 20,
    parameter V_SYNC   = 3,
    parameter V_BP     = 17,
    // 同步极性：0 = 高有效，1 = 低有效（多数 RGB 屏是低有效）
    parameter HSYNC_LOW = 1'b1,
    parameter VSYNC_LOW = 1'b1
) (
    input  wire        pclk,        // 像素时钟
    input  wire        rst_n,
    // ---- 时序输出（组合译码，见文件末）----
    output wire        hsync,
    output wire        vsync,
    output wire        de,          // 数据使能（DEN）
    // ---- 当前像素坐标（有效区内）----
    output wire [11:0] x,
    output wire [11:0] y,
    // ---- 帧起始脉冲（用于锁存画面参数）----
    output reg         frame_start
);

    localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    reg [11:0] hcnt;
    reg [11:0] vcnt;

    wire hsync_raw = (hcnt >= H_ACTIVE + H_FP) &&
                     (hcnt <  H_ACTIVE + H_FP + H_SYNC);
    wire vsync_raw = (vcnt >= V_ACTIVE + V_FP) &&
                     (vcnt <  V_ACTIVE + V_FP + V_SYNC);

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            hcnt        <= 12'd0;
            vcnt        <= 12'd0;
            frame_start <= 1'b0;
        end else begin
            // ---------- 水平计数 ----------
            if (hcnt == H_TOTAL - 1) begin
                hcnt <= 12'd0;

                // ---------- 垂直计数 ----------
                if (vcnt == V_TOTAL - 1) begin
                    vcnt        <= 12'd0;
                    frame_start <= 1'b1;      // 一帧开始
                end else begin
                    vcnt        <= vcnt + 1'b1;
                    frame_start <= 1'b0;
                end
            end else begin
                hcnt        <= hcnt + 1'b1;
                frame_start <= 1'b0;
            end
        end
    end

    // 输出全部用组合逻辑，保证 hsync/vsync/de 与 x/y 在同一拍上对齐。
    // 计数是寄存器输出，所以这里只是对寄存器值做译码，不会有毛刺。
    assign hsync = HSYNC_LOW ? ~hsync_raw : hsync_raw;
    assign vsync = VSYNC_LOW ? ~vsync_raw : vsync_raw;
    assign de    = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

    assign x = hcnt;
    assign y = vcnt;

endmodule
