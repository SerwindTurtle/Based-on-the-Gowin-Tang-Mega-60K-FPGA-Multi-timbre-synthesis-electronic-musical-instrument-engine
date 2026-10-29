// ============================================================
// pll_simple.v -- 干净的 PLLA 封装（不用 PLL_INIT / mDRP）
//
// 为什么自己写这个
// IP 生成器默认勾了 mDRP，于是 Gowin_PLL 里多出一个 PLL_INIT
// 状态机，它会在上电后通过 mDRP 口动态重配置PLL，
// 并且用 PLL_INIT 的 O_RST 去复位 PLLA。
// 测试结果：pll_lock 一直不置位，clk_px 完全没有跳变
// （用 LED 诊断确认：R17/P16/U21 三个灯全灭）。
//
// 对照 Sipeed 官方 hdmi_colorbar 例程的 Gowin_PLL：
// module Gowin_PLL (lock, clkout0, clkout1, clkin);
// .RESET(gw_gnd) <- RESET 直接接地
// 没有 mdclk，也没有 PLL_INIT
// 也就是说：官方根本不用 mDRP 那套，PLL 靠静态 defparam 工作。
//
// 所以这里照官方的拓扑重写：RESET 接 0、mDRP 口全部接 0、
// 不加 PLL_INIT，lock 直接从 PLLA 输出。
//
// 频率：
// VCO = CLKIN / IDIV x MDIV = 50 / 1 x 30 = 1500 MHz
// clkout0 = VCO / ODIV0 = 1500 / 10 = 150 MHz <- 像素时钟
// clkout1 = VCO / ODIV1 = 1500 / 2 = 750 MHz <- 位时钟（= 5 x 像素）
//
// 150MHz + 2200x1125 时序 => 60.6Hz，正好对上出厂 demo 的 1080p61Hz。
//
//  为什么不用 VCO=750 / ODIV1=1：
// IP 生成器按 150/750 算出了 VCO=750 + ODIV1=1（分频比 1 = 直通），
// 分频比 1 通常不被支持，PLL 会锁不住。官方例程用的是 VCO=1500 + 10/2。
// ============================================================
`timescale 1ns / 1ps

module pll_simple (
    input  wire clkin,
    output wire clkout0,    // 150 MHz 像素时钟
    output wire clkout1,    // 750 MHz 位时钟
    output wire lock
);

    wire gw_gnd = 1'b0;

    // MDRDO 是 PLLA 的输出口（mDRP 读数据），必须接 wire，不能接常量。
    // 我们不用 mDRP，所以让它悬空即可。
    wire [7:0] mdrdo_unused;

    PLLA PLLA_inst (
        .LOCK      (lock),
        .CLKOUT0   (clkout0),
        .CLKOUT1   (clkout1),
        .CLKOUT2   (),
        .CLKOUT3   (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .CLKFBOUT  (),
        .MDRDO     (mdrdo_unused),
        .CLKIN     (clkin),
        .CLKFB     (gw_gnd),
        .RESET     (gw_gnd),      // <- 关键：复位直接接地（官方做法）
        .PLLPWD    (gw_gnd),
        .RESET_I   (gw_gnd),
        .RESET_O   (gw_gnd),
        .PSSEL     (3'b000),
        .PSDIR     (gw_gnd),
        .PSPULSE   (gw_gnd),
        .SSCPOL    (gw_gnd),
        .SSCON     (gw_gnd),
        .SSCMDSEL  (7'b0000000),
        .SSCMDSEL_FRAC(3'b000),
        .MDCLK     (gw_gnd),      // mDRP 全部不使用
        .MDOPC     (2'b00),
        .MDAINC    (gw_gnd),
        .MDWDI     (8'h00)
    );

    defparam PLLA_inst.FCLKIN          = "50";
    defparam PLLA_inst.IDIV_SEL        = 1;
    defparam PLLA_inst.FBDIV_SEL       = 1;
    defparam PLLA_inst.ODIV0_SEL       = 10;
    defparam PLLA_inst.ODIV1_SEL       = 2;
    defparam PLLA_inst.ODIV2_SEL       = 8;
    defparam PLLA_inst.ODIV3_SEL       = 8;
    defparam PLLA_inst.ODIV4_SEL       = 8;
    defparam PLLA_inst.ODIV5_SEL       = 8;
    defparam PLLA_inst.ODIV6_SEL       = 8;
    defparam PLLA_inst.MDIV_SEL        = 15;
    defparam PLLA_inst.MDIV_FRAC_SEL   = 0;
    defparam PLLA_inst.ODIV0_FRAC_SEL  = 0;
    defparam PLLA_inst.CLKOUT0_EN      = "TRUE";
    defparam PLLA_inst.CLKOUT1_EN      = "TRUE";
    defparam PLLA_inst.CLKOUT2_EN      = "FALSE";
    defparam PLLA_inst.CLKOUT3_EN      = "FALSE";
    defparam PLLA_inst.CLKOUT4_EN      = "FALSE";
    defparam PLLA_inst.CLKOUT5_EN      = "FALSE";
    defparam PLLA_inst.CLKOUT6_EN      = "FALSE";
    defparam PLLA_inst.CLKFB_SEL       = "INTERNAL";
    defparam PLLA_inst.CLKOUT0_DT_DIR  = 1'b1;
    defparam PLLA_inst.CLKOUT1_DT_DIR  = 1'b1;
    defparam PLLA_inst.CLKOUT2_DT_DIR  = 1'b1;
    defparam PLLA_inst.CLKOUT3_DT_DIR  = 1'b1;
    defparam PLLA_inst.CLKOUT0_DT_STEP = 0;
    defparam PLLA_inst.CLKOUT1_DT_STEP = 0;
    defparam PLLA_inst.CLKOUT2_DT_STEP = 0;
    defparam PLLA_inst.CLKOUT3_DT_STEP = 0;
    defparam PLLA_inst.CLK0_IN_SEL     = 1'b0;
    defparam PLLA_inst.CLK0_OUT_SEL    = 1'b0;
    defparam PLLA_inst.CLK1_IN_SEL     = 1'b0;
    defparam PLLA_inst.CLK1_OUT_SEL    = 1'b0;
    defparam PLLA_inst.CLK2_IN_SEL     = 1'b0;
    defparam PLLA_inst.CLK2_OUT_SEL    = 1'b0;
    defparam PLLA_inst.CLK3_IN_SEL     = 1'b0;
    defparam PLLA_inst.CLK3_OUT_SEL    = 1'b0;
    defparam PLLA_inst.CLK4_IN_SEL     = 2'b00;
    defparam PLLA_inst.CLK4_OUT_SEL    = 1'b0;
    defparam PLLA_inst.CLK5_IN_SEL     = 1'b0;
    defparam PLLA_inst.CLK5_OUT_SEL    = 1'b0;
    defparam PLLA_inst.CLK6_IN_SEL     = 1'b0;
    defparam PLLA_inst.CLK6_OUT_SEL    = 1'b0;
    defparam PLLA_inst.DYN_DPA_EN      = "FALSE";
    defparam PLLA_inst.CLKOUT0_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT0_PE_FINE   = 0;
    defparam PLLA_inst.CLKOUT1_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT1_PE_FINE   = 0;
    defparam PLLA_inst.CLKOUT2_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT2_PE_FINE   = 0;
    defparam PLLA_inst.CLKOUT3_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT3_PE_FINE   = 0;
    defparam PLLA_inst.CLKOUT4_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT4_PE_FINE   = 0;
    defparam PLLA_inst.CLKOUT5_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT5_PE_FINE   = 0;
    defparam PLLA_inst.CLKOUT6_PE_COARSE = 0;
    defparam PLLA_inst.CLKOUT6_PE_FINE   = 0;
    defparam PLLA_inst.DYN_PE0_SEL     = "FALSE";
    defparam PLLA_inst.DYN_PE1_SEL     = "FALSE";
    defparam PLLA_inst.DYN_PE2_SEL     = "FALSE";
    defparam PLLA_inst.DYN_PE3_SEL     = "FALSE";
    defparam PLLA_inst.DYN_PE4_SEL     = "FALSE";
    defparam PLLA_inst.DYN_PE5_SEL     = "FALSE";
    defparam PLLA_inst.DYN_PE6_SEL     = "FALSE";
    defparam PLLA_inst.DE0_EN          = "FALSE";
    defparam PLLA_inst.DE1_EN          = "FALSE";
    defparam PLLA_inst.DE2_EN          = "FALSE";
    defparam PLLA_inst.DE3_EN          = "FALSE";
    defparam PLLA_inst.DE4_EN          = "FALSE";
    defparam PLLA_inst.DE5_EN          = "FALSE";
    defparam PLLA_inst.DE6_EN          = "FALSE";
    defparam PLLA_inst.RESET_I_EN      = "FALSE";
    defparam PLLA_inst.RESET_O_EN      = "FALSE";
    defparam PLLA_inst.ICP_SEL         = 6'bXXXXXX;
    defparam PLLA_inst.LPF_RES         = 3'bXXX;
    defparam PLLA_inst.LPF_CAP         = 2'b00;
    defparam PLLA_inst.SSC_EN          = "FALSE";

endmodule
