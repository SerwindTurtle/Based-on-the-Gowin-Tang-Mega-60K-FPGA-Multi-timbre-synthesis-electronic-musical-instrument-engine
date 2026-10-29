// ============================================================
// fx_echo.v -- 全局回声 / 延时
//
// 一块 BSRAM 延时线（16384 点 @48.8kHz ≈ 335ms 上限）
// 读地址 = 写地址 - 延时；反馈用 4 位（0..15，/16）移位实现
// 输出只给"湿声"，由主混音决定返回量
//
// 寄存器映射（网页 0x50..0x53）：
// ECHO_ON 0/1
// ECHO_TIME 0..255 -> 延时 = 512 + time*62 个采样（10.5ms..334ms）
// ECHO_FB 0..15 -> 反馈 = fb/16
// ECHO_MIX 0..127 -> 湿声返回量
// ============================================================
module fx_echo (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,
    input  wire               on,
    input  wire [7:0]         delay_time,
    input  wire [3:0]         fb,
    input  wire [6:0]         mix,
    input  wire signed [23:0] in,
    output reg  signed [23:0] out
);

    localparam DEPTH = 16384;
    localparam AW    = 14;

    (* ram_style = "block_ram" *)
    reg [15:0] mem [0:DEPTH-1];

    reg  [AW-1:0]      wptr;
    reg  signed [15:0] rd;

    // delay_time*60 = delay_time*64 - delay_time*4（常数乘法只用移位/减法）
    // 0..255 -> 512..15812 个采样（10.5ms..324ms），确保 < 16384
    wire [AW-1:0] dly   = 14'd512 + ({6'd0, delay_time} << 6) - ({6'd0, delay_time} << 2);
    wire [AW-1:0] raddr = wptr - dly;

    function signed [15:0] sat16;
        input signed [31:0] x;
        begin
            if (x > 32'sd32767)       sat16 = 16'sh7FFF;
            else if (x < -32'sd32768) sat16 = 16'sh8000;
            else                      sat16 = x[15:0];
        end
    endfunction

    // 发送总线可能到 61k（8 声部 × 发送 15）；入口软限幅到 16 位，
    // 不要硬 clip，否则效果器一开就"炸"。
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

    // 16 位 × 4 位 -> 16 位（/16）
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

    // 16 位 × 7 位 -> 24 位（/128）
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

    wire signed [15:0] din  = soft16(in);
    wire signed [15:0] wdat = sat16(din + mul4_16(rd, fb));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {AW{1'b0}};
            rd   <= 16'sd0;
            out  <= 24'sd0;
        end else if (sample_en) begin
            // 先读旧值，再写新值：反馈用到的是上一拍的 rd
            rd      <= mem[raddr];
            mem[wptr] <= wdat;
            wptr    <= wptr + 1'b1;

            out <= on ? gain7_16(rd, mix) : 24'sd0;
        end
    end

endmodule
