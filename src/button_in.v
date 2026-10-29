// ============================================================
// 按键输入：同步 + 去抖 + 边沿检测
//
// 用途：把机械按键/按键模块的引脚电平，变成干净的
// gate（按下状态）/ press（按下脉冲）/ released（松开脉冲），
// 直接喂给 voice_alloc，不经过 ADC。
//
// 按键不使用 ADC 的原因：
// 按键输出的是数字电平（0 / 3.3V），用 ADC 读是绕远路，
// 而且还要调 vsenctl / chen 选源。直接读数字 IO 更快更可靠。
// ADC 那条通路留给压力传感器（真正的模拟量）。
//
// 去抖时间 = 2^DBNC_BITS / 时钟频率
// DBNC_BITS=16, clk=3.125MHz -> 65536/3.125M ≈ 21ms
//
// ACTIVE_LOW：按键模块"按下低电平"就设 1，"按下高电平"设 0
// 本项目的按键测试是松开 0V / 按下 3.3V= 高有效，
// 所以 top.v 里例化时传的是 ACTIVE_LOW = 1'b0。
// 曾经按注释猜成低有效(1)，症状是：上电就一直响，按下反而没声。
// ============================================================
module button_in #(
    parameter DBNC_BITS  = 16,      // 去抖计数位宽
    parameter ACTIVE_LOW = 1'b0     // 0 = 按下为高电平（本按键模块就是这种）
) (
    input  wire clk,
    input  wire rst_n,
    input  wire pin,                // 按键引脚原始电平
    output reg  gate,               // 去抖后的按下状态（1 = 按下）
    output reg  press,              // 按下脉冲（1 拍）
    output reg  released             // 松开脉冲（1 拍）
);

    // ---------- 三级同步（按键是异步慢信号）----------
    reg [2:0] sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sync <= {3{ACTIVE_LOW}};   // 低有效时空闲为高，复位到 1；高有效复位到 0
        else
            sync <= {sync[1:0], pin};
    end

    // 归一化成"按下 = 1"
    wire level = ACTIVE_LOW ? ~sync[2] : sync[2];

    // ---------- 去抖 + 边沿 ----------
    reg [DBNC_BITS-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= {DBNC_BITS{1'b0}};
            gate    <= 1'b0;
            press   <= 1'b0;
            released <= 1'b0;
        end else begin
            press   <= 1'b0;
            released <= 1'b0;

            if (level != gate) begin
                // 电平与当前状态不同 -> 计时，连续满 21ms 才认账
                if (cnt == {DBNC_BITS{1'b1}}) begin
                    gate <= level;
                    cnt  <= {DBNC_BITS{1'b0}};
                    if (level) press   <= 1'b1;
                    else       released <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end else begin
                cnt <= {DBNC_BITS{1'b0}};
            end
        end
    end

endmodule
