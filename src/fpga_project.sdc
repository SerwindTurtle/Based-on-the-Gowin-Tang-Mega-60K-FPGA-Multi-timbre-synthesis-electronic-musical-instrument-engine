# ============================================================
#  时序约束
# ============================================================
#  sys_clk: 板载 50MHz
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]

#  adc_clk: 50MHz 分频出来的 3.125MHz（音频/ADC）
create_clock -name adc_clk -period 320 -waveform {0 160} [get_nets {clkdiv_cnt[3]}]

#  clk_px: HDMI 像素时钟 75MHz（pll_simple: VCO 750 / ODIV0 10）
#  ⚠️ 必须显式声明，否则工具会按 sys_clk 的 20ns 去检查 HDMI 域，
#     等于把 75MHz 的路径放宽了 1.5 倍，实际可能跑不起来。
#     网名以 P&R 报告的 Global Clock 表为准：u_hdmi/clk_px
create_clock -name clk_px -period 13.333 -waveform {0 6.667} [get_nets {u_hdmi/clk_px}]

# ============================================================
#  三个时钟互不相关（数据都经过同步器/准静态，不做跨域时序检查）
#    adc_clk  -> sys_clk / clk_px : 波形数据、写指针、压力读数（两级同步）
#    sys_clk  -> clk_px           : page 翻页、ads 状态（两级同步）
# ============================================================
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {adc_clk}] -group [get_clocks {clk_px}]