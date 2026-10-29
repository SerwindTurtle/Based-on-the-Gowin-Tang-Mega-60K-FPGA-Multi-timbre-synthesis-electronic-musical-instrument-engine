// ============================================================
// 声部分配器：把音符事件分配到 N 个独立声部
//
// 每个声部都是一份独立的 (音高 / 力度 / 开关)：
// 声部0: v_note[0] / v_vel[0] / v_gate[0]
// 声部1: v_note[1] / v_vel[1] / v_gate[1]
// ...
//
// 分配策略：
// note_on -> 找编号最小的空闲声部占用；若全忙则"偷声"
// （占用 cur_voice，简单的偷声策略，以后可改成偷最旧的）
// note_off -> 释放 cur_voice
// gate 持续为 1 但音高变了（连奏滑音）-> 只更新当前声部的音高，不换声部
//
// 声部编号位宽 VW 由 NUM_VOICES 自动算出，改 NUM_VOICES 不用动别的地方。
// NUM_VOICES = 8 -> VW = 3
// NUM_VOICES = 16 -> VW = 4
// NUM_VOICES = 32 -> VW = 5
// （这里不用 $clog2，改用条件表达式，兼容性最好）
// ============================================================
module voice_alloc #(
    parameter NUM_VOICES = 32,    // 声部数量
    // 声部编号位宽（按声部数自动决定）。
    // 必须放在端口表之前的 parameter 里，端口声明才能引用它。
    parameter VW = (NUM_VOICES <= 2)  ? 1 :
                   (NUM_VOICES <= 4)  ? 2 :
                   (NUM_VOICES <= 8)  ? 3 :
                   (NUM_VOICES <= 16) ? 4 :
                   (NUM_VOICES <= 32) ? 5 : 6
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- 来自 note_gen 的音符事件 ----
    input  wire        note_on,     // 新音符脉冲
    input  wire        note_off,    // 音符结束脉冲
    input  wire        gate_in,     // 当前是否按下（用于连奏时更新音高）
    input  wire [6:0]  note_in,     // 音高
    input  wire [6:0]  vel_in,      // 力度
    // ---- 各声部状态（打包向量）----
    // 第 i 个声部：v_note[i*7 +: 7]、v_vel[i*7 +: 7]、v_gate[i]
    output reg  [NUM_VOICES*7-1:0] v_note,   // 各声部音高
    output reg  [NUM_VOICES*7-1:0] v_vel,    // 各声部力度
    output reg  [NUM_VOICES-1:0]   v_gate,   // 各声部开关
    // ---- 当前（最近分配的）声部 ----
    output reg  [VW-1:0]           cur_voice,
    output wire                    any_gate  // 有任一声部在响
);

    integer   i;
    reg       found;          // 是否找到空闲声部
    reg [VW-1:0] free_idx;    // 空闲声部编号

    // ---------- 找空闲声部（编号最小的一个） ----------
    always @(*) begin
        found    = 1'b0;
        free_idx = {VW{1'b0}};
        for (i = 0; i < NUM_VOICES; i = i + 1) begin
            if (!found && !v_gate[i]) begin
                found    = 1'b1;
                free_idx = i[VW-1:0];      // 位宽跟着 VW 走
            end
        end
    end

    assign any_gate = |v_gate;

    // ---------- 分配 / 释放 ----------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_note    <= 0;
            v_vel     <= 0;
            v_gate    <= 0;
            cur_voice <= {VW{1'b0}};
        end else if (note_on) begin
            if (found) begin
                // 有空闲声部 -> 占用它
                v_note[free_idx*7 +: 7] <= note_in;
                v_vel[free_idx*7 +: 7]  <= vel_in;
                v_gate[free_idx]        <= 1'b1;
                cur_voice               <= free_idx;
            end else begin
                // 声部全忙 -> 偷声（复用当前声部）
                v_note[cur_voice*7 +: 7] <= note_in;
                v_vel[cur_voice*7 +: 7]  <= vel_in;
                v_gate[cur_voice]        <= 1'b1;
            end
        end else if (note_off) begin
            v_gate[cur_voice] <= 1'b0;      // 释放当前声部
        end else if (gate_in) begin
            // 连奏：音高变了，只更新当前声部的音高
            v_note[cur_voice*7 +: 7] <= note_in;
        end
    end

endmodule
