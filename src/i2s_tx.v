// ============================================================
// PT8211 音频 DAC 串行发送器
// 接板载 U16 = PT8211-S（立体声 DAC）-> LPF -> NS4263 功放 -> 耳机/扬声器
//
//  PT8211 不是标准 Philips I2S。三个关键差异（照 datasheet 和
// Sipeed/社区参考实现核对过）：
//
// 1) 声道极性相反：
// WS = 高 -> 左声道
// WS = 低 -> 右声道
// （标准 I2S 是低=左，正好相反）
//
// 2) 没有 I2S 的"1 个 BCK 延迟"：
// MSB 就在 WS 边沿那一拍出现（LSB-justified / "Japanese" 格式）。
// 每声道正好 16 个 BCK，所以 LSBJ 和 left-justified 在这里重合，
// 不存在偏移问题。
//
// 3) 数据格式：二进制补码、MSB 先出、每帧 32 个 BCK（每声道 16 位）
//
// 时序做法（本模块的核心）：
// BCK 下降沿 -> 更新 WS 和 DIN（给 DAC 留半个周期建立时间）
// BCK 上升沿 -> DAC 在这里采样 DIN/WS
// 如果像"图省事"那样在上升沿才改数据，建立时间就是 0，能否工作
// 取决于布线先后 -- 所以必须在下降沿呈现数据。
//
// 时钟：所有逻辑都在 50MHz 单一时钟域内，不生成内部 BCK 再跨域。
// BCK 周期 = 32 个 clk -> BCK = 1.5625 MHz
// 一帧 = 32 个 BCK -> 采样率 = 48828.125 Hz
// ============================================================
module i2s_tx (
    input  wire               clk,        // 50MHz 系统时钟
    input  wire               rst_n,
    input  wire signed [15:0] pcm_in,     // 要播放的 PCM（单声道，左右都放它）
    output reg                bck,        // -> HP_BCK (Y17)
    output reg                ws,         // -> HP_WS (AB17)
    output reg                din         // -> HP_DIN (AA16)
);

    localparam DIV  = 32;      // 每个 BCK 周期的 clk 数
    localparam HALF = 16;      // 其中 BCK 为低的 clk 数

    reg [5:0]  div;        // 0..DIV-1
    reg [4:0]  slot;       // 0..31：帧内 BCK 序号
    reg [15:0] shift;      // 移位寄存器
    reg signed [15:0] lat; // 本帧锁存的 PCM

    wire [4:0] slot_n = slot + 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div   <= 6'd0;
            slot  <= 5'd31;         // 让第一个下降沿正好从 slot 0 开始
            bck   <= 1'b0;
            ws    <= 1'b1;
            din   <= 1'b0;
            shift <= 16'd0;
            lat   <= 16'sd0;
        end else if (div == DIV - 1) begin
            // ---------- BCK 下降沿：更新 DIN / WS ----------
            div  <= 6'd0;
            bck  <= 1'b0;
            slot <= slot_n;

            if (slot_n == 5'd31)
                lat <= pcm_in;                  // 帧尾预取下一帧数据
                                                    // （混音结果在 1024 个 clk 内稳定，准静态跨域安全）

            if (slot_n == 5'd0) begin
                // 左声道开始：WS 拉高，送出左声道 MSB
                din   <= lat[15];
                shift <= {lat[14:0], 1'b0};
                ws    <= 1'b1;                  // PT8211: 高 = 左
            end else if (slot_n == 5'd16) begin
                // 右声道开始：WS 拉低，送出右声道 MSB
                din   <= lat[15];
                shift <= {lat[14:0], 1'b0};
                ws    <= 1'b0;                  // PT8211: 低 = 右
            end else begin
                din   <= shift[15];
                shift <= {shift[14:0], 1'b0};
            end

        end else begin
            div <= div + 1'b1;

            // ---------- BCK 上升沿：DAC 在这里采样 DIN / WS ----------
            if (div == HALF - 1)
                bck <= 1'b1;
        end
    end

endmodule
