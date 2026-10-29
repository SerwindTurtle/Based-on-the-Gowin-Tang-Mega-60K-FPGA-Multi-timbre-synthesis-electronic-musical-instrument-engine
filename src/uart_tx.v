// ============================================================
// uart_tx.v -- 8N1 串口发送（1 起始位 + 8 数据位 + 1 停止位，LSB 先）
//
// 用法（和 param_regs.v 的握手方式）：
// if (ready) begin data <= xxx; send <= 1; end // send 单拍脉冲
// ready = 0 表示正在发送，下一字节要等它变 1
//
// 一帧 10 位，格式固定 8N1，无校验（校验在协议层用 CRC8 做）
// ============================================================
module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       send,      // 单拍脉冲启动
    output reg        tx,        // 串口输出（空闲高）
    output wire       ready      // 1 = 可以接受新字节
);

    localparam integer DIV = CLK_HZ / BAUD;

    reg        busy;
    reg [15:0] cnt;
    reg [3:0]  bits;      // 还要发多少位（含当前位）
    reg [9:0]  sh;        // {停止位, data[7:0], 起始位}，bit0 先发

    // ready 必须把 send 也一起算进去：
    // busy 是寄存器，收到 send 之后要下一个时钟才变 1。
    // 如果 ready 只看 busy，发送方在"send 已拉高、busy 还没变 1"的那一拍
    // 会误以为还能再塞一个字节 -- 第二个字节就被 uart_tx 忽略掉了
    // （表现：一帧里丢一个字节，CRC 永远不过）。
    // 加上 ~send 之后，send 拉高的那一拍 ready 立刻变 0，握手就对了。
    assign ready = ~busy & ~send;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            cnt  <= 16'd0;
            bits <= 4'd0;
            sh   <= 10'h3FF;
            tx   <= 1'b1;
        end else if (!busy) begin
            tx <= 1'b1;
            if (send) begin
                sh   <= {1'b1, data, 1'b0};   // bit9=停止位, bit0=起始位
                tx   <= 1'b0;                 // 立刻拉低，起始位
                busy <= 1'b1;
                bits <= 4'd10;
                cnt  <= DIV - 1;
            end
        end else begin
            if (cnt == 16'd0) begin
                cnt <= DIV - 1;
                if (bits == 4'd1) begin
                    busy <= 1'b0;
                    bits <= 4'd0;
                    tx   <= 1'b1;             // 停止位结束，回空闲
                end else begin
                    sh   <= {1'b1, sh[9:1]};
                    tx   <= sh[1];            // 下一位（老值的 bit1）
                    bits <= bits - 4'd1;
                end
            end else begin
                cnt <= cnt - 16'd1;
            end
        end
    end

endmodule
