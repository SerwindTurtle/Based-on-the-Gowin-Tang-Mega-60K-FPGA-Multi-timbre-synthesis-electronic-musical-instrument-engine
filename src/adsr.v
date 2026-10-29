// ============================================================
// adsr.v - 包络发生器
//
// 状态：IDLE / ATTACK / DECAY / SUSTAIN / RELEASE。
// rate 控制更新速率，exp_shift 控制指数衰减，one_shot 用于打击音。
// pedal_en 打开延音踏板，松键后按 pedal_step 慢速释放。
// ============================================================

module adsr #(
    parameter WIDTH = 16
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             sample_en,    // 采样率使能：1 = 本拍更新一次包络
    input  wire [3:0]       rate,         // 包络速率分频：0=每拍都更新，N=每 2^N 拍更新
    input  wire [3:0]       exp_shift,    // 衰减曲线：0=线性，>0=指数衰减的右移位数
    input  wire             one_shot,     // 1 = 衰减到 0 即自终止（不看 gate）
    input  wire             gate,         // 1 = 按下
    // 延音踏板：松开后用一个独立的慢释音步长，
    // 即使 one_shot 音色（钢琴/古筝/木琴）也不会瞬间掐断。
    input  wire             pedal_en,
    input  wire [WIDTH-1:0] pedal_step,
    input  wire [WIDTH-1:0] atk_step,     // 起音步长
    input  wire [WIDTH-1:0] dec_step,     // 衰减步长（线性模式用）
    input  wire [WIDTH-1:0] sus_level,    // 延音电平
    input  wire [WIDTH-1:0] rel_step,     // 释音步长
    output reg  [WIDTH-1:0] env,          // 当前包络值
    output reg              active        // 1 = 包络还在工作（可用于偷声判断）
);

    localparam S_IDLE = 3'd0,
               S_ATK  = 3'd1,
               S_DEC  = 3'd2,
               S_SUS  = 3'd3,
               S_REL  = 3'd4;

    localparam [WIDTH-1:0] MAXV = {WIDTH{1'b1}};
    // 延音踏板打开时，one-shot 衰减到这个下限就保持住（约 50%），
    // 松手后从这个电平慢慢放掉；否则按住久了包络已经接近 0，尾音会听不出来。
    localparam [WIDTH-1:0] PEDAL_FLOOR = MAXV >> 1;

    // 指数衰减：每拍减去"当前值的 1/2^exp_shift"，包络越小时减得越少，形成"先快后慢"；
    // 当这一步已经减不动（env <= 步长）时直接归零，保证一定终止、绝不卡住。
    wire [WIDTH-1:0] exp_step = (exp_shift == 4'd0) ? dec_step
                                                    : (env >> exp_shift);
    // 一步衰减量：始终至少减 1，所以不可能卡住不动
    wire [WIDTH-1:0] step_exp = (exp_step == {WIDTH{1'b0}}) ? {{(WIDTH-1){1'b0}}, 1'b1}
                                                            : exp_step;
    // 包络还能不能安全地减掉这一步（不能减 -> 该结束了）
    wire exp_last = (env <= step_exp);

    // 延音踏板只允许"变慢"，不能比原来的释音还快（否则持续音会被缩短）
    // rel_step=0（立即切断）时仍然允许踏板接管
    wire [WIDTH-1:0] rel_step_eff = (rel_step == {WIDTH{1'b0}}) ? pedal_step :
                                    ((pedal_step < rel_step) ? pedal_step : rel_step);

    reg [2:0] st;
    reg       gate_d;
    // 延音踏板的 4 倍慢速节拍：释音/one-shot 衰减都只在 pedal_tick 走一步
    reg [1:0] pedal_cnt;
    wire      pedal_tick = (pedal_cnt == 2'd3);

    // ---------- 包络速率分频：只有计数满 2^rate - 1 时才走一步包络 ----------
    // rate = 0 时 rate_cnt 恒为 0、rate_tick 恒为 1 -> 每个采样点都更新（行为和之前一致）
    reg  [3:0] rate_cnt;
    wire [3:0] rate_mask = (rate == 4'd0) ? 4'd0 : ((4'd1 << rate) - 4'd1);
    wire       rate_tick = (rate_cnt == rate_mask);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rate_cnt <= 4'd0;
        else if (sample_en)
            rate_cnt <= rate_tick ? 4'd0 : (rate_cnt + 4'd1);
    end

    // 踏板慢速节拍：每个 rate_tick 走一格，4 格才让包络走一步
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pedal_cnt <= 2'd0;
        else if (sample_en && rate_tick)
            pedal_cnt <= pedal_cnt + 2'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= S_IDLE;
            env    <= {WIDTH{1'b0}};
            active <= 1'b0;
            gate_d <= 1'b0;
        end else if (sample_en && rate_tick) begin
            gate_d <= gate;

            if (gate & ~gate_d) begin
                // ---- 起音：从头开始爬（不从 0 而是从当前值，避免爆音）----
                st     <= S_ATK;
                active <= 1'b1;
            end else if (~gate & gate_d) begin
                // ---- 释音 ----
                st <= S_REL;
            end else begin
                case (st)
                    S_IDLE: begin
                        env    <= {WIDTH{1'b0}};
                        active <= 1'b0;
                    end
                    S_ATK: begin
                        if (env >= MAXV - atk_step) begin
                            env <= MAXV;
                            st  <= S_DEC;
                        end else begin
                            env <= env + atk_step;
                        end
                    end
                    S_DEC: begin
                        // 打击音(one_shot) 与 持续音 的衰减目标完全不同：
                        // one_shot = 1 -> 一路衰减到 0，然后结束
                        // one_shot = 0 -> 只衰减到延音电平就进 SUSTAIN
                        if (one_shot) begin
                            // 延音踏板打开时，one-shot（钢琴/拨弦）的衰减放慢 4 倍，
                            // 这样按住期间不会很快衰减到 0，松手才有足够的包络做尾音。
                            if (!pedal_en || pedal_tick) begin
                                if (pedal_en && (env <= PEDAL_FLOOR)) begin
                                    // 踏板保持下限：不要衰减到 0，松手才有尾音
                                    env <= PEDAL_FLOOR;
                                end else if (exp_last) begin
                                    env    <= {WIDTH{1'b0}};
                                    st     <= S_IDLE;
                                    active <= 1'b0;
                                end else begin
                                    env <= env - step_exp;
                                end
                            end
                        end else begin
                            //  这里之前写的是"等 env 掉到接近 0 才跳 sus_level"，
                            // 导致持续音的真实包络是：
                            // 起音冲到 100% -> 衰减 190ms 掉到近 0
                            // -> 瞬间跳回 70% 再持续
                            // 听感就是"先响一下、静下去、又响起来"，还带咔哒声。
                            // 正确做法：降到延音电平附近就停住。下一拍不能再减
                            // （env - step_exp <= sus_level）也要提前收住，
                            // 否则最后一步会冲到 sus_level 以下。
                            // 用 17 位比较，避免 sus_level 接近满量程时相加溢出。
                            if ({1'b0, env} <= {1'b0, sus_level} + {1'b0, step_exp}) begin
                                env <= sus_level;
                                st  <= S_SUS;
                            end else begin
                                env <= env - step_exp;
                            end
                        end
                    end
                    S_SUS: begin
                        env <= sus_level;
                    end
                    S_REL: begin
                        if (pedal_en) begin
                            // 延音踏板：用独立慢步长，且每 4 个 rate_tick 才走一步
                            // （比原来的释音慢 4 倍）；one_shot 也不立即归零
                            if (pedal_tick) begin
                                if (env <= rel_step_eff) begin
                                    env    <= {WIDTH{1'b0}};
                                    st     <= S_IDLE;
                                    active <= 1'b0;
                                end else begin
                                    env <= env - rel_step_eff;
                                end
                            end
                        end else if (one_shot || (env <= rel_step)) begin
                            // 未开延音：one_shot 音色追求"松手瞬间消失"，直接归零
                            env    <= {WIDTH{1'b0}};
                            st     <= S_IDLE;
                            active <= 1'b0;
                        end else begin
                            env <= env - rel_step;
                        end
                    end
                    default: st <= S_IDLE;
                endcase
            end
        end
    end

endmodule