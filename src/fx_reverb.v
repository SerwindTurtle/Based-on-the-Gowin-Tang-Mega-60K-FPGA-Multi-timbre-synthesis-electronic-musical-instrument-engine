// ============================================================
// fx_reverb.v -- 全局混响（Schroeder 结构）
//
// 4 个并联梳状滤波器（带阻尼低通）+ 2 个串联全通滤波器：
//
// in ──┬─ comb(1116) ─┐
// ├─ comb(1188) ─┤
// ├─ comb(1277) ─┼─ 平均 ─ allpass(225) ─ allpass(556) ─ wet
// └─ comb(1356) ─┘
//
// 所有反馈/全通系数都用 1/2^n 的移位实现，不占 DSP
// 4 块 2048 点 + 2 块 1024 点 BSRAM（共约 10 块）
//
// 寄存器映射（网页 0x54..0x57）：
// REV_ON 0/1
// REV_SIZE 0..127 -> 梳状反馈（0.25..0.69）
// REV_DAMP 0..127 -> 阻尼低通（越大越暗）
// REV_MIX 0..127 -> 湿声返回量
// ============================================================
module fx_reverb (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,
    input  wire               on,
    input  wire [6:0]         size,
    input  wire [6:0]         damp,
    input  wire [6:0]         mix,
    input  wire signed [23:0] in,
    output reg  signed [23:0] out
);

    // 梳状延时（采样点，@48.8kHz：22.9 / 24.3 / 26.2 / 27.8 ms）
    localparam C0 = 11'd1116;
    localparam C1 = 11'd1188;
    localparam C2 = 11'd1277;
    localparam C3 = 11'd1356;
    // 全通延时
    localparam A0 = 10'd225;
    localparam A1 = 10'd556;

    (* ram_style = "block_ram" *) reg [15:0] c0 [0:2047];
    (* ram_style = "block_ram" *) reg [15:0] c1 [0:2047];
    (* ram_style = "block_ram" *) reg [15:0] c2 [0:2047];
    (* ram_style = "block_ram" *) reg [15:0] c3 [0:2047];
    (* ram_style = "block_ram" *) reg [15:0] ap0 [0:1023];
    (* ram_style = "block_ram" *) reg [15:0] ap1 [0:1023];

    reg  [10:0] wptr;
    reg  signed [15:0] d0, d1, d2, d3;
    reg  signed [15:0] ad0, ad1;
    reg  signed [15:0] lp0, lp1, lp2, lp3;
    reg  signed [15:0] y0, y1;

    wire [10:0] r0 = wptr - C0;
    wire [10:0] r1 = wptr - C1;
    wire [10:0] r2 = wptr - C2;
    wire [10:0] r3 = wptr - C3;
    wire [9:0]  ar0 = wptr[9:0] - A0;
    wire [9:0]  ar1 = wptr[9:0] - A1;

    // size 0..127 -> 反馈 4..11 (/16)
    wire [3:0]  fb       = 4'd4 + size[6:4];
    // damp 0..127 -> 低通系数 1/2 .. 1/256
    wire [3:0]  damp_sh  = 4'd1 + damp[6:4];

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

    // 单极低通的新值
    function signed [15:0] onepole;
        input signed [15:0] x;
        input signed [15:0] s;
        input [3:0]         sh;
        begin
            onepole = s + ((x - s) >>> sh);
        end
    endfunction

    wire signed [15:0] din  = soft16(in);
    wire signed [15:0] nlp0 = onepole(d0, lp0, damp_sh);
    wire signed [15:0] nlp1 = onepole(d1, lp1, damp_sh);
    wire signed [15:0] nlp2 = onepole(d2, lp2, damp_sh);
    wire signed [15:0] nlp3 = onepole(d3, lp3, damp_sh);

    wire signed [16:0] d0s = $signed(d0);
    wire signed [16:0] d1s = $signed(d1);
    wire signed [16:0] d2s = $signed(d2);
    wire signed [16:0] d3s = $signed(d3);
    wire signed [16:0] ad0s = $signed(ad0);
    wire signed [16:0] ad1s = $signed(ad1);
    wire signed [16:0] y0s = $signed(y0);
    wire signed [16:0] y1s = $signed(y1);

    wire signed [16:0] comb = (d0s + d1s + d2s + d3s) >>> 2;

    // 全通 1：y = xd + (yd - x)/2；写 x + yd/2
    wire signed [16:0] ap1_in  = comb;
    wire signed [16:0] ap1_out = ad0s + ((y0s - ap1_in) >>> 1);
    // 全通 2
    wire signed [16:0] ap2_out = ad1s + ((y1s - ap1_out) >>> 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 11'd0;
            d0 <= 0; d1 <= 0; d2 <= 0; d3 <= 0;
            ad0 <= 0; ad1 <= 0;
            lp0 <= 0; lp1 <= 0; lp2 <= 0; lp3 <= 0;
            y0 <= 0; y1 <= 0;
            out <= 24'sd0;
        end else if (sample_en) begin
            // 读
            d0  <= c0[r0];
            d1  <= c1[r1];
            d2  <= c2[r2];
            d3  <= c3[r3];
            ad0 <= ap0[ar0];
            ad1 <= ap1[ar1];

            // 低通状态
            lp0 <= nlp0;
            lp1 <= nlp1;
            lp2 <= nlp2;
            lp3 <= nlp3;

            // 写梳状（输入 + 阻尼后的反馈）
            c0[wptr] <= sat16(din + mul4_16(nlp0, fb));
            c1[wptr] <= sat16(din + mul4_16(nlp1, fb));
            c2[wptr] <= sat16(din + mul4_16(nlp2, fb));
            c3[wptr] <= sat16(din + mul4_16(nlp3, fb));

            // 写全通
            ap0[wptr[9:0]] <= sat16(ap1_in + (y0s >>> 1));
            ap1[wptr[9:0]] <= sat16(ap1_out + (y1s >>> 1));

            y0 <= sat16(ap1_out);
            y1 <= sat16(ap2_out);

            wptr <= wptr + 1'b1;
            out  <= on ? gain7_16(y1, mix) : 24'sd0;
        end
    end

endmodule
