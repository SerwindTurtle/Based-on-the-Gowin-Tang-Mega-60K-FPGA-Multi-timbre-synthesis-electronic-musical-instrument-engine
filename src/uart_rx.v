// ============================================================
// uart_rx.v -- 8N1 串口接收（1 起始位 + 8 数据位 + 1 停止位，LSB 先）
//
// 用途：接收网页控制台 / CH340 / 板载 DEBUG-USB2 发来的参数帧。
//
// 设计要点：
// 1) 输入先过两级同步器（rx 是异步信号，直接进状态机容易亚稳态）
// 2) 起始位中点采样确认（滤掉毛刺），之后每个位的中点采样一次
// 3) 波特率分频 = CLK_HZ / BAUD，50MHz / 115200 = 434（测试 115207，误差 0.006%）
//
//  想换波特率：同时改这里和 uart_tx.v 的 BAUD 参数，并让网页用同样的值。
// CH340 / BL616 都支持 115200；115200 是最稳的档位。
// ============================================================
module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,        // 串口输入（空闲高）
    output reg  [7:0] data,      // 收到的字节
    output reg        valid      // 单拍脉冲：data 有效
);

    localparam integer DIV  = CLK_HZ / BAUD;   // 一位的时钟数
    localparam integer HALF = DIV / 2;

    // ---------- 输入同步 + 下降沿检测 ----------
    reg rx_s0, rx_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s0 <= 1'b1;
            rx_s1 <= 1'b1;
        end else begin
            rx_s0 <= rx;
            rx_s1 <= rx_s0;
        end
    end

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bitn;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            cnt   <= 16'd0;
            bitn  <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (st)
                // 等起始位下降沿
                S_IDLE: begin
                    if (!rx_s1) begin
                        cnt <= HALF - 1;
                        st  <= S_START;
                    end
                end

                // 半个位后确认还是低电平（真起始位），然后每 DIV 拍采一位
                S_START: begin
                    if (cnt == 16'd0) begin
                        if (!rx_s1) begin
                            cnt  <= DIV - 1;
                            bitn <= 3'd0;
                            st   <= S_DATA;
                        end else begin
                            st <= S_IDLE;      // 毛刺，丢掉
                        end
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                // 8 个数据位，LSB 先
                S_DATA: begin
                    if (cnt == 16'd0) begin
                        sh[bitn] <= rx_s1;
                        if (bitn == 3'd7) begin
                            cnt <= DIV - 1;
                            st  <= S_STOP;
                        end else begin
                            bitn <= bitn + 3'd1;
                            cnt  <= DIV - 1;
                        end
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                // 停止位中点：不管高低都收下（有些工具停止位偏短）
                S_STOP: begin
                    if (cnt == 16'd0) begin
                        data  <= sh;
                        valid <= 1'b1;
                        st    <= S_IDLE;
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
