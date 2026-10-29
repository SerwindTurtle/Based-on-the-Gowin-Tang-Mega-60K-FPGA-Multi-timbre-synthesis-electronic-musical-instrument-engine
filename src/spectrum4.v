// ============================================================
// spectrum4.v -- 4 段音频频谱（一阶低通滤波器组，给 HDMI 用）
//
// 不占 DSP：全部用移位加法。4 个频段：
// band0 = lp(shift 8) 低频
// band1 = lp(5) - lp(8) 中低
// band2 = lp(3) - lp(5) 中高
// band3 = x - lp(1) 高频
//
// 输出 bands[7:0]=最低 ... bands[31:24]=最高。
// HDMI 侧把 4 段画成 8 条（每段重复两次），视觉上仍是 8 条。
// ============================================================
module spectrum4 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,
    input  wire signed [15:0] sample_in,
    output reg  [31:0]        bands
);

    reg signed [23:0] x;
    reg signed [23:0] lp0, lp1, lp2, lp3;
    reg        [25:0] e0, e1, e2, e3;

    function [23:0] abs24;
        input signed [23:0] v;
        begin
            abs24 = v[23] ? (~v + 24'd1) : v;
        end
    endfunction

    wire signed [23:0] d0 = lp0;
    wire signed [23:0] d1 = lp1 - lp0;
    wire signed [23:0] d2 = lp2 - lp1;
    wire signed [23:0] d3 = x   - lp3;

    wire [25:0] b0 = {2'b0, abs24(d0)} << 2;
    wire [25:0] b1 = {2'b0, abs24(d1)} << 2;
    wire [25:0] b2 = {2'b0, abs24(d2)} << 2;
    wire [25:0] b3 = {2'b0, abs24(d3)} << 2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 24'sd0;
            lp0 <= 24'sd0; lp1 <= 24'sd0; lp2 <= 24'sd0; lp3 <= 24'sd0;
            e0 <= 26'd0; e1 <= 26'd0; e2 <= 26'd0; e3 <= 26'd0;
            bands <= 32'd0;
        end else if (sample_en) begin
            x <= {{8{sample_in[15]}}, sample_in};

            lp0 <= lp0 + ((x - lp0) >>> 8);
            lp1 <= lp1 + ((x - lp1) >>> 5);
            lp2 <= lp2 + ((x - lp2) >>> 3);
            lp3 <= lp3 + ((x - lp3) >>> 1);

            e0 <= (b0 > e0) ? (e0 + ((b0 - e0) >>> 6)) : (e0 - (e0 >>> 6));
            e1 <= (b1 > e1) ? (e1 + ((b1 - e1) >>> 6)) : (e1 - (e1 >>> 6));
            e2 <= (b2 > e2) ? (e2 + ((b2 - e2) >>> 6)) : (e2 - (e2 >>> 6));
            e3 <= (b3 > e3) ? (e3 + ((b3 - e3) >>> 6)) : (e3 - (e3 >>> 6));

            // 包络实际只有 ~14 位，必须取有效高位；取 [25:18] 会永远是 0。
            // [17:10] 最大 127，直接当 0..127px 柱高，不会让 HDMI 坐标下溢。
            bands <= {e3[17:10], e2[17:10], e1[17:10], e0[17:10]};
        end
    end

endmodule
