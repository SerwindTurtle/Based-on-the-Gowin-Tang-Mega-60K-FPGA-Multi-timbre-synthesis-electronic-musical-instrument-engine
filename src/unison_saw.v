// ============================================================
// unison_saw.v -- 32 声部齐奏 / 超锯齿（8 键 × 4 层）
//
// 主声部仍然是原来的 osc_voice（第 1 层）；
// 这个模块给每个键再生成 3 个微失谐的锯齿层：
//
// 键 i：主声部 + saw(+δ) + saw(−δ) + saw(+2δ) = 4 层
// 8 键 × 4 层 = 32 个振荡器
//
// 不复制 24 套 ADSR/力度：所有附加层共用主声部的 env_bus / v_vel，
// 所以只多 24 个相位累加器 + 每键 2 个乘法器（env × vel），
// DSP 大约 +16（当前 91.5 -> ~107.5/118）。
//
// 失谐量用移位实现：
// det_shift = 10 - detune[6:4] （10..3）
// δ = inc >> det_shift （约 0.1% .. 12.5%）
// +δ / −δ / +2δ 三层，相位各自累加，不需要乘法器。
//
// 附加层只输出"湿声"，top.v 会把它加到主声部 PCM 上；
// 混合量用 7 位移位加法，不占 DSP。
// ============================================================
module unison_saw #(
    parameter NUM_KEYS = 8
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       sample_en,
    input  wire                       on,
    input  wire [2:0]                 layers,     // 1..4（总层数，含主声部）
    input  wire [6:0]                 detune,     // 0..127
    input  wire [6:0]                 mix,        // 0..127
    // 每个键当前相位增量（来自主 osc_voice，含滑音/颤音）
    input  wire [NUM_KEYS*24-1:0]     inc_bus,
    input  wire [NUM_KEYS-1:0]        gate,
    input  wire [NUM_KEYS*7-1:0]      vel_bus,
    input  wire [NUM_KEYS*16-1:0]     env_bus,
    // 附加层 PCM（16 位有符号，每键一路）
    output wire [NUM_KEYS*16-1:0]     pcm_bus_out
);

    // 18 位 × 7 位 -> 18 位（/128），用移位加法，不占 DSP
    function signed [17:0] gain7_18;
        input signed [17:0] x;
        input [6:0]         g;
        integer k;
        reg signed [24:0] acc;
        begin
            acc = 25'sd0;
            for (k = 0; k < 7; k = k + 1)
                if (g[k]) acc = acc + ($signed(x) <<< k);
            gain7_18 = acc >>> 7;
        end
    endfunction

    // 失谐移位：10..3（detune=0 -> 0.098%，detune=127 -> 12.5%）
    wire [3:0] det_shift = 4'd10 - detune[6:4];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_KEYS; gi = gi + 1) begin : g_key
            wire [23:0] inc  = inc_bus[gi*24 +: 24];
            wire [23:0] dlt  = inc >> det_shift;
            wire [23:0] inc1 = inc + dlt;          // +δ
            wire [23:0] inc2 = inc - dlt;          // −δ
            wire [23:0] inc3 = inc + (dlt << 1);   // +2δ

            reg [23:0] ph1, ph2, ph3;
            reg        gate_d;

            wire        gt  = gate[gi];
            wire [6:0]  vel = vel_bus[gi*7 +: 7];
            wire [15:0] env = env_bus[gi*16 +: 16];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    ph1 <= 24'd0;
                    ph2 <= 24'd0;
                    ph3 <= 24'd0;
                    gate_d <= 1'b0;
                end else if (sample_en) begin
                    gate_d <= gt;
                    if (gt & ~gate_d) begin
                        ph1 <= 24'd0;
                        ph2 <= 24'd0;
                        ph3 <= 24'd0;
                    end else if (gt) begin
                        ph1 <= ph1 + inc1;
                        ph2 <= ph2 + inc2;
                        ph3 <= ph3 + inc3;
                    end
                end
            end

            // 锯齿波（和 osc_voice 的 w_saw 同一写法）
            wire signed [15:0] s1 = ph1[23:8] ^ 16'h8000;
            wire signed [15:0] s2 = ph2[23:8] ^ 16'h8000;
            wire signed [15:0] s3 = ph3[23:8] ^ 16'h8000;

            // 按层数选层，并归一化：2 层 ×1、3 层 ÷2、4 层 ÷4
            reg signed [17:0] sum_raw;
            always @(*) begin
                sum_raw = 18'sd0;
                if (layers >= 3'd2) sum_raw = sum_raw + {{2{s1[15]}}, s1};
                if (layers >= 3'd3) sum_raw = sum_raw + {{2{s2[15]}}, s2};
                if (layers >= 3'd4) sum_raw = sum_raw + {{2{s3[15]}}, s3};
            end

            reg signed [17:0] sum_norm;
            always @(*) begin
                case (layers)
                    3'd2:    sum_norm = sum_raw;
                    3'd3:    sum_norm = sum_raw >>> 1;
                    3'd4:    sum_norm = sum_raw >>> 1;   // 4 层也只用 >>1，附加层才听得出来
                    default: sum_norm = 18'sd0;   // 1 层 = 不用附加层
                endcase
            end

            // 混合量（移位加法，不占 DSP）
            wire signed [17:0] sum_mix = gain7_18(sum_norm, mix);

            // 和主声部同一量纲：wave × env × vel >> 23
            // 先算 env×vel/128（16×7 乘法），再乘 sum_mix（18×16），
            // 两个乘法器/键，避免 34×7 被拆成两个 DSP。
            wire [22:0]        env_vel = env * vel;          // 16×7 -> 23 位
            wire signed [16:0] ev      = env_vel >>> 7;      // /128，最大 65023
            wire signed [34:0] p_all   = sum_mix * ev;       // 18×17 -> 35 位
            wire signed [15:0] pcm     = p_all[31:16];       // /65536

            assign pcm_bus_out[gi*16 +: 16] = (on && (layers >= 3'd2)) ? pcm : 16'sd0;
        end
    endgenerate

endmodule
