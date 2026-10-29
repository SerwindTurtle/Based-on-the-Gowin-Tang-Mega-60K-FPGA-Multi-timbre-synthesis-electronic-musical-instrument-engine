// ============================================================
// 键盘输入：N 个按键（默认 8 个 = 一个八度）
//
// 用途：把 N 个机械按键/按键模块的引脚电平，变成干净的
// gate（按下状态）/ press（按下脉冲）/ released（松开脉冲），
// 再按下面两条规则直接产出"每个声部的 音高 / 力度 / 开关"：
//
// 规则 1（位映射，注意是反序的）：
// note_out[i*7 +: 7] = NOTE_BASE + (N-1-i)
// 即 KEY[0] 是这一排里最高的音，KEY[N-1] 是最低的音。
// 这么做是为了让按键在面板上从左到右的排列，
// 正好对应"从低音到高音"（KEY7 在左下角那一端）。
// 如果你的接线是反的：把实例化里的 .REVERSE(1'b0) 即可。
//
// 规则 2（固定声部映射）：第 i 个键固定占用第 i 个声部。
// 好处：多键同时按下时各自独立发声、各自独立衰减，互不打断
// （这正是钢琴该有的行为：低音可以一直按着余音，同时弹高音）。
// 代价：同时能响的键数 = 声部数。NUM_VOICES=32 时够 8 键用。
// 因为每个键占的声部号固定，所以"同一键重复按下"必然伴随
// gate 的 0->1 上升沿，振荡器和包络都会正确重新触发。
//
// 去抖时间 = 2^DBNC_BITS / 时钟频率
// DBNC_BITS=15, clk=3.125MHz -> 32768/3.125M ≈ 10.5ms
// （机械按键 5~10ms 足够；嫌灵敏/迟钝就调这个数）
//
// ACTIVE_LOW：按键模块"按下低电平"就设 1，"按下高电平"设 0
//  本项目测试按键是松开 0V / 按下 3.3V= 高有效，用 0
// ============================================================
module keyboard_in #(
    parameter NKEYS      = 8,       // 按键个数
    parameter DBNC_BITS  = 15,      // 去抖计数位宽 -> 2^15 / 3.125MHz ≈ 10.5ms
    parameter ACTIVE_LOW = 1'b0,    // 0 = 按下为高电平（本项目按键就是这种）
    parameter REVERSE    = 1'b0,    // 1 = KEY[0] 发最高的音
    parameter [6:0] NOTE_BASE = 7'd60,   // 最低那个键的音（MIDI 60 = C4）
    parameter [6:0] VELOCITY  = 7'd100   // 固定力度（以后接压力传感器可改成动态）
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [NKEYS-1:0]        key,       // 按键原始电平（每键一位）
    // ---- 每键独立的状态（调试/LED 用，可选接） ----
    output wire [NKEYS-1:0]        gate,      // 去抖后的按下状态
    output wire [NKEYS-1:0]        press,     // 按下脉冲（1 拍，每键独立）
    output wire [NKEYS-1:0]        released,  // 松开脉冲（1 拍，每键独立）
    // ---- 直接打包成 voice_alloc / synth_voices 用的格式 ----
    output wire [NKEYS*7-1:0]      note_out,  // 第 i 键：note_out[i*7 +: 7]
    output wire [NKEYS*7-1:0]      vel_out,   // 第 i 键：vel_out [i*7 +: 7]
    // ---- 汇总信号 ----
    output wire [NKEYS-1:0]        any_key    // 原始电平（未去抖），调试用
);

    assign any_key = key;

    // ============================================================
    // 钢琴白键的半音偏移（一个八度内的 8 个白键）
    // 度数 0..7 = C D E F G A B C
    // 偏移 0 2 4 5 7 9 11 12
    //  不能用 "i 就是半音数" 那种简单映射 -- 钢琴的白键不是半音阶，
    // C 到 D 差 2 个半音，E 到 F 只差 1 个，必须查这张表。
    // ============================================================
    function [4:0] white_semi;
        input [3:0] d;
        begin
            case (d)
                4'd0: white_semi = 5'd0;    // C
                4'd1: white_semi = 5'd2;    // D
                4'd2: white_semi = 5'd4;    // E
                4'd3: white_semi = 5'd5;    // F
                4'd4: white_semi = 5'd7;    // G
                4'd5: white_semi = 5'd9;    // A
                4'd6: white_semi = 5'd11;   // B
                4'd7: white_semi = 5'd12;   // C（高八度）
                default: white_semi = 5'd0;
            endcase
        end
    endfunction

    // 空闲电平：高有效时空闲 = 0；低有效时空闲 = 1
    localparam IDLE = ACTIVE_LOW;

    genvar i;
    generate
        for (i = 0; i < NKEYS; i = i + 1) begin : g_key

            // ---------- 三级同步（按键是异步慢信号） ----------
            reg [2:0] sync;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    sync <= {3{IDLE}};
                else
                    sync <= {sync[1:0], key[i]};
            end

            // 归一化成"按下 = 1"
            wire level = ACTIVE_LOW ? ~sync[2] : sync[2];

            // ---------- 去抖 + 边沿 ----------
            reg [DBNC_BITS-1:0] cnt;
            reg                 g_r;
            reg                 p_r;
            reg                 r_r;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    cnt <= {DBNC_BITS{1'b0}};
                    g_r <= 1'b0;
                    p_r <= 1'b0;
                    r_r <= 1'b0;
                end else begin
                    p_r <= 1'b0;
                    r_r <= 1'b0;

                    if (level != g_r) begin
                        // 电平与当前状态不同 -> 计时，连续满去抖时间才认账
                        if (cnt == {DBNC_BITS{1'b1}}) begin
                            g_r <= level;
                            cnt <= {DBNC_BITS{1'b0}};
                            if (level) p_r <= 1'b1;
                            else       r_r <= 1'b1;
                        end else begin
                            cnt <= cnt + 1'b1;
                        end
                    end else begin
                        cnt <= {DBNC_BITS{1'b0}};
                    end
                end
            end

            assign gate[i]     = g_r;
            assign press[i]    = p_r;
            assign released[i] = r_r;

            // ---------- 音高映射 ----------
            // 第 i 个键 -> 八度内的度数 i（0=C,1=D,...,7=高八度 C）
            // 再查 white_semi 得到半音偏移，加上基准音。
            // REVERSE=1 时把度数反过来（KEY[0] 发最高的音）。
            //  i 是 genvar，必须放在 localparam 里才能被综合器当常量
            localparam [3:0] DEG_C    = REVERSE ? (4'd7 - i) : i;
            localparam [6:0] KEY_NOTE = NOTE_BASE + {2'b0, white_semi(DEG_C)};

            assign note_out[i*7 +: 7] = KEY_NOTE;
            assign vel_out [i*7 +: 7] = VELOCITY;

        end
    endgenerate

endmodule
