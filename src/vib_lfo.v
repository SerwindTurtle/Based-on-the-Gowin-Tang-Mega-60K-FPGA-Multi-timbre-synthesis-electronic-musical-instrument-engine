// ============================================================
// vib_lfo.v -- 全局颤音 LFO（所有声部共用）
//
// 输出 delta 是一个"带符号的相位增量调制量"（-127..+127）。
// osc_voice 里这样用它：
// inc_vib = inc_cur + (inc_cur * delta >>> 11)
// 也就是说 delta=127 时频率偏 ±6.2%（约 ±104 音分），
// 而且深度与音高无关（乘的是当前相位增量），音分深度一致。
//
// rate：0.1Hz 单位（5..120 -> 0.5..12.0Hz）
// rate_inc = rate * 34（因为 2^24/(48828.125*10) ≈ 34.36）
// depth：0..127
// enable：0 时深度会慢慢降到 0（2.6ms），不会"啪"一下跳变
//
// LFO 波形：32 点正弦表（5 位相位索引，11.25° 分辨率，够颤音用）
// ============================================================
module vib_lfo #(
    parameter PHASE_BITS = 24
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sample_en,    // 48.8kHz 采样使能
    input  wire [7:0] rate,         // 0.1 Hz 单位
    input  wire [6:0] depth,        // 0..127
    input  wire       enable,
    output reg  signed [7:0] delta
);

    localparam [23:0] RATE_MUL = 24'd34;

    // ---------- LFO 相位累加 ----------
    reg [PHASE_BITS-1:0] phase;
    wire [23:0] rate_inc = ({16'd0, rate} << 5) + ({16'd0, rate} << 1); // rate*34

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          phase <= {PHASE_BITS{1'b0}};
        else if (sample_en)  phase <= phase + rate_inc;
    end

    // ---------- 32 点正弦表：round(127*sin(2*pi*i/32)) ----------
    function [7:0] sin_lfo;
        input [4:0] i;
        begin
            case (i)
                5'd0 : sin_lfo = 8'sd0;
                5'd1 : sin_lfo = 8'sd25;
                5'd2 : sin_lfo = 8'sd49;
                5'd3 : sin_lfo = 8'sd71;
                5'd4 : sin_lfo = 8'sd90;
                5'd5 : sin_lfo = 8'sd106;
                5'd6 : sin_lfo = 8'sd118;
                5'd7 : sin_lfo = 8'sd125;
                5'd8 : sin_lfo = 8'sd127;
                5'd9 : sin_lfo = 8'sd125;
                5'd10: sin_lfo = 8'sd118;
                5'd11: sin_lfo = 8'sd106;
                5'd12: sin_lfo = 8'sd90;
                5'd13: sin_lfo = 8'sd71;
                5'd14: sin_lfo = 8'sd49;
                5'd15: sin_lfo = 8'sd25;
                5'd16: sin_lfo = 8'sd0;
                5'd17: sin_lfo = -8'sd25;
                5'd18: sin_lfo = -8'sd49;
                5'd19: sin_lfo = -8'sd71;
                5'd20: sin_lfo = -8'sd90;
                5'd21: sin_lfo = -8'sd106;
                5'd22: sin_lfo = -8'sd118;
                5'd23: sin_lfo = -8'sd125;
                5'd24: sin_lfo = -8'sd127;
                5'd25: sin_lfo = -8'sd125;
                5'd26: sin_lfo = -8'sd118;
                5'd27: sin_lfo = -8'sd106;
                5'd28: sin_lfo = -8'sd90;
                5'd29: sin_lfo = -8'sd71;
                5'd30: sin_lfo = -8'sd49;
                default: sin_lfo = -8'sd25;
            endcase
        end
    endfunction

    wire signed [7:0] s = sin_lfo(phase[PHASE_BITS-1 -: 5]);

    // ---------- 深度平滑：开/关颤音时不会"啪"一下 ----------
    reg  [6:0] depth_cur;
    wire [6:0] depth_eff = enable ? depth : 7'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) depth_cur <= 7'd0;
        else if (sample_en) begin
            if      (depth_cur < depth_eff) depth_cur <= depth_cur + 7'd1;
            else if (depth_cur > depth_eff) depth_cur <= depth_cur - 7'd1;
        end
    end

    // ---------- 乘深度（只此一处乘法，全局共用） ----------
    wire signed [15:0] prod = s * $signed({1'b0, depth_cur});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         delta <= 8'sd0;
        else if (sample_en) delta <= prod[14:7];   // 带符号 >>7
    end

endmodule
