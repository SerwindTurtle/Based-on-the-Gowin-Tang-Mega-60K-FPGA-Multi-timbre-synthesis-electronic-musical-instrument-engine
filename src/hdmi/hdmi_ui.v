// ============================================================
// hdmi_ui.v -- 把原 1024x600 界面居中画进 1280x720 HDMI 画面
// （方案 A：letterbox，四周留黑边）
//
// 时钟选择：75 MHz 像素 / 375 MHz 位时钟（VCO 750, ODIV 10/2）
// 不采用 150MHz 1080p60 的原因：
// lcd_draw 是很大一块组合逻辑，测试关键路径约 14ns。
// 150MHz 周期 6.67ns 根本不够；75MHz 周期 13.33ns 才勉强能过。
// 75MHz + 1650x750 时序 = 60.6Hz，是标准的 720p60，显示器都认。
//
// PLL 用自己写的 pll_simple（PLLA，不带 PLL_INIT / mDRP）
// 注意：IP 生成器默认开 mDRP，生成出的 PLL_INIT 状态机会用
// O_RST 把 PLLA 摁在复位里，同时又在等 I_LOCK -- 死锁，
// 表现为 pll_lock 永不置位、clk_px 完全不跳变、HDMI 无信号。
// 官方例程的 PLL 是把 RESET 直接接 GND、不带 PLL_INIT 的。
//
// 画面布局（1280x720）：
// X 方向：黑边 128 + UI 1024 + 黑边 128 = 1280
// Y 方向：黑边 60 + UI 600 + 黑边 60 = 720
// ============================================================
`timescale 1ns / 1ps

module hdmi_ui #(
    parameter NUM_VOICES   = 32,
    parameter BUF_AW       = 10,
    parameter DISP_W       = 800,
    parameter KBD_NOTE_LO  = 60,
    parameter KBD_REVERSE  = 1'b0,
    parameter TOP_H        = 134
) (
    input  wire        clk_50m,
    input  wire        rst_n,

    // ---- 界面要显示的数据（和 LCD 版本完全一样）----
    input  wire signed [15:0] buf_data,     // 波形缓冲读数据（第二读口）
    input  wire [BUF_AW-1:0]  wr_ptr,       // 写指针（adc_clk 域）
    input  wire [NUM_VOICES-1:0] v_gate,
    input  wire [7:0]          kbd_gate,
    input  wire [63:0]         dbg_force,   // 8 路压力原始读数
    input  wire [5:0]          active_cnt,  // 复音数
    input  wire [5:0]          peak_cnt,

    // ---- 压力调试界面相关 ----
    input  wire        page,        // 0 = 正常界面，1 = 压力调试界面（KEY0 长按切换）
    input  wire        ads_ok,      // I²C 是否通
    input  wire [7:0]  ads_err,     // I²C 错误计数
    input  wire [7:0]  ads_seen,    // 每通道"读到过压力"标志
    input  wire [31:0] spec_bus,    // 4 段频谱（真实音频，显示成 8 条）

    // ---- 波形缓冲读地址（送给 scope_capture 的第二读口）----
    output wire [BUF_AW-1:0]  buf_addr,

    // ---- HDMI TMDS 输出（DVI TX IP 的 P/N 双端口）----
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,

    // ---- 诊断输出（接 LED）----
    output wire        dbg_lock,
    output wire        dbg_rstn,
    output wire        dbg_blink
);

    // 画面常量
    // 从 1080p30 改成 720p60。
    // 75MHz 像素时钟下 1080p 只能 30Hz（一帧 33ms），压力条看起来"一格一格"；
    // 720p60 刷新翻倍到 ~60.6Hz，跟手很多。
    // UI 仍然是 1024×600 像素（不缩放），只是四周黑边从 448/240 变成 128/60。
    localparam H_ACTIVE = 1280;
    localparam V_ACTIVE = 720;
    localparam UI_W     = 1024;
    localparam UI_H     = 600;
    localparam UI_X0    = (H_ACTIVE - UI_W) / 2;   // 128
    localparam UI_Y0    = (V_ACTIVE - UI_H) / 2;   // 60

    // ============================================================
    // PLL：50MHz -> 75MHz（像素） + 375MHz（位时钟 = 5x）
    // ============================================================
    wire clk_px, clk_px5, pll_lock;

    pll_simple u_pll (
        .clkin   (clk_50m),
        .clkout0 (clk_px),          // 75 MHz 像素时钟
        .clkout1 (clk_px5),         // 375 MHz 位时钟
        .lock    (pll_lock)
    );

    // 复位：固定延时释放，不依赖 pll_lock（避免 lock 异常时死等）
    reg [20:0] rst_cnt = 21'd0;
    always @(posedge clk_px) begin
        if (!rst_n)           rst_cnt <= 21'd0;
        else if (!(&rst_cnt)) rst_cnt <= rst_cnt + 21'd1;
    end
    wire px_rst  = ~(&rst_cnt);       // 1 = 复位中
    wire px_rstn = &rst_cnt;

    // ============================================================
    // 720p 视频时序
    // ============================================================
    wire [13:0] px_x, px_y;
    wire        v_de, v_hsync, v_vsync;

    hdmi_timing #(
        // 720p60 标准时序：75MHz / (1650×750) ≈ 60.6Hz
        // H: hsync 40 + hbp 220 + visible 1280 + hfp 110 = 1650
        // V: vsync 5 + vbp 20 + visible 720 + vfp 5 = 750
        .video_hlength   (1650),
        .video_vlength   (750),
        .video_hsync_pol (1),
        .video_hsync_len (40),
        .video_hbp_len   (220),
        .video_h_visible (H_ACTIVE),
        .video_vsync_pol (1),
        .video_vsync_len (5),
        .video_vbp_len   (20),
        .video_v_visible (V_ACTIVE)
    ) u_timing (
        .pixel_clock     (clk_px),
        .reset           (px_rst),
        .ext_sync        (1'b0),
        .timing_h_pos    (),
        .timing_v_pos    (),
        .pixel_x         (px_x),
        .pixel_y         (px_y),
        .video_vsync     (v_vsync),
        .video_hsync     (v_hsync),
        .video_den       (v_de),
        .video_line_start()
    );

    // ============================================================
    // letterbox：UI 居中
    // ============================================================
    wire in_ui = v_de &&
                 (px_x >= UI_X0) && (px_x < UI_X0 + UI_W) &&
                 (px_y >= UI_Y0) && (px_y < UI_Y0 + UI_H);

    wire [13:0] ui_x = in_ui ? (px_x - UI_X0) : 14'd0;
    wire [13:0] ui_y = in_ui ? (px_y - UI_Y0) : 14'd0;

    // 流水 1：把 letterbox 的坐标/使能打一拍，切断
    // "v_pos -> 坐标比较 -> lcd_draw 组合逻辑 -> rgb" 这条 15.5ns 的长路径
    // （75MHz 要求 14.9ns，原来差 0.58ns）
    reg [11:0] uix_r, uiy_r;
    reg        inui_r;
    always @(posedge clk_px) begin
        if (px_rst) begin
            uix_r  <= 12'd0;
            uiy_r  <= 12'd0;
            inui_r <= 1'b0;
        end else begin
            uix_r  <= ui_x[11:0];
            uiy_r  <= ui_y[11:0];
            inui_r <= in_ui;
        end
    end

    // ============================================================
    // 写指针跨时钟域锁存：每帧锁一次
    // ============================================================
    reg [BUF_AW-1:0] wr_ptr_lat;
    wire             frame_start = (px_x == 14'd0) && (px_y == 14'd0);
    always @(posedge clk_px) begin
        if (px_rst)           wr_ptr_lat <= {BUF_AW{1'b0}};
        else if (frame_start) wr_ptr_lat <= wr_ptr;
    end

    // ============================================================
    // 压力读数跨时钟域：两级同步（来自 sys_clk 50MHz 域）
    // ============================================================
    reg [63:0] dbg_s1, dbg_s2;
    always @(posedge clk_px) begin
        if (px_rst) begin
            dbg_s1 <= 64'd0;
            dbg_s2 <= 64'd0;
        end else begin
            dbg_s1 <= dbg_force;
            dbg_s2 <= dbg_s1;
        end
    end
    wire [63:0] dbg_force_sync = dbg_s2;

    // 频谱跨时钟域：两级同步 + 每帧锁存
    reg [31:0] spec_s1, spec_s2, spec_lat;
    always @(posedge clk_px) begin
        if (px_rst) begin
            spec_s1 <= 32'd0; spec_s2 <= 32'd0; spec_lat <= 32'd0;
        end else begin
            spec_s1 <= spec_bus;
            spec_s2 <= spec_s1;
            if (frame_start) spec_lat <= spec_s2;
        end
    end

    // ============================================================
    // 原来的界面绘制模块（参数和 LCD 版完全一致）
    // ============================================================
    wire [17:0] ui_rgb;      // RGB666
    wire        ui_de;

    lcd_draw #(
        .H_ACTIVE   (UI_W),
        .V_ACTIVE   (UI_H),
        .BUF_AW     (BUF_AW),
        .DISP_W     (DISP_W),
        .NUM_VOICES (NUM_VOICES),
        .AMP_SHIFT  (8),
        .TOP_H      (TOP_H),
        .ROTATE     (0),
        .MIRROR_X   (1'b0),
        .MIRROR_Y   (1'b0),
        .KBD_N      (8),
        .KBD_NOTE_LO(KBD_NOTE_LO),
        .KBD_REVERSE(KBD_REVERSE)
    ) u_lcd_draw (
        .pclk       (clk_px),
        .rst_n      (rst_n),
        .x          (uix_r),
        .y          (uiy_r),
        .de         (inui_r),
        .buf_addr   (buf_addr),
        .buf_data   (buf_data),
        .wr_ptr     (wr_ptr_lat),
        .v_gate     (v_gate),
        .active_cnt (active_cnt),
        .peak_cnt   (peak_cnt),
        .kbd_gate   (kbd_gate),
        .dbg_force  (dbg_force_sync),
        .rgb        (ui_rgb),
        .de_out     (ui_de)
    );

    // ============================================================
    // 压力调试界面（和正常界面并行绘制，按 page 二选一）
    // ============================================================
    // page 来自 adc_clk 域，先做两级同步
    reg page_s1, page_s2;
    always @(posedge clk_px) begin
        if (px_rst) begin
            page_s1 <= 1'b0;
            page_s2 <= 1'b0;
        end else begin
            page_s1 <= page;
            page_s2 <= page_s1;
        end
    end
    wire page_sync = page_s2;

    wire [17:0] dbg_rgb;
    wire        dbg_de;

    dbg_force_draw u_dbg (
        .pclk     (clk_px),
        .rst_n    (rst_n),
        .x        (uix_r),
        .y        (uiy_r),
        .de       (inui_r),
        .force_ch (dbg_force_sync),
        .i2c_ok   (ads_ok),
        .i2c_err  (ads_err),
        .seen     (ads_seen),
        .rgb      (dbg_rgb),
        .de_out   (dbg_de)
    );

    // 二选一：page_sync=1 时输出调试界面
    // 调试页再打一拍：它的字模查表 + 条形计算路径较长，
    // 多加一级流水后 75MHz 才过。静态文字偏 1 像素肉眼看不出。
    reg [17:0] dbg_rgb2;
    reg        dbg_de2;
    always @(posedge clk_px) begin
        if (px_rst) begin
            dbg_rgb2 <= 18'd0;
            dbg_de2  <= 1'b0;
        end else begin
            dbg_rgb2 <= dbg_rgb;
            dbg_de2  <= dbg_de;
        end
    end

    // ---- 频谱条：覆盖波形区顶部约 80px，相当于压缩波形空间 ----
    localparam [13:0] SPEC_Y0   = 14'd140;
    localparam [13:0] SPEC_H    = 14'd78;
    localparam [13:0] SPEC_BASE = SPEC_Y0 + SPEC_H;   // 218
    wire spec_area = inui_r && (uiy_r >= SPEC_Y0[11:0]) && (uiy_r < SPEC_BASE[11:0]);
    wire [2:0] spec_idx = uix_r[9:7];                 // 8 条
    wire [1:0] spec_band = spec_idx[2:1];             // 4 段，每段显示两条
    wire [7:0] spec_lv  = spec_lat[{spec_band, 3'b000} +: 8];
    wire [7:0] spec_h   = spec_lv;                    // 0..127，不做比较器，避免 HDMI 关键路径
    wire spec_bar = spec_area && (uiy_r >= (SPEC_BASE[11:0] - spec_h));
    wire [17:0] spec_rgb = spec_area
                         ? (spec_bar ? {6'd4, 6'd60, 6'd28} : {6'd1, 6'd4, 6'd8})
                         : ui_rgb;

    wire [17:0] act_rgb = page_sync ? dbg_rgb2 : spec_rgb;
    wire        act_de  = page_sync ? dbg_de2  : ui_de;

    // ============================================================
    // RGB666 -> RGB888，并与 hsync/vsync 对齐
    // ============================================================
    wire [23:0] ui_rgb24 = { act_rgb[17:12], act_rgb[17:16],
                             act_rgb[11:6],  act_rgb[11:10],
                             act_rgb[5:0],   act_rgb[5:4]  };

    // lcd_draw 的输出是寄存的（比 x/y 晚 1 拍），hsync/vsync 也延 1 拍对齐
    reg hs_d, vs_d, de_d;
    reg hs_d2, vs_d2, de_d2;
    always @(posedge clk_px) begin
        if (px_rst) begin
            hs_d <= 1'b0;
            vs_d <= 1'b0;
            de_d <= 1'b0;
        end else begin
            hs_d <= v_hsync;
            vs_d <= v_vsync;
            de_d <= v_de;          // 整帧有效区（1280x720），不是 UI 区域
        end
    end

    // 再延一拍：lcd_draw 的输入已经寄存过一拍，输出还要一拍，共 2 拍
    always @(posedge clk_px) begin
        if (px_rst) begin
            hs_d2 <= 1'b0;
            vs_d2 <= 1'b0;
            de_d2 <= 1'b0;
        end else begin
            hs_d2 <= hs_d;
            vs_d2 <= vs_d;
            de_d2 <= de_d;
        end
    end

    // UI 区外送黑（黑边）
    wire [23:0] pix = act_de ? ui_rgb24 : 24'h000000;

    // ============================================================
    // TMDS 发送：官方 DVI_TX IP（TLVDS 真差分）
    // ============================================================
    DVI_TX_Top u_dvi_tx (
        .I_rst_n       (px_rstn),
        .I_serial_clk  (clk_px5),        // 375 MHz = 5 x 像素时钟
        .I_rgb_clk     (clk_px),         // 75 MHz 像素时钟
        .I_rgb_vs      (vs_d2),
        .I_rgb_hs      (hs_d2),
        //  这里必须用整帧有效区 de_d，不能用 ui_de（UI 区域）
        // 之前用 ui_de，显示器按 DE 数出来的有效区就是 1024x600，
        // 于是 OSD 显示 1024x600@30Hz/60Hz，黑边也不是黑边而是"消隐"。
        // 黑边应该是有效区里的黑色像素，所以 DE 要铺满整帧。
        .I_rgb_de      (de_d2),
        .I_rgb_r       (pix[23:16]),
        .I_rgb_g       (pix[15:8]),
        .I_rgb_b       (pix[7:0]),
        .O_tmds_clk_p  (tmds_clk_p),
        .O_tmds_clk_n  (tmds_clk_n),
        .O_tmds_data_p (tmds_data_p),
        .O_tmds_data_n (tmds_data_n)
    );

    // ============================================================
    // 诊断
    // ============================================================
    assign dbg_lock = pll_lock;
    assign dbg_rstn = px_rstn;

    reg [24:0] blink_cnt;
    always @(posedge clk_px) blink_cnt <= blink_cnt + 25'd1;
    assign dbg_blink = blink_cnt[24];

endmodule
