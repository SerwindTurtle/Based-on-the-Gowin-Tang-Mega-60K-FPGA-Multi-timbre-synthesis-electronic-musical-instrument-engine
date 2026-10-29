// ============================================================
// ads1115_ctrl.v - 两片 ADS1115 读取 8 路压力
//
// I2C 400kHz，地址 0x48/0x49；按键按下时扫描对应通道并保持峰值。
// 输出 vel_ch（力度）、force_ch/raw_ch（调试）、seen_ch（通道检测）。
// ============================================================

`timescale 1ns / 1ps

module ads1115_ctrl #(
    // ---- I²C 时钟分频 = CLK_HZ / I2C_HZ / 4 ----
    // 50MHz / 400kHz / 4 = 31 （快速模式，推荐）
    // 50MHz / 100kHz / 4 = 125 （标准模式，更稳但慢 4 倍）
    parameter CLK_DIV   = 31,
    // ---- 两颗从机地址（由 ADDR 引脚决定）----
    parameter ADDR_1    = 7'h48,      // ADDR 接 GND
    parameter ADDR_2    = 7'h49,      // ADDR 接 VCC
    // ---- 数据速率：3'd7 = 860SPS，3'd4 = 128SPS ----
    parameter DR_SEL    = 3'd7,
    // ---- 力度映射 ----
    parameter [15:0] FORCE_MIN = 16'd400,    // 死区（低于它算 0，滤底噪 + 判断传感器是否接上）
    // ---- 压力显示平滑（只影响调试显示，不影响力度/音频）----
    // 上升：立即跟上（不滤波，峰值不会丢）
    // 下降：每个采样点衰减 1/2^FILT_SHIFT
    // 采样率约 500Hz（25kHz I²C + 只读 1 路）：
    // 1 -> 回落时间常数 ≈ 2 点 ≈ 4ms （最快，推荐）
    // 2 -> ≈ 4 点 ≈ 8ms
    // 3 -> ≈ 8 点 ≈ 16ms（原来的值，调试时感觉拖尾）
    parameter [3:0]  FILT_SHIFT = 4'd1,
    // ---- 空闲巡检间隔（clk 周期数）：50MHz 下 50000 = 1ms ----
    parameter [15:0] IDLE_TICKS = 16'd5000,    // 100us（连续模式下不必多等，保持高速采样）
    // 通道使能掩码：bit i = 1 表示第 i 路接了传感器，才去采它
    // 没接的通道如果不屏蔽，输入悬空会采到噪声，
    // 表现为"别的键的柱子随机乱冒"。
    // bit0 = AIN0(0x48) ... bit3 = AIN3(0x48)；bit4..7 = 0x49 的 AIN0..3
    parameter [7:0]  CH_MASK    = 8'hFF
) (
    input  wire        clk,           // 系统时钟（50MHz）
    input  wire        rst_n,

    // ---- I²C 物理线（外部开漏，oe = 1 表示拉低）----
    input  wire        sda_in,
    input  wire        scl_in,
    output wire        sda_oe,
    output wire        scl_oe,

    // ---- 按键状态（来自 keyboard_in，1 = 该键当前按下）----
    input  wire [7:0]  key_gate,
    // ---- 调试页强制扫描：1 = 不管有没有按键，都扫所有 CH_MASK 使能的通道 ----
    // 用途：调试界面上按其它琴键时，当前通道也不会被"只读按下键"的逻辑跳过，
    // 压力条能一直跟着传感器走，不会出现"按了几下突然不刷新"。
    input  wire        force_scan,

    // ---- 输出 ----
    output reg  [63:0] vel_ch,        // 每键力度 0~127：vel_ch[i*8 +: 8]
    // 实时力度（不管有没有按键都更新）：单传感器模式下直接给所有键用
    output reg  [7:0]  vel_live,
    output reg  [63:0] force_ch,      // 每键 peak 高 8 位（调试）
    output reg         data_ok,       // I²C 至少成功过一次
    output reg  [7:0]  err_cnt,       // I²C 无应答计数
    // 每通道"曾经读到过真实压力"标志（粘滞，上电清零）。
    // 用途：传感器还没接 / 该通道没接传感器时，顶层据此退回固定力度，
    // 避免"力度恒为 0 导致整台琴没声音"。
    output reg  [7:0]  seen_ch,
    // 调试输出：每通道最新一次原始读数的高 8 位（raw_ch[i*8 +: 8]）。
    // 和 force_ch 的区别：这个不管按键有没有按下都更新。
    // 说明：驱动只在按键按下时才累计峰值，如果只是单独捏传感器
    // 而没按到琴键，force_ch 不会变 -- 那样根本没法判断传感器通不通。
    output reg  [63:0] raw_ch
);

    // ============================================================
    // I²C 主机
    // ============================================================
    // cmd: 0 = START+地址字节, 1 = WRITE, 2 = READ, 3 = STOP
    reg         i2c_req;
    reg  [1:0]  i2c_cmd;
    reg  [7:0]  i2c_send;
    reg         i2c_nack;
    wire [7:0]  i2c_recv;
    wire        i2c_done, i2c_ack_err;

    i2c_master #(
        .CLK_DIV (CLK_DIV)
    ) u_i2c (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (i2c_req),
        .cmd       (i2c_cmd),
        .send_byte (i2c_send),
        .nack_last (i2c_nack),
        .recv_byte (i2c_recv),
        .busy      (),
        .done      (i2c_done),
        .ack_err   (i2c_ack_err),
        .scl_in    (scl_in),
        .sda_in    (sda_in),
        .scl_oe    (scl_oe),
        .sda_oe    (sda_oe)
    );

    // ============================================================
    // 状态机状态
    // ============================================================
    localparam [3:0] S_IDLE      = 4'd0,   // 空闲等待（没有键按下时）
                     S_PICK      = 4'd1,   // 挑选下一个要读的通道
                     S_CFG_START = 4'd2,   // 写 Config：START + 地址(W)
                     S_CFG_REG   = 4'd3,   // 写 Config：寄存器指针 0x01
                     S_CFG_HI    = 4'd4,   // 写 Config：高字节
                     S_CFG_LO    = 4'd5,   // 写 Config：低字节
                     S_CFG_STOP  = 4'd6,   // 写 Config：STOP
                     S_WAIT_CNV  = 4'd7,   // 等转换完成
                     S_RD_START  = 4'd8,   // 读：START + 地址(W)
                     S_RD_PTR    = 4'd9,   // 读：寄存器指针 0x00
                     S_RD_RSTART = 4'd10,  // 读：重复 START + 地址(R)
                     S_RD_B1     = 4'd11,  // 读：高字节（回 ACK）
                     S_RD_B2     = 4'd12,  // 读：低字节（回 NACK）
                     S_RD_STOP   = 4'd13,  // 读：STOP
                     S_STORE     = 4'd14;  // 处理结果 + 推进通道

    reg [3:0]  st;
    reg [3:0]  scan_idx;      // 本轮已检查到第几个通道（0~8）
    reg [3:0]  ch;            // 当前正在读的通道 0~7
    reg [15:0] idle_cnt;      // 空闲巡检计数
    reg [19:0] cnv_cnt;       // 转换等待计数
    reg [15:0] rd_hi;         // 读回的高字节暂存
    reg [15:0] raw_val;       // 本通道 16 位原始值
    reg [7:0]  gate_prev;     // 每通道上一拍的按键状态（找上升沿）
    reg [15:0] peak_val [0:7];// 每通道本次按下的力峰值（16 位）
    // 本次按下"必须至少采一次"的标记：
    // 按下沿置位，采样成功后才清。这样即使读回时手已经松开，
    // 这一拍采样仍然算数（解决"快速轻点漏检"）。
    reg [7:0]  capture;
    reg        trx_err;       // 本通道这次事务里是否出现过 NACK
    // 连续转换模式：配置只写一次，之后循环只读结果
    reg        cfg_ok;
    // 读数平滑：非对称一阶低通（上升直通，下降 1/2^FILT_SHIFT）
    // 只用于调试显示，力度用的是 raw_val 峰值，不受影响。
    reg [15:0] raw_f;
    // 看门狗：状态机超时保护
    reg [25:0] wdt;
    reg [3:0]  st_prev;

    // ============================================================
    // key_gate 跨时钟域同步
    // ============================================================
    // key_gate 来自 keyboard_in，跑在 adc_clk(3.125MHz) 域；
    // 本模块跑在 clk(50MHz) 域。按键电平最多每 2.6ms 变一次，
    // 用标准两级触发器同步即可，不需要握手。
    reg [7:0] gate_s1, gate_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_s1 <= 8'd0;
            gate_s2 <= 8'd0;
        end else begin
            gate_s1 <= key_gate;
            gate_s2 <= gate_s1;
        end
    end
    wire [7:0] key_g = gate_s2;        // 同步后的按键状态（本域使用）

    // force_scan 来自 adc_clk 域（page_dbg），同样做两级同步
    reg fs_s1, fs_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fs_s1 <= 1'b0;
            fs_s2 <= 1'b0;
        end else begin
            fs_s1 <= force_scan;
            fs_s2 <= fs_s1;
        end
    end
    wire force_scan_s = fs_s2;

    // 前 4 路在 #1，后 4 路在 #2
    wire [6:0] cur_addr = (ch < 4'd4) ? ADDR_1 : ADDR_2;
    //
    // ADS1115 的 MUX 编码是：
    // 000 = AIN0-AIN1 差分 001 = AIN0-AIN3 差分
    // 010 = AIN1-AIN3 差分 011 = AIN2-AIN3 差分
    // 100 = AIN0 对 GND 单端 101 = AIN1 对 GND 单端
    // 110 = AIN2 对 GND 单端 111 = AIN3 对 GND 单端
    // 原来写成 ch[1:0]（000~011），那是差分模式。
    // 于是 AIN0 接 GND 时读到负数（显示 0 被钳掉），
    // 接 3.3V 时和悬空的 AIN1 差分仍≈0 -- 跟测试结果完全一致。
    // 单端必须从 3'b100 开始。
    wire [2:0] cur_mux  = 3'b100 + {1'b0, ch[1:0]};

    // Config 寄存器内容
    wire [15:0] cfg_word = { 1'b1,        // OS : 启动转换
                             cur_mux,     // MUX : 100+ch = AINx 对 GND 单端
                             3'b001,      // PGA : ±4.096V
                             1'b0,        // MODE : 连续转换
    // 连续转换模式：单次模式每次采样都要"写配置(5次事务) + 等转换
    // + 读结果(5次事务)"，25kHz 下一共约 6.8ms，手感明显迟滞。
    // 连续模式下配置只写一次，之后每轮只读结果（5次事务，约 2.4ms），
    // 快 2.8 倍。内部按 DR 自动连续转换，读到的总是最新值。
                             DR_SEL,      // DR : 860 / 128 SPS
                             5'b00011 };  // 比较器关闭

    // 转换等待：860SPS 约 1.2ms，128SPS 约 8ms（50MHz 下 1 周期 = 20ns）
    localparam [19:0] CNV_WAIT = (DR_SEL >= 3'd6) ? 20'd120000 : 20'd400000;   // 860SPS: 2.4ms（原 1.2ms 太紧，转换可能还没完成）

    // 是否有键按下（决定"只读按下的键"还是"慢速巡检全部"）
    wire any_gated = |key_g;

    // ============================================================
    // 力度映射（ 低端加敏）
    // ============================================================
    // 旧算法：vel = (raw - 400) >> 7，每 128 码才 +1。
    // 测试问题：低压力时 raw 本来就小，算出来一直是 0，
    // 顶层保底把它钳到 20 -> 听感"怎么按都是最小声"。
    //
    // 现在直接用 ADC 的高字节 h = raw[15:8]（和调试页压力条同一个量），
    // 分段映射，低端更陡、高端仍保留动态：
    // h 0~ 2 -> 0 （死区，防底噪）
    // h 3~ 8 -> 16~31 （极轻区，每 +1 -> +3）
    // h 9~24 -> 32~62 （轻按区，每 +1 -> +2）
    // h 25~64 -> 64~103 （中按区，每 +1 -> +1）
    // h 65~111 -> 104~127 （重按区，每 +2 -> +1）
    // h 112+ -> 127 （满力度）
    // 把"一按就满 / 松一点就没"改宽 --
    // 旧曲线 h=80 就满，新曲线要到 h≈111 才满，中间多了 30 格。
    function [7:0] map_vel;
        input [15:0] p;
        reg   [7:0]  h;
        reg   [8:0]  v;
        begin
            if (p[15]) begin
                map_vel = 8'd0;                 // 负值（超量程/接反）当 0
            end else begin
                h = p[15:8];
                if (h <= 8'd2)
                    map_vel = 8'd0;
                else if (h <= 8'd8) begin
                    v = ({1'b0, h} - 9'd3) * 9'd3 + 9'd16;    // 16~31
                    map_vel = v[7:0];
                end else if (h <= 8'd24) begin
                    v = ({1'b0, h} - 9'd9) * 9'd2 + 9'd32;    // 32~62
                    map_vel = v[7:0];
                end else if (h <= 8'd64) begin
                    v = 9'd64 + ({1'b0, h} - 9'd25);          // 64~103
                    map_vel = v[7:0];
                end else begin
                    v = 9'd104 + (({1'b0, h} - 9'd65) >> 1);  // 104~127
                    map_vel = (v > 9'd127) ? 8'd127 : v[7:0];
                end
            end
        end
    endfunction

    // ============================================================
    // 主状态机
    // ============================================================
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            i2c_req   <= 1'b0;
            i2c_cmd   <= 2'd0;
            i2c_send  <= 8'd0;
            i2c_nack  <= 1'b0;
            scan_idx  <= 4'd0;
            ch        <= 4'd0;
            idle_cnt  <= 16'd0;
            cnv_cnt   <= 20'd0;
            rd_hi     <= 16'd0;
            raw_val   <= 16'd0;
            gate_prev <= 8'd0;
            vel_ch    <= 64'd0;
            vel_live  <= 8'd0;
            force_ch  <= 64'd0;
            data_ok   <= 1'b0;
            err_cnt   <= 8'd0;
            seen_ch   <= 8'd0;
            raw_ch    <= 64'd0;
            trx_err   <= 1'b0;
            wdt       <= 26'd0;
            cfg_ok    <= 1'b0;
            raw_f     <= 16'd0;
            capture   <= 8'd0;
            st_prev   <= S_IDLE;
            for (i = 0; i < 8; i = i + 1) peak_val[i] <= 16'd0;
        end else begin
            i2c_req <= 1'b0;              // 默认：请求线只拉高一个周期

            // ---- 关键：ack_err 是"每条命令"的，下一条命令开始时会被清零，
            // 而 STOP 命令根本没有 ACK 阶段。所以必须在每条命令完成时
            // 就把它并进本通道的 trx_err，绝不能等到 STOP 之后再读。
            // （注意：在 STOP 后读 ack_err 永远是 0，于是"I²C 不通"
            // 被误判成"通信正常"，读到 0xFFFF 当负数丢掉，
            // 力度恒为 0 -> 整台琴静音。）
            if (i2c_done)
                trx_err <= trx_err | i2c_ack_err;

            case (st)

            // ---- 空闲：等一会儿再巡检 ----
            // 有键按下 / 调试页强制扫描时不等待，立刻开始下一轮
            // （背靠背扫描，约 1.9ms 一个采样点）；
            // 没有键按下且不在调试页时才慢速巡检（省总线）。
            S_IDLE: begin
                scan_idx <= 4'd0;
                if (any_gated || force_scan_s || (idle_cnt >= IDLE_TICKS)) begin
                    idle_cnt <= 16'd0;
                    st       <= S_PICK;
                end else begin
                    idle_cnt <= idle_cnt + 16'd1;
                end
            end

            // ---- 挑通道 ----
            // 优先级：按下的键一定要读；调试页（force_scan）或无键时扫全部
            S_PICK: begin
                if (scan_idx >= 4'd8) begin
                    scan_idx <= 4'd0;
                    st       <= S_IDLE;
                end else begin
                    ch <= scan_idx;
                    // 先看该通道有没有接传感器（CH_MASK）。
                    // 没接的通道输入悬空，会采到噪声，表现为
                    // "别的键的柱子随机乱冒" -- 必须直接跳过。
                    if (!CH_MASK[scan_idx[2:0]]) begin
                        gate_prev[scan_idx[2:0]] <= 1'b0;
                        capture  [scan_idx[2:0]] <= 1'b0;
                        scan_idx <= scan_idx + 4'd1;
                    end else if (key_g[scan_idx[2:0]] || force_scan_s || !any_gated) begin
                        // 按下沿：开始新一轮采集
                        // 注意：这里不清 seen_ch--它是粘滞的，
                        // 一旦确认该通道装了传感器就一直有效。
                        if (key_g[scan_idx[2:0]] && !gate_prev[scan_idx[2:0]]) begin
                            // 按下沿：清峰值，并标记"这次按下必须采一次"。
                            // 力度先清 0，顶层 VEL_FLOOR 会把它钳到 20，
                            // 所以不会出现"按下瞬间 0 力度 = 没声"。
                            peak_val[scan_idx[2:0]] <= 16'd0;
                            capture [scan_idx[2:0]] <= 1'b1;
                            vel_ch  [scan_idx*8 +: 8] <= 8'd0;
                            force_ch[scan_idx*8 +: 8] <= 8'd0;
                        end
                        // 记录本通道的按键状态（用于下一轮找上升沿）
                        gate_prev[scan_idx[2:0]] <= key_g[scan_idx[2:0]];
                        trx_err <= 1'b0;          // 新的一次事务，清错误标志
                        // 连续转换模式：配置写过一次后，之后每轮只读结果
                        st <= cfg_ok ? S_RD_START : S_CFG_START;
                    end else begin
                        // 没按下的键，跳过不读（这是提速的关键）
                        gate_prev[scan_idx[2:0]] <= 1'b0;
                        capture  [scan_idx[2:0]] <= 1'b0;
                        scan_idx <= scan_idx + 4'd1;
                    end
                end
            end

            // ---- 写 Config 启动一次单次转换 ----
            S_CFG_START: begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd0;                     // START + 地址
                i2c_send <= {cur_addr, 1'b0};         // 写方向
                st       <= S_CFG_REG;
            end
            S_CFG_REG: if (i2c_done) begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd1;
                i2c_send <= 8'h01;                    // Config 寄存器
                st       <= S_CFG_HI;
            end
            S_CFG_HI: if (i2c_done) begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd1;
                i2c_send <= cfg_word[15:8];
                st       <= S_CFG_LO;
            end
            S_CFG_LO: if (i2c_done) begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd1;
                i2c_send <= cfg_word[7:0];
                st       <= S_CFG_STOP;
            end
            S_CFG_STOP: if (i2c_done) begin
                i2c_req <= 1'b1;
                i2c_cmd <= 2'd3;                      // STOP
                cnv_cnt <= 20'd0;
                st      <= S_WAIT_CNV;
                // 只有这次配置写没有 NAK 才算生效。
                // 原来无条件置 1 -- 如果上电瞬间写失败（模块还没准备好），
                // 就会一直用错误配置读，表现为"有时能用、有时读不到"。
                cfg_ok  <= ~trx_err;
            end

            // ---- 等转换完成 ----
            S_WAIT_CNV: begin
                if (cnv_cnt >= CNV_WAIT - 20'd1) begin
                    cnv_cnt <= 20'd0;
                    st      <= S_RD_START;
                end else begin
                    cnv_cnt <= cnv_cnt + 20'd1;
                end
            end

            // ---- 读 Conversion：完整 I²C 序列 ----
            // START+addr(W) -> WRITE 0x00 -> 重复 START+addr(R)
            // -> READ 高字节(ACK) -> READ 低字节(NACK) -> STOP
            //  "重复 START + 读地址"这一步不能省，否则读不到数据。
            S_RD_START: begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd0;
                i2c_send <= {cur_addr, 1'b0};
                st       <= S_RD_PTR;
            end
            S_RD_PTR: if (i2c_done) begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd1;
                i2c_send <= 8'h00;                    // Conversion 寄存器
                st       <= S_RD_RSTART;
            end
            S_RD_RSTART: if (i2c_done) begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd0;                     // 重复 START
                i2c_send <= {cur_addr, 1'b1};         // 读方向
                st       <= S_RD_B1;
            end
            S_RD_B1: if (i2c_done) begin
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd2;                     // READ 高字节
                i2c_nack <= 1'b0;                     // 后面还有 -> ACK
                st       <= S_RD_B2;
            end
            S_RD_B2: if (i2c_done) begin
                rd_hi    <= {8'd0, i2c_recv};         // 上面那次 READ 的高字节
                i2c_req  <= 1'b1;
                i2c_cmd  <= 2'd2;                     // READ 低字节
                i2c_nack <= 1'b1;                     // 最后一个 -> NACK
                st       <= S_RD_STOP;
            end
            S_RD_STOP: if (i2c_done) begin
                raw_val <= {rd_hi[7:0], i2c_recv};    // 拼成 16 位
                i2c_req <= 1'b1;
                i2c_cmd <= 2'd3;                      // STOP
                st      <= S_STORE;
            end

            // ---- 处理结果 ----
            S_STORE: if (i2c_done) begin
                // 用 trx_err（本次事务累计的 NACK），不能用 i2c_ack_err
                // （那是"最后一条命令"的，而最后一条是 STOP，永远为 0）
                if (trx_err) begin
                    err_cnt <= err_cnt + 8'd1;        // 无应答：接线/地址/上拉问题
                    // 自愈：任何一次通信失败都让配置失效，
                    // 下一轮会重新写配置（连续转换模式要重新启动）。
                    cfg_ok  <= 1'b0;
                    // 注意：capture 不清 -- 这次按下还没采到，下一轮继续试
                end else begin
                    data_ok <= 1'b1;
                    // 实时力度：每次成功读到都更新（不看按键状态）
                    // 单传感器模式下顶层把它给所有键用，声音就能一直跟着传感器。
                    vel_live <= raw_val[15] ? 8'd0 : map_vel(raw_val);
                    // ---- 调试：不管按键状态，都记录最新一次读数 ----
                    // 直接输出高字节，不做负值钳位：
                    // 0x00 -> 0 （总线被拉低 / 从机回 0）
                    // 0xFF -> 255 （总线一直高 = 从机根本没驱动 SDA）
                    // 这样 0 和 255 能区分开，不会都显示成 0
                    raw_ch[ch*8 +: 8] <= raw_f[15:8];   // 用滤波后的值
                    // 非对称滤波：上升不滤波（保证峰值 255 能立刻采到），
                    // 下降按 1/2^FILT_SHIFT 衰减（柱子回落平滑，不抖动）。
                    // 原来固定 1/8，调试时回落要 30~60ms，看起来"反应慢"；
                    // 改成参数后默认 1/2，回落 ≈10ms，跟手很多。
                    if (raw_val > raw_f)
                        raw_f <= raw_val;                                  // 上升：立即跟上
                    else
                        raw_f <= raw_f - (raw_f >> FILT_SHIFT)
                                       + (raw_val >> FILT_SHIFT);          // 下降：快速回落
                    // 16 位补码：单端输入在量程内为正，超量程/接反为负
                    if (!raw_val[15]) begin
                        // 只要读到超过死区的值，就认定该通道装了传感器。
                        // 粘滞标志，供顶层决定"用测试力度"还是"退回固定力度"。
                        if (raw_val > FORCE_MIN)
                            seen_ch[ch[2:0]] <= 1'b1;

                        // key_g 仍高：正常按住期间的峰值；
                        // capture=1：这次采样是"按下沿"发起的那一次，
                        // 即使读回时已经松手，也算数（快速轻点不会漏）。
                        if (key_g[ch[2:0]] || capture[ch[2:0]]) begin
                            // 峰值保持（存完整 16 位）
                            if (raw_val > peak_val[ch[2:0]]) begin
                                peak_val[ch[2:0]] <= raw_val;
                                vel_ch  [ch*8 +: 8] <= map_vel(raw_val);
                                force_ch[ch*8 +: 8] <= raw_val[15:8];
                            end
                        end
                    end
                    // 这次按下要求的采样已经完成（成功或数值无效都算完成）
                    capture[ch[2:0]] <= 1'b0;
                end
                scan_idx <= scan_idx + 4'd1;          // 推进到下一个通道
                st       <= S_PICK;
            end

            default: st <= S_IDLE;
            endcase

            // ------------------------------------------------------
            // 看门狗：防止状态机永久卡死
            // ------------------------------------------------------
            // 问题现象："用着用着就再也检测不到了"。
            // 原因可能是某次 I²C 事务没有返回 done（从机拉低 SCL 做了
            // 时钟延展、或总线被干扰），FSM 就永远停在等待里。
            // 这里加一个超时：状态连续 60ms 没变化就强制回 IDLE，
            // 并把这次记为一次错误。
            if (st != st_prev) begin
                wdt <= 26'd0;
            end else if (!(&wdt)) begin
                wdt <= wdt + 26'd1;
                if (wdt >= 26'd3_000_000) begin        // 50MHz 下 60ms
                    st      <= S_IDLE;
                    err_cnt <= err_cnt + 8'd1;
                    // 总线可能被卡过，配置状态不可信，强制重来
                    cfg_ok  <= 1'b0;
                end
            end
            st_prev <= st;
        end
    end

endmodule