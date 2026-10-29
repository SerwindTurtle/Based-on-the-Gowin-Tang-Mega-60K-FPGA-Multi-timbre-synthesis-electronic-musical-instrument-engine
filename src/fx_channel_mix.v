// ============================================================
// fx_channel_mix.v -- 32 声部调音台的"通道条"部分
//
// 每个通道做三件事：
// 1) 音量（0..128，128 = 原音量）
// 2) 失真（0..127，用"预增益 + 软削波 + 干湿混合"实现，不用 DSP）
// 3) 4 路辅助发送：回声 / 混响 / 合唱 / 相位（每路 0..15）
//
// 输出：
// dry -- 所有通道的干声相加
// send_echo / send_reverb / send_chorus / send_phaser
// -- 4 条辅助总线，送进全局效果器
//
// 采用发送式效果器的原因：
// 32 套延时线需要 32 份 BSRAM，DSP/布线都放不下。
// 专业调音台也是这个结构：每通道控制"送多少"到全局效果器。
//
// 为了省 DSP，本模块的乘加全部用"移位 + 加法"实现：
// 音量/发送/干湿混合都只占 LUT，不占乘法器。
// 32 通道 × 6 个参数也不会把 DSP 吃满。
// ============================================================
module fx_channel_mix #(
    parameter NUM_CH = 8,       // 实际参与混音的声部数（当前键盘 8 键）
    parameter SUM_W  = 28
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     sample_en,
    // 各声部 PCM：第 i 路 = pcm_bus[i*16 +: 16]
    input  wire [NUM_CH*16-1:0]     pcm_bus,
    // 32 个通道参数（只取前 NUM_CH 个）
    // ch_a[i] = {dist[7:0], vol[7:0]}
    // ch_b[i] = {phaser[3:0], chorus[3:0], reverb[3:0], echo[3:0]}
    input  wire [511:0]             ch_a,
    input  wire [511:0]             ch_b,
    output reg  signed [23:0]       dry,
    output reg  signed [23:0]       send_echo,
    output reg  signed [23:0]       send_reverb,
    output reg  signed [23:0]       send_chorus,
    output reg  signed [23:0]       send_phaser
);

    // ------------------------------------------------------------
    // 纯函数
    // ------------------------------------------------------------
    // 16 位有符号 × 8 位无符号（0..128）-> 24 位有符号（>>7 还原量纲）
    // 全用移位+加法，避免 8 个乘法器
    function signed [23:0] gain_u8_16;
        input signed [15:0] x;
        input [7:0]         g;
        integer k;
        reg signed [24:0] acc;
        begin
            acc = 25'sd0;
            for (k = 0; k < 8; k = k + 1)
                if (g[k]) acc = acc + ($signed(x) <<< k);
            gain_u8_16 = acc >>> 7;      // 除以 128，还原"128 = 原音量"
        end
    endfunction

    // 24 位 × 4 位（0..15）-> 24 位，结果 = x * g / 16
    function signed [23:0] mul4_24;
        input signed [23:0] x;
        input [3:0]         g;
        reg signed [27:0] acc;
        begin
            acc = 28'sd0;
            if (g[0]) acc = acc + x;
            if (g[1]) acc = acc + (x <<< 1);
            if (g[2]) acc = acc + (x <<< 2);
            if (g[3]) acc = acc + (x <<< 3);
            mul4_24 = acc[27:4];
        end
    endfunction

    // 24 位 × 4 位干湿混合：m=0 全干，m=15 接近全湿
    function signed [23:0] blend4_24;
        input signed [23:0] a;
        input signed [23:0] b;
        input [3:0]         m;
        reg signed [28:0] diff;
        reg signed [28:0] prod;
        begin
            diff = b - a;
            prod = 29'sd0;
            if (m[0]) prod = prod + diff;
            if (m[1]) prod = prod + (diff <<< 1);
            if (m[2]) prod = prod + (diff <<< 2);
            if (m[3]) prod = prod + (diff <<< 3);
            blend4_24 = a + prod[28:4];
        end
    endfunction

    // 24 位饱和
    function signed [23:0] sat24;
        input signed [31:0] x;
        begin
            if (x > 32'sd8_388_607)      sat24 = 24'sh7FFFFF;
            else if (x < -32'sd8_388_608) sat24 = 24'sh800000;
            else                          sat24 = x[23:0];
        end
    endfunction

    // 软削波：|x|<=20000 直通，超过后每 2 个码值压成 1 个，最高 30000
    function signed [23:0] soft24;
        input signed [23:0] x;
        reg [23:0] ax;
        reg [23:0] y;
        begin
            ax = x[23] ? ((~x) + 24'd1) : x;
            if (ax <= 24'd20000) y = ax;
            else                 y = 24'd20000 + ((ax - 24'd20000) >>> 1);
            if (y > 24'd30000) y = 24'd30000;
            soft24 = x[23] ? -$signed(y) : $signed(y);
        end
    endfunction

    // ------------------------------------------------------------
    // 每个通道的通道条
    // ------------------------------------------------------------
    wire signed [23:0] ch_y  [0:NUM_CH-1];
    wire signed [23:0] ch_se [0:NUM_CH-1];
    wire signed [23:0] ch_sr [0:NUM_CH-1];
    wire signed [23:0] ch_sc [0:NUM_CH-1];
    wire signed [23:0] ch_sp [0:NUM_CH-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_CH; gi = gi + 1) begin : g_ch
            wire signed [15:0] x   = pcm_bus[gi*16 +: 16];
            wire [15:0]        ca  = ch_a[gi*16 +: 16];
            wire [15:0]        cb  = ch_b[gi*16 +: 16];

            wire [7:0]  vol_raw = ca[7:0];
            wire [7:0]  vol     = (vol_raw > 8'd128) ? 8'd128 : vol_raw;
            wire [7:0]  dist    = ca[15:8];

            wire [3:0]  s_echo  = cb[3:0];
            wire [3:0]  s_rev   = cb[7:4];
            wire [3:0]  s_cho   = cb[11:8];
            wire [3:0]  s_pha   = cb[15:12];

            // 音量
            wire signed [23:0] v = gain_u8_16(x, vol);

            // 失真：预增益 1/2/4/8 倍 -> 软削波 -> 干湿混合
            // dist 是 0..127，用 bit[6:5] 取 0..3 档预增益
            wire [2:0]         dsh   = {1'b0, dist[6:5]};
            wire signed [31:0] pre   = {{8{v[23]}}, v} <<< dsh;
            wire signed [23:0] vclip = soft24(sat24(pre));
            wire signed [23:0] y     = blend4_24(v, vclip, dist[6:3]);

            assign ch_y [gi] = y;
            assign ch_se[gi] = mul4_24(y, s_echo);
            assign ch_sr[gi] = mul4_24(y, s_rev);
            assign ch_sc[gi] = mul4_24(y, s_cho);
            assign ch_sp[gi] = mul4_24(y, s_pha);
        end
    endgenerate

    // ------------------------------------------------------------
    // 求和（组合），采样脉冲时打一拍
    // ------------------------------------------------------------
    reg signed [SUM_W-1:0] dry_c, se_c, sr_c, sc_c, sp_c;
    integer i;

    always @(*) begin
        dry_c = {SUM_W{1'b0}};
        se_c  = {SUM_W{1'b0}};
        sr_c  = {SUM_W{1'b0}};
        sc_c  = {SUM_W{1'b0}};
        sp_c  = {SUM_W{1'b0}};
        for (i = 0; i < NUM_CH; i = i + 1) begin
            dry_c = dry_c + ch_y [i];
            se_c  = se_c  + ch_se[i];
            sr_c  = sr_c  + ch_sr[i];
            sc_c  = sc_c  + ch_sc[i];
            sp_c  = sp_c  + ch_sp[i];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dry <= 24'sd0;
            send_echo <= 24'sd0;
            send_reverb <= 24'sd0;
            send_chorus <= 24'sd0;
            send_phaser <= 24'sd0;
        end else if (sample_en) begin
            // 总衰减 MIX_SHIFT 统一在 fx_master 里做一次，这里保持原始电平。
            // 发送总线 >>2 留 headroom（8 个满幅声部同时送 15 约 61k，
            // 效果器入口再用 soft16 软限幅，不会硬削波），听感比 >>3 明显。
            dry         <= sat24(dry_c);
            send_echo   <= sat24(se_c >>> 2);
            send_reverb <= sat24(sr_c >>> 2);
            send_chorus <= sat24(sc_c >>> 2);
            send_phaser <= sat24(sp_c >>> 2);
        end
    end

endmodule
