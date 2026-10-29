//Copyright (C)2014-2026 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//Tool Version: V1.9.12.03 (64-bit)
//IP Version: 1.1
//Part Number: GW5AT-LV60PG484AC1/I0
//Device: GW5AT-60
//Device Version: B
//Created Time: Tue Sep 29 03:42:01 2026

module Gowin_ADC (adcrdy, adcvalue, mdrp_rdata, adcbit, clko, eoc, tlvds_ibuf_adc_i, tlvds_ibuf_adc_ib, tlvds_ibuf_adc_adcen, adcmode, vsenctl, clk, drstn, adcreqi, mdrp_clk, mdrp_wdata, mdrp_a_inc, mdrp_opcode, clki, chen, rstn, soc);

output adcrdy;
output [13:0] adcvalue;
output [7:0] mdrp_rdata;
output [12:0] adcbit;
output clko;
output eoc;
input tlvds_ibuf_adc_i;
input tlvds_ibuf_adc_ib;
input tlvds_ibuf_adc_adcen;
input adcmode;
input [2:0] vsenctl;
input clk;
input drstn;
input adcreqi;
input mdrp_clk;
input [7:0] mdrp_wdata;
input mdrp_a_inc;
input [1:0] mdrp_opcode;
input clki;
input [6:0] chen;
input rstn;
input soc;

wire adceno;
wire adc1bit;
wire adcclko;
wire gw_vcc;

assign gw_vcc = 1'b1;

TLVDS_IBUF_ADC tlvds_ibuf_adc_inst0 (
    .I(tlvds_ibuf_adc_i),
    .IB(tlvds_ibuf_adc_ib),
    .ADCEN(tlvds_ibuf_adc_adcen)
);

ADC_SAR adc_sar_inst (
    .ADCENO(adceno),
    .ADCRDY(adcrdy),
    .ADCVALUE(adcvalue),
    .MDRP_RDATA(mdrp_rdata),
    .ADC1BIT(adc1bit),
    .ADCCLKO(adcclko),
    .ADCBIT(adcbit),
    .CLKO(clko),
    .EOC(eoc),
    .ADCMODE(adcmode),
    .VSENCTL(vsenctl),
    .CLK(clk),
    .DRSTN(drstn),
    .ADCREQI(adcreqi),
    .MDRP_CLK(mdrp_clk),
    .MDRP_WDATA(mdrp_wdata),
    .MDRP_A_INC(mdrp_a_inc),
    .MDRP_OPCODE(mdrp_opcode),
    .ADCENI(gw_vcc),
    .CLKI(clki),
    .CHEN(chen),
    .RSTN(rstn),
    .SOC(soc)
);

defparam adc_sar_inst.BUF_EN = 29'b00000000010000000000010001001;
defparam adc_sar_inst.CLK_SEL = 1'b1;
defparam adc_sar_inst.DIV_CTL = 2'd0;
defparam adc_sar_inst.ADC_EN_SEL = 1'b0;
defparam adc_sar_inst.PHASE_SEL = 1'b0;
defparam adc_sar_inst.CSR_ADC_MODE = 1'b1;
defparam adc_sar_inst.CSR_VSEN_CTRL = 3'd0;
defparam adc_sar_inst.CSR_SAMPLE_CNT_SEL = 3'd4;
defparam adc_sar_inst.CSR_RATE_CHANGE_CTRL = 3'd5;
defparam adc_sar_inst.CSR_FSCAL = 10'd653;
defparam adc_sar_inst.CSR_OFFSET = 12'd0;
defparam adc_sar_inst.ADC_CLK_DIV = 2'b00;
defparam adc_sar_inst.ADC_CLKDIV_EN = 1'b0;
defparam adc_sar_inst.CLK_SRC_SEL = 1'b1;
defparam adc_sar_inst.VREF_BUF_EN = 1'b1;
defparam adc_sar_inst.COUNT_LEN = 5'b10100;
defparam adc_sar_inst.DAC_SAMPLE_END = 5'b10010;
defparam adc_sar_inst.DAC_SAMPLE_START = 5'b01101;
defparam adc_sar_inst.SH_SAMPLE_END = 5'b01011;
defparam adc_sar_inst.SH_SAMPLE_START = 5'b00001;
defparam adc_sar_inst.AUTO_CHOP_EN = 1'b1;
defparam adc_sar_inst.CHOP_CLK_DIV = 4'b0001;

endmodule //Gowin_ADC
