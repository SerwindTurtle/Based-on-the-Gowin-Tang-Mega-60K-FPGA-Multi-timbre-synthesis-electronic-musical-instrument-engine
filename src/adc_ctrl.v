// ============================================================
// 高云 GW5AT-60 硬件 ADC 控制器
// 功能：产生启动转换脉冲 -> 等待转换完成 -> 锁存结果
// 连续采样：每次转换完成(adc_ready=1)就锁存一次，然后自动开始下一次
// ============================================================
module adc_ctrl (
    input  wire        clk,        // ADC 时钟（需与 Gowin_ADC 的 clk 同域）
    input  wire        rst_n,      // 低有效异步复位
    input  wire        adc_ready,  // 接 Gowin_ADC 的 adcrdy（转换完成标志）
    input  wire [13:0] adc_value,  // 接 Gowin_ADC 的 adcvalue[13:0]（转换结果）
    output reg         adc_start,  // 接 Gowin_ADC 的 adcreqi（1 个时钟宽度的启动脉冲）
    output reg  [13:0] adc_data,   // 锁存后的转换结果
    output reg         adc_valid   // 锁存结果有效脉冲（可扩展用，本设计暂未使用）
);

// ---------- 状态定义 ----------
localparam S_IDLE = 2'd0;  // 空闲
localparam S_TRIG = 2'd1;  // 发出启动脉冲
localparam S_WAIT = 2'd2;  // 等待转换完成

reg [1:0] state;
reg [1:0] state_n;

// ---------- 状态寄存器 ----------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= S_IDLE;
    else
        state <= state_n;
end

// ---------- 次态逻辑 + 启动脉冲输出 ----------
always @(*) begin
    state_n   = state;
    adc_start = 1'b0;
    case (state)
        S_IDLE: begin
            // 空闲一拍后立即开始转换
            state_n = S_TRIG;
        end
        S_TRIG: begin
            // 在 S_TRIG 这一拍把 adcreqi 拉高一个时钟周期
            adc_start = 1'b1;
            state_n   = S_WAIT;
        end
        S_WAIT: begin
            // 等待 Gowin_ADC 给出 adcrdy
            if (adc_ready)
                state_n = S_IDLE;   // 转换完成，回到空闲，下一拍再次触发
            else
                state_n = S_WAIT;
        end
        default: state_n = S_IDLE;
    endcase
end

// ---------- 锁存转换结果 ----------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        adc_data  <= 14'd0;
        adc_valid <= 1'b0;
    end else begin
        if (state == S_WAIT && adc_ready) begin
            adc_data  <= adc_value;   // 转换完成，锁存本次结果
            adc_valid <= 1'b1;
        end else begin
            adc_valid <= 1'b0;
        end
    end
end

endmodule
