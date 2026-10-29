// ============================================================
// fx_master.v -- 主效果链：失真 -> 5 段均衡 -> 限幅 -> 主音量
//
// 1) 失真：预增益 + 软削波 + 音色低通 + 干湿混合（全移位实现）
// 2) 均衡：5 段固定分频点（≈120 / 500 / 1k / 5k Hz），每段独立增益
// band0 = LP120
// band1 = LP500 - LP120
// band2 = LP1k - LP500
// band3 = LP5k - LP1k
// band4 = x - LP5k
// 5 段相加严格等于原信号，增益由网页滑块控制（0=衰减，16=0dB）
// 3) 限幅：可调阈值 + 天花板 + 软拐点，防止爆音
// 4) 主音量：0..255，约 5ms 平滑，静音也走同一条斜坡
//
// 寄存器映射（网页 0x61..0x6F）：
// DRV_ON / DRV_DRIVE / DRV_TONE / DRV_MIX
// LIM_ON / LIM_TH / LIM_CEIL / LIM_REL
// EQ_ON / EQ_LOW / EQ_LMID / EQ_MID / EQ_HMID / EQ_HIGH / EQ_OUT
// ============================================================
module fx_master (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_en,
    // 各路声音（24 位有符号，留足余量）
    input  wire signed [23:0] dry,
    input  wire signed [23:0] echo,
    input  wire signed [23:0] reverb,
    input  wire signed [23:0] chorus,
    input  wire signed [23:0] phaser,
    input  wire [2:0]         mix_shift,
    // 主音量 / 静音
    input  wire [7:0]         master,
    input  wire               mute,
    // 失真
    input  wire               drv_on,
    input  wire [6:0]         drv_drive,
    input  wire [6:0]         drv_tone,
    input  wire [6:0]         drv_mix,
    // 限幅
    input  wire               lim_on,
    input  wire [7:0]         lim_th,
    input  wire [7:0]         lim_ceil,
    input  wire [6:0]         lim_rel,
    // 均衡
    input  wire               eq_on,
    input  wire [5:0]         eq_low,
    input  wire [5:0]         eq_lmid,
    input  wire [5:0]         eq_mid,
    input  wire [5:0]         eq_hmid,
    input  wire [5:0]         eq_high,
    input  wire [7:0]         eq_out,
    // 输出
    output reg  signed [15:0] pcm_out,
    output reg                pcm_valid
);

    // ------------------------------------------------------------
    // 纯函数
    // ------------------------------------------------------------
    function signed [23:0] sat24;
        input signed [31:0] x;
        begin
            if (x > 32'sd8_388_607)      sat24 = 24'sh7FFFFF;
            else if (x < -32'sd8_388_608) sat24 = 24'sh800000;
            else                          sat24 = x[23:0];
        end
    endfunction

    function signed [15:0] sat16;
        input signed [31:0] x;
        begin
            if (x > 32'sd32767)       sat16 = 16'sh7FFF;
            else if (x < -32'sd32768) sat16 = 16'sh8000;
            else                      sat16 = x[15:0];
        end
    endfunction

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

    // 24 位 × 6 位（0..63，16=1.0）-> 24 位
    function signed [23:0] gain6_24;
        input signed [23:0] x;
        input [5:0]         g;
        integer k;
        reg signed [30:0] acc;
        begin
            acc = 31'sd0;
            for (k = 0; k < 6; k = k + 1)
                if (g[k]) acc = acc + ($signed(x) <<< k);
            gain6_24 = sat24(acc >>> 4);
        end
    endfunction

    // 24 位 × 8 位（0..255）-> 24 位
    function signed [23:0] gain8_24;
        input signed [23:0] x;
        input [7:0]         g;
        integer k;
        reg signed [32:0] acc;
        begin
            acc = 33'sd0;
            for (k = 0; k < 8; k = k + 1)
                if (g[k]) acc = acc + ($signed(x) <<< k);
            gain8_24 = sat24(acc >>> 8);
        end
    endfunction

    // 16 位 × 8 位（0..255）-> 16 位
    function signed [15:0] gain8_16;
        input signed [15:0] x;
        input [7:0]         g;
        integer k;
        reg signed [24:0] acc;
        begin
            acc = 25'sd0;
            for (k = 0; k < 8; k = k + 1)
                if (g[k]) acc = acc + ($signed(x) <<< k);
            gain8_16 = sat16(acc >>> 8);
        end
    endfunction

    // ------------------------------------------------------------
    // 1) 干声 + 4 路湿声 + 总衰减
    // ------------------------------------------------------------
    wire signed [26:0] sum_c = $signed(dry) + $signed(echo) + $signed(reverb)
                             + $signed(chorus) + $signed(phaser);
    wire signed [23:0] sum = sat24(sum_c >>> mix_shift);

    // ------------------------------------------------------------
    // 2) 失真（先把总线衰减 1/4 再进削波，出来后 ×4 补偿，
    // 这样单声部和 8 声部和弦都能落在软削波的工作区间）
    // ------------------------------------------------------------
    wire signed [23:0] drv_in = sum >>> 2;
    wire [2:0]         dsh  = drv_drive[6:5];      // 0..3
    wire [3:0]         dmix = drv_drive[6:3];      // 0..15
    wire signed [31:0] pre  = {{8{drv_in[23]}}, drv_in} <<< dsh;
    wire signed [23:0] drv_clip = soft24(sat24(pre));
    wire [3:0]         tsh  = 4'd7 - {1'b0, drv_tone[6:4]}; // 7(暗)..0(直通)

    reg  signed [23:0] tone_lp;
    wire signed [23:0] tone_n = tone_lp + ((drv_clip - tone_lp) >>> tsh);
    wire signed [25:0] tone_g = {{2{tone_n[23]}}, tone_n} <<< 2;
    wire signed [23:0] drv_wet = sat24(tone_g);
    wire signed [23:0] drv_out = drv_on ? blend4_24(sum, drv_wet, dmix) : sum;

    // ------------------------------------------------------------
    // 3) 5 段均衡
    // ------------------------------------------------------------
    reg signed [23:0] lp120, lp500, lp1k, lp5k;
    wire signed [23:0] n120 = lp120 + ((drv_out - lp120) >>> 6);
    wire signed [23:0] n500 = lp500 + ((drv_out - lp500) >>> 4);
    wire signed [23:0] n1k  = lp1k  + ((drv_out - lp1k ) >>> 3);
    wire signed [23:0] n5k  = lp5k  + ((drv_out - lp5k ) >>> 1);

    wire signed [23:0] b0 = n120;
    wire signed [23:0] b1 = n500 - n120;
    wire signed [23:0] b2 = n1k  - n500;
    wire signed [23:0] b3 = n5k  - n1k;
    wire signed [23:0] b4 = drv_out - n5k;

    wire signed [23:0] e0 = gain6_24(b0, eq_low);
    wire signed [23:0] e1 = gain6_24(b1, eq_lmid);
    wire signed [23:0] e2 = gain6_24(b2, eq_mid);
    wire signed [23:0] e3 = gain6_24(b3, eq_hmid);
    wire signed [23:0] e4 = gain6_24(b4, eq_high);
    wire signed [26:0] eq_sum_c = $signed(e0) + $signed(e1) + $signed(e2)
                                + $signed(e3) + $signed(e4);
    wire signed [23:0] eq_sum = sat24(eq_sum_c);
    wire signed [23:0] eq_out_s = eq_on ? eq_sum : drv_out;
    wire signed [23:0] eq_trim = gain8_24(eq_out_s, eq_out);

    // ------------------------------------------------------------
    // 4) 限幅器（软拐点，24 位域内做，最后才饱和到 16 位）
    // ------------------------------------------------------------
    // th*112 = th*64 + th*32 + th*16；ceil*96 = ceil*64 + ceil*32
    wire [15:0] th_raw   = 16'd4096 + ({8'd0, lim_th}   << 6)
                                       + ({8'd0, lim_th}   << 5)
                                       + ({8'd0, lim_th}   << 4);
    wire [15:0] ceil_raw = 16'd8192 + ({8'd0, lim_ceil} << 6)
                                       + ({8'd0, lim_ceil} << 5);
    wire [15:0] th_eff   = (th_raw > (ceil_raw - 16'd512)) ? (ceil_raw - 16'd512) : th_raw;
    wire [2:0]  knee     = 3'd1 + lim_rel[6:5];      // 1..4

    wire signed [23:0] th24   = {8'd0, th_eff};      // 16 位阈值零扩展到 24 位
    wire signed [23:0] ceil24 = {8'd0, ceil_raw};

    wire [23:0] ax    = eq_trim[23] ? ((~eq_trim) + 24'd1) : eq_trim;
    wire [23:0] over  = (ax > th24) ? (ax - th24) : 24'd0;
    wire [23:0] yabs  = (ax <= th24) ? ax : (th24 + (over >>> knee));
    wire [23:0] ylim  = (yabs > ceil24) ? ceil24 : yabs;
    wire signed [23:0] lim_out = lim_on
                               ? (eq_trim[23] ? -$signed(ylim) : $signed(ylim))
                               : eq_trim;

    // ------------------------------------------------------------
    // 5) 主音量平滑 + 输出
    // ------------------------------------------------------------
    wire [7:0] gain_target = mute ? 8'd0 : master;
    reg  [7:0] gain;

    wire signed [23:0] final24 = gain8_24(lim_out, gain);
    // 24 位只是留 headroom，量纲仍是 16 位 PCM；最后饱和到 16 位
    wire signed [15:0] final_pcm = sat16(final24);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tone_lp   <= 24'sd0;
            lp120 <= 0; lp500 <= 0; lp1k <= 0; lp5k <= 0;
            gain      <= 8'd0;
            pcm_out   <= 16'sd0;
            pcm_valid <= 1'b0;
        end else begin
            pcm_valid <= sample_en;
            if (sample_en) begin
                tone_lp <= tone_n;
                lp120   <= n120;
                lp500   <= n500;
                lp1k    <= n1k;
                lp5k    <= n5k;

                if (gain < gain_target)      gain <= gain + 8'd1;
                else if (gain > gain_target) gain <= gain - 8'd1;

                pcm_out <= final_pcm;
            end
        end
    end

endmodule
