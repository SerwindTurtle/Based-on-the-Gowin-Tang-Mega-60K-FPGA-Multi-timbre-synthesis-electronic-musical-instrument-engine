// ============================================================
// fx_mod.v -- 全局合唱 + 相位（镶边）
//
// 两条独立的调制延时线，共用同一个写指针：
//
// 合唱：基础延时 ≈ 14ms，LFO 在 ±5ms 范围内摆动 -> 轻微音高漂移
// 相位：基础延时 ≈ 4ms，LFO 在 ±2.5ms 范围内摆动 + 反馈 -> 梳状扫频
//
// 严格意义上的"相位器"是级联全通滤波器，需要多个乘法器；
// 这里用"短延时 + 反馈 + LFO 扫延时"实现镶边/相位扫频，
// 听感属于同一类"喷气/漩涡"效果，资源只需 2 块 BSRAM。
// LFO 用三角波（相位累加器高位），不用查表。
//
// 寄存器映射（网页 0x58..0x60）：
// CHO_ON / CHO_RATE / CHO_DEPTH / CHO_MIX
// PHA_ON / PHA_RATE / PHA_DEPTH / PHA_FB / PHA_MIX
// ============================================================
module fx_mod (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,
    // 合唱
    input  wire               cho_on,
    input  wire [6:0]         cho_rate,
    input  wire [6:0]         cho_depth,
    input  wire [6:0]         cho_mix,
    // 相位（镶边）
    input  wire               pha_on,
    input  wire [6:0]         pha_rate,
    input  wire [6:0]         pha_depth,
    input  wire [3:0]         pha_fb,
    input  wire [6:0]         pha_mix,
    // 输入 / 输出（合唱、相位各有独立的发送总线）
    input  wire signed [23:0] in_cho,
    input  wire signed [23:0] in_pha,
    output reg  signed [23:0] cho_out,
    output reg  signed [23:0] pha_out
);

    localparam DEPTH = 2048;
    localparam AW    = 11;

    (* ram_style = "block_ram" *) reg [15:0] cho_mem [0:DEPTH-1];
    (* ram_style = "block_ram" *) reg [15:0] pha_mem [0:DEPTH-1];

    reg [AW-1:0]       wptr;
    reg signed [15:0]  cho_rd, pha_rd;

    // LFO 相位累加器：rate 0..127 -> 约 0.09..6Hz（合唱）/ 0.05..3Hz（相位）
    reg [23:0] cho_ph, pha_ph;
    wire [23:0] cho_inc = 24'd32 + ({17'd0, cho_rate} << 4);
    wire [23:0] pha_inc = 24'd16 + ({17'd0, pha_rate} << 3);

    // 三角波：0..255 -> -128..127
    wire [7:0] cho_tri = cho_ph[23] ? (~cho_ph[22:15]) : cho_ph[22:15];
    wire [7:0] pha_tri = pha_ph[23] ? (~pha_ph[22:15]) : pha_ph[22:15];
    wire signed [8:0] cho_bip = $signed({1'b0, cho_tri}) - 9'sd128;
    wire signed [8:0] pha_bip = $signed({1'b0, pha_tri}) - 9'sd128;

    // 调制量（用乘法器；整个设计只多 2 个 DSP）
    wire signed [15:0] cho_mod = ($signed(cho_bip) * $signed({1'b0, cho_depth})) >>> 6;
    wire signed [15:0] pha_mod = ($signed(pha_bip) * $signed({1'b0, pha_depth})) >>> 7;

    // 目标延时（限制在 1..2046，避免读到写指针自身）
    wire signed [15:0] cho_t = 16'sd700 + cho_mod;
    wire signed [15:0] pha_t = 16'sd200 + pha_mod;
    wire [AW-1:0] cho_dly = (cho_t < 16'sd1) ? 11'd1 :
                            (cho_t > 16'sd2046) ? 11'd2046 : cho_t[AW-1:0];
    wire [AW-1:0] pha_dly = (pha_t < 16'sd1) ? 11'd1 :
                            (pha_t > 16'sd2046) ? 11'd2046 : pha_t[AW-1:0];

    wire [AW-1:0] cho_addr = wptr - cho_dly;
    wire [AW-1:0] pha_addr = wptr - pha_dly;

    function signed [15:0] sat16;
        input signed [31:0] x;
        begin
            if (x > 32'sd32767)       sat16 = 16'sh7FFF;
            else if (x < -32'sd32768) sat16 = 16'sh8000;
            else                      sat16 = x[15:0];
        end
    endfunction

    function signed [15:0] soft16;
        input signed [23:0] x;
        reg [23:0] ax, y;
        begin
            ax = x[23] ? ((~x) + 24'd1) : x;
            if (ax <= 24'd20000) y = ax;
            else                 y = 24'd20000 + ((ax - 24'd20000) >>> 1);
            if (y > 24'd30000) y = 24'd30000;
            soft16 = x[23] ? -$signed(y) : $signed(y);
        end
    endfunction

    function signed [15:0] mul4_16;
        input signed [15:0] x;
        input [3:0]         g;
        reg signed [19:0] acc;
        begin
            acc = 20'sd0;
            if (g[0]) acc = acc + x;
            if (g[1]) acc = acc + (x <<< 1);
            if (g[2]) acc = acc + (x <<< 2);
            if (g[3]) acc = acc + (x <<< 3);
            mul4_16 = acc[19:4];
        end
    endfunction

    function signed [23:0] gain7_16;
        input signed [15:0] x;
        input [6:0]         g;
        integer k;
        reg signed [24:0] acc;
        begin
            acc = 25'sd0;
            for (k = 0; k < 7; k = k + 1)
                if (g[k]) acc = acc + ($signed(x) <<< k);
            gain7_16 = acc >>> 7;
        end
    endfunction

    wire signed [15:0] din_cho = soft16(in_cho);
    wire signed [15:0] din_pha = soft16(in_pha);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr    <= {AW{1'b0}};
            cho_ph  <= 24'd0;
            pha_ph  <= 24'h400000;       // 两个 LFO 错开 90°
            cho_rd  <= 16'sd0;
            pha_rd  <= 16'sd0;
            cho_out <= 24'sd0;
            pha_out <= 24'sd0;
        end else if (sample_en) begin
            cho_ph <= cho_ph + cho_inc;
            pha_ph <= pha_ph + pha_inc;

            cho_rd <= cho_mem[cho_addr];
            pha_rd <= pha_mem[pha_addr];

            cho_mem[wptr] <= din_cho;
            pha_mem[wptr] <= sat16(din_pha + mul4_16(pha_rd, pha_fb));

            wptr <= wptr + 1'b1;

            cho_out <= cho_on ? gain7_16(cho_rd, cho_mix) : 24'sd0;
            pha_out <= pha_on ? gain7_16(pha_rd, pha_mix) : 24'sd0;
        end
    end

endmodule
