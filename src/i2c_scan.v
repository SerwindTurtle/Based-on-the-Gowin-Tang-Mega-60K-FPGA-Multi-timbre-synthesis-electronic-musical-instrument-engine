// ============================================================
// i2c_scan.v -- I²C 地址扫描器（用于找出总线上有哪些器件）
//
// 用途：ADS1115 到底是 0x48 还是 0x49、模块上有几个器件、
// 甚至"到底有没有器件"，扫一遍就全知道了。
//
// 做法：
// 从 0x08 依次试到 0x77，每个地址发一次 START + 地址(W)，
// 看从机是否应答（ACK）。有应答的地址按顺序存进 addr_ch[0..7]，
// 最多记 8 个，同时给出总数 found_cnt。
//
// 结果怎么显示：
// 顶层把 addr_ch 接到调试界面的"压力值"通道上，
// 于是 8 行会直接显示找到的地址（十进制 3 位）：
// 0x48 = 72
// 0x49 = 73
// 一眼就能看出来。
//
// 总线共用：本模块有自己的 i2c_master 实例。
// 只有在 page_dbg=1（调试界面）时顶层才把 SDA/SCL 切给扫描器，
// 平时扫描器空闲（两条线都释放），不影响 ADS1115 驱动。
// ============================================================
`timescale 1ns / 1ps

module i2c_scan #(
    parameter CLK_DIV = 500        // 25kHz（和 ADS 驱动一致，弱上拉也稳）
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 物理线（开漏：oe=1 拉低）----
    input  wire        sda_in,
    input  wire        scl_in,
    output wire        sda_oe,
    output wire        scl_oe,

    // ---- 结果 ----
    output reg  [63:0] addr_ch,    // 8 个找到的地址（0 = 空位）
    output reg  [7:0]  found_cnt,  // 找到的器件总数
    output reg         busy        // 扫描进行中
);

    // ------------------------------------------------------------
    // i2c_master 实例
    // ------------------------------------------------------------
    reg        req;
    reg  [1:0] cmd;
    reg  [7:0] send_byte;
    wire [7:0] recv_byte;
    wire       done, ack_err;
    wire       m_busy;

    i2c_master #(.CLK_DIV(CLK_DIV)) u_master (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (req),
        .cmd       (cmd),
        .send_byte (send_byte),
        .nack_last (1'b0),
        .recv_byte (recv_byte),
        .busy      (m_busy),
        .done      (done),
        .ack_err   (ack_err),
        .scl_in    (scl_in),
        .sda_in    (sda_in),
        .scl_oe    (scl_oe),
        .sda_oe    (sda_oe)
    );

    // ------------------------------------------------------------
    // 扫描状态机
    // ------------------------------------------------------------
    localparam S_NEXT = 2'd0,   // 准备下一个地址
               S_REQ  = 2'd1,   // 发 START + 地址
               S_WAIT = 2'd2,   // 等这次事务完成
               S_GAP  = 2'd3;   // 地址之间留一点间隔

    reg [1:0] st;
    reg [6:0] cur;              // 当前探测的地址
    reg [3:0] slot;             // 已记录的数量
    reg [15:0] gap;

    localparam [15:0] GAP_TICKS = 16'd200;   // 50MHz 下 4us 间隔

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_NEXT;
            cur       <= 7'h08;
            slot      <= 4'd0;
            gap       <= 16'd0;
            req       <= 1'b0;
            cmd       <= 2'd0;
            send_byte <= 8'd0;
            addr_ch   <= 64'd0;
            found_cnt <= 8'd0;
            busy      <= 1'b1;
        end else begin
            req <= 1'b0;                    // 默认只拉高一拍

            case (st)
            // ---- 准备下一个地址 ----
            S_NEXT: begin
                if (cur > 7'h77) begin
                    // 一轮扫完：保持结果，停一会儿再重扫
                    busy <= 1'b0;
                    if (gap >= 16'd30000) begin   // 约 0.6ms 后重扫
                        gap     <= 16'd0;
                        cur     <= 7'h08;
                        slot    <= 4'd0;
                        addr_ch <= 64'd0;         // 清空重新扫
                        busy    <= 1'b1;
                        st      <= S_REQ;
                    end else begin
                        gap <= gap + 16'd1;
                    end
                end else begin
                    st <= S_REQ;
                end
            end

            // ---- 发 START + 地址(写) ----
            S_REQ: begin
                req       <= 1'b1;
                cmd       <= 2'd0;                 // START + 首字节
                send_byte <= {cur, 1'b0};          // 7 位地址 + 写方向
                st        <= S_WAIT;
            end

            // ---- 等事务结束 ----
            S_WAIT: if (done) begin
                if (!ack_err && slot < 4'd8) begin
                    // 有应答：记下这个地址
                    addr_ch[slot*8 +: 8] <= {1'b0, cur};
                    slot                 <= slot + 4'd1;
                end
                if (!ack_err) found_cnt <= found_cnt + 8'd1;
                // 发 STOP 收尾，让总线回到空闲
                req       <= 1'b1;
                cmd       <= 2'd3;                 // STOP
                send_byte <= 8'd0;
                st        <= S_GAP;
            end

            // ---- 间隔 + 推进地址 ----
            S_GAP: if (done) begin
                if (gap >= GAP_TICKS) begin
                    gap <= 16'd0;
                    cur <= cur + 7'd1;
                    st  <= S_NEXT;
                end else begin
                    gap <= gap + 16'd1;
                end
            end

            default: st <= S_NEXT;
            endcase
        end
    end

endmodule
