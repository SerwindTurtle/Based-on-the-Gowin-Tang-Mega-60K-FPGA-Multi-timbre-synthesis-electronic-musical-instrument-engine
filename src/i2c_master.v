// ============================================================
// i2c_master.v -- 极简 I²C 主机（一次执行一条命令）
//
// 用于驱动 GT911 电容触摸控制器，也可以用来做 I²C 扫描。
//
// 设计要点
// 1. 开漏：sda/scl 都用"输出 0 拉低 + 读回"的方式。
// sda_oe / scl_oe 为 1 时拉低，为 0 时高阻（靠外部/内部上拉为高）。
//  顶层把这两个信号接到真正的 inout 双向 IO 上。
// 2. 一次只执行一条命令，由上层状态机按顺序发起，逻辑简单不会卡死。
// 3. 时钟分频 CLK_DIV：每 bit 分 4 相（放数据、拉高、采样、拉低）。
// 100kHz @50MHz -> CLK_DIV = 50e6/100e3/4 = 125
//
// 命令编码（cmd）：
// 0 = START（同时发第一个字节 {dev[6:0], rw}）
// 1 = WRITE（发 send_byte）
// 2 = READ （收一个字节；最后一个字节把 nack_last 置 1 发 NACK）
// 3 = STOP
// ============================================================
`timescale 1ns / 1ps

module i2c_master #(
    parameter CLK_DIV = 125
) (
    input  wire       clk,
    input  wire       rst_n,

    // ---- 命令接口 ----
    input  wire       req,
    input  wire [1:0] cmd,
    input  wire [7:0] send_byte,
    input  wire       nack_last,

    output reg  [7:0] recv_byte,
    output reg        busy,
    output reg        done,
    output reg        ack_err,

    // ---- 物理线 ----
    input  wire       scl_in,
    input  wire       sda_in,
    output wire       scl_oe,       // 1 = 拉低
    output wire       sda_oe
);

    // ---------------- 时序相位 ----------------
    reg [15:0] ph;
    wire       ph_end = (ph >= CLK_DIV[15:0] - 16'd1);
    reg [1:0]  phase;

    // ---------------- 输出 ----------------
    reg scl_lo, sda_lo;
    assign scl_oe = scl_lo;
    assign sda_oe = sda_lo;

    reg [2:0] bitn;
    reg [7:0] shreg;

    // ---------------- 状态 ----------------
    localparam S_IDLE = 3'd0, S_START = 3'd1, S_SEND = 3'd2, S_ACKW = 3'd3,
               S_RECV = 3'd4, S_ACKM  = 3'd5, S_STOP = 3'd6, S_DONE = 3'd7;
    reg [2:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            ph        <= 16'd0;
            phase     <= 2'd0;
            bitn      <= 3'd0;
            shreg     <= 8'd0;
            scl_lo    <= 1'b0;
            sda_lo    <= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
            ack_err   <= 1'b0;
            recv_byte <= 8'd0;
        end else begin
            done <= 1'b0;
            case (st)
            S_IDLE: begin
                scl_lo <= 1'b0;
                sda_lo <= 1'b0;
                busy   <= 1'b0;
                if (req) begin
                    busy    <= 1'b1;
                    ack_err <= 1'b0;
                    ph      <= 16'd0;
                    phase   <= 2'd0;
                    bitn    <= 3'd0;
                    shreg   <= send_byte;
                    case (cmd)
                        2'd0: st <= S_START;
                        2'd1: st <= S_SEND;
                        2'd2: st <= S_RECV;
                        default: st <= S_STOP;
                    endcase
                end
            end

            // ---- START：SCL 高时 SDA 由高变低 ----
            S_START: begin
                if (ph_end) begin
                    ph <= 16'd0;
                    case (phase)
                    2'd0: sda_lo <= 1'b1;
                    2'd1: scl_lo <= 1'b1;
                    2'd2: begin sda_lo <= ~shreg[7]; bitn <= 3'd1; end   // 取反：oe=1 是拉低
                    default: begin st <= S_SEND; phase <= 2'd0; end
                    endcase
                    if (phase != 2'd3) phase <= phase + 2'd1;
                end else ph <= ph + 16'd1;
            end

            // ---- 发 8 位 ----
            S_SEND: begin
                if (ph_end) begin
                    ph <= 16'd0;
                    case (phase)
                    2'd0: sda_lo <= ~shreg[7];              // 取反：bit=1 释放(高)，bit=0 拉低
                    2'd1: scl_lo <= 1'b0;               // 释放 SCL -> 上升沿
                    2'd2: begin end                      // 从机采样
                    default: begin
                        scl_lo <= 1'b1;                  // 拉低
                        shreg  <= {shreg[6:0], 1'b0};
                        phase  <= 2'd0;
                        if (bitn == 3'd7) st <= S_ACKW;
                        else              bitn <= bitn + 3'd1;
                    end
                    endcase
                    if (phase != 2'd3) phase <= phase + 2'd1;
                end else ph <= ph + 16'd1;
            end

            // ---- 收从机 ACK ----
            S_ACKW: begin
                if (ph_end) begin
                    ph <= 16'd0;
                    case (phase)
                    2'd0: sda_lo <= 1'b0;
                    2'd1: scl_lo <= 1'b0;
                    2'd2: ack_err <= sda_in;             // 低 = ACK
                    default: begin
                        scl_lo <= 1'b1;
                        st     <= S_DONE;
                        phase  <= 2'd0;
                    end
                    endcase
                    if (phase != 2'd3) phase <= phase + 2'd1;
                end else ph <= ph + 16'd1;
            end

            // ---- 收 8 位 ----
            S_RECV: begin
                if (ph_end) begin
                    ph <= 16'd0;
                    case (phase)
                    2'd0: sda_lo <= 1'b0;
                    2'd1: scl_lo <= 1'b0;
                    2'd2: shreg <= {shreg[6:0], sda_in};
                    default: begin
                        scl_lo <= 1'b1;
                        phase  <= 2'd0;
                        if (bitn == 3'd7) st <= S_ACKM;
                        else              bitn <= bitn + 3'd1;
                    end
                    endcase
                    if (phase != 2'd3) phase <= phase + 2'd1;
                end else ph <= ph + 16'd1;
            end

            // ---- 主机发 ACK/NACK ----
            S_ACKM: begin
                if (ph_end) begin
                    ph <= 16'd0;
                    case (phase)
                    2'd0: sda_lo <= ~nack_last;                 // 取反：ACK(0) 要拉低，NACK(1) 要释放
                    2'd1: scl_lo <= 1'b0;
                    2'd2: begin end
                    default: begin
                        scl_lo    <= 1'b1;
                        sda_lo    <= 1'b0;
                        recv_byte <= shreg;
                        st        <= S_DONE;
                        phase     <= 2'd0;
                    end
                    endcase
                    if (phase != 2'd3) phase <= phase + 2'd1;
                end else ph <= ph + 16'd1;
            end

            // ---- STOP：SCL 高时 SDA 由低变高 ----
            S_STOP: begin
                if (ph_end) begin
                    ph <= 16'd0;
                    case (phase)
                    2'd0: begin sda_lo <= 1'b1; scl_lo <= 1'b0; end
                    2'd1: sda_lo <= 1'b0;
                    2'd2: begin end
                    default: begin st <= S_DONE; phase <= 2'd0; end
                    endcase
                    if (phase != 2'd3) phase <= phase + 2'd1;
                end else ph <= ph + 16'd1;
            end

            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
