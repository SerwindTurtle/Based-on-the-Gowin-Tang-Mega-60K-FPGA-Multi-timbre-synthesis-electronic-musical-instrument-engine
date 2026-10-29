// ============================================================
// 音频波形采集：把混音后的 PCM 存进环形缓冲，供屏幕逐像素读取
//
// 不采用帧缓存的原因：
// GW5AT-60 的 BSRAM 总共只有约 265KB，
// 而 1024x600 RGB565 整帧 = 1.2MB，放不下。
// 所以屏幕必须"逐像素实时生成"，波形只需要一小块采样缓冲。
//
// 采用同步读的原因：
// 组合读写法： assign rd_data = mem[rd_addr];
// BSRAM 做不了组合读，综合器只能把整个数组铺成寄存器：
// BUF_AW=10 -> 1024×16 ≈ 1.0 万个寄存器（占全设计寄存器的 98%）
// BUF_AW=12 -> 4096×16 ≈ 3.3 万个寄存器
// 测试后果：器件被塞满 -> 布局失败
// ERROR (PR0003) : Failed to place with '533 REG(s) unPlaced'
// 或者布局布线长时间跑不出来 / 被系统杀掉。
//
// 改成"寄存读地址 + 打一拍输出"之后，综合器就能推断成 BSRAM
// （配 top 里综合选项 -ram_style block_ram 更保险），
// 4096×16 只占几个 BSRAM 块，寄存器几乎归零。
//
//  代价：rd_data 比 rd_addr 晚一拍出来。绘制侧已经按这个做了地址
// 提前一拍的处理（lcd_draw 里有对应的说明），波形只会整体平移
// 1 个像素，肉眼无感。
//
// 读地址换算（把最新采样对齐到屏幕最右边）：
// 设显示宽度 W，最右列 x=W-1 要显示最新采样
// rd_addr = (wr_ptr + x - W) mod 2^BUF_AW
// 因为 2^BUF_AW 是 2 的幂，减 W 等于加 (2^BUF_AW - W)，直接加法+掩码
// （这部分换算在 lcd_draw 里做，本模块只提供读写口）
// ============================================================
module scope_capture #(
    parameter BUF_AW = 10           // 缓冲地址位宽（2^BUF_AW 个采样）
) (
    input  wire               clk,
    input  wire               rst_n,
    // ---- 来自 mixer_limiter 的音频 ----
    input  wire               sample_valid,   // 采样率使能（48828Hz）
    input  wire signed [15:0] sample_in,      // 混音后的 PCM
    // ---- 读端口 1（LCD 绘制用）----
    input  wire [BUF_AW-1:0]  rd_addr,        // 读地址（由绘制逻辑算好）
    output reg  signed [15:0] rd_data,        // 读出的采样（同步读，慢 1 拍）
    // ---- 读端口 2（HDMI 绘制用）----
    // 使用双端口的原因：
    // LCD 和 HDMI 各有一个绘制实例，都要读波形缓冲。
    // BSRAM 一个块只有一个读口，两个实例抢地址会互相踩。
    // 这里内部复制一份存储做第二端口 -- 多占 1 个 BSRAM 块
    // （1024x16 的一个块就够），比改成真双口 BSRAM 简单可靠得多。
    input  wire [BUF_AW-1:0]  rd_addr2,
    output reg  signed [15:0] rd_data2,
    // ---- 写指针（绘制逻辑用它算基址）----
    output wire [BUF_AW-1:0]  wr_ptr
);

    //  不能叫 buf -- buf 是 Verilog 门原语关键字，综合器会报
    // "Verilog 2001 keyword 'buf' used in incorrect context"
    reg signed [15:0] mem  [0:(1<<BUF_AW)-1];
    reg signed [15:0] mem2 [0:(1<<BUF_AW)-1];   // 第二份存储（供读端口 2）
    reg [BUF_AW-1:0]  wp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= {BUF_AW{1'b0}};
            // mem 不复位：BSRAM 不支持整块异步复位，综合器会忽略
        end else if (sample_valid) begin
            mem [wp] <= sample_in;
            mem2[wp] <= sample_in;      // 两份同步写
            wp       <= wp + 1'b1;
        end
    end

    // 同步读：地址先寄存一拍，再取数据 -> 综合器可推断成 BSRAM
    // （这两步合起来就是标准的"同步读 BSRAM"模板）
    reg [BUF_AW-1:0] rd_addr_r;
    reg [BUF_AW-1:0] rd_addr_r2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_r <= {BUF_AW{1'b0}};
            rd_data   <= 16'sd0;
        end else begin
            rd_addr_r <= rd_addr;              // 地址打一拍
            rd_data   <= mem[rd_addr_r];       // 用寄存后的地址读 -> BSRAM
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_r2 <= {BUF_AW{1'b0}};
            rd_data2   <= 16'sd0;
        end else begin
            rd_addr_r2 <= rd_addr2;
            rd_data2   <= mem2[rd_addr_r2];
        end
    end

    assign wr_ptr = wp;

endmodule
