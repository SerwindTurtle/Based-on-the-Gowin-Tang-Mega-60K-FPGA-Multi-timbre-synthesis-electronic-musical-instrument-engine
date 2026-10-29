// ============================================================
// dbg_force_draw.v -- 压力传感器 / I²C 扫描 调试界面
//
// 画面（1024x600）：
// ┌──────────────────────────────────────────────┐
// │ <- 大方块：绿 = 检测到器件 / 红 = 没找到 │
// ├──────────────────────────────────────────────┤
// │ 0 072 ███████░░░░░░░░░░░░░ │
// │ 1 073 ████████░░░░░░░░░░░░ │
// │ 2 000 ░░░░░░░░░░░░░░░░░░░░ ○ │
// └──────────────────────────────────────────────┘
//
// 修正过的三个渲染 BUG：
// 1) 通道号错乱（显示 1,4,3,3...）：原来用 ry / ROW_H 除法，综合不稳。
// 改成显式位切片 ry[8:6]（等价 /64）。
// 2) 十进制数字恒为 000：原来用 for 循环 + 共享中间变量算除法，
// 被综合器优化掉。改成 8 路展开写死，每路独立寄存器。
// 3) 颜色按 18 位 RGB666 排布（[17:12]=R, [11:6]=G, [5:0]=B）。
// ============================================================
`timescale 1ns / 1ps

module dbg_force_draw (
    input  wire        pclk,
    input  wire        rst_n,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,

    input  wire [63:0] force_ch,   // 8 路 × 8 位（本次按下的力峰值高字节）
    input  wire        i2c_ok,     // 1 = 检测到器件（绿方块）
    input  wire [7:0]  i2c_err,    // 错误计数（本版不显示，保留接口）
    input  wire [7:0]  seen,       // 每通道"有效"标志

    output reg  [17:0] rgb,
    output reg         de_out
);

    // ------------------------------------------------------------
    // 颜色（RGB666）
    // ------------------------------------------------------------
    localparam [17:0] C_BG    = 18'b000000_001000_010000;   // 深蓝黑
    localparam [17:0] C_HEAD  = 18'b001000_010000_011000;   // 顶栏深蓝
    localparam [17:0] C_TXT   = 18'b111111_111111_111111;   // 白
    localparam [17:0] C_BOX   = 18'b001100_011000_100000;   // 通道号底色
    localparam [17:0] C_BARON = 18'b001111_111111_000000;   // 条形：亮黄
    localparam [17:0] C_BARBG = 18'b001000_001100_010000;   // 条形底：暗
    localparam [17:0] C_OK    = 18'b000000_111111_000000;   // 绿
    localparam [17:0] C_ERR   = 18'b111111_000000_000000;   // 红
    localparam [17:0] C_SEEN  = 18'b000000_111111_100000;
    localparam [17:0] C_NOSEEN= 18'b010000_010000_010000;

    // ------------------------------------------------------------
    // 5×7 点阵数字
    // ------------------------------------------------------------
    function [4:0] digit_row;
        input [3:0] d;
        input [2:0] r;
        begin
            case ({d, r})
                7'd0:digit_row=5'b01110; 7'd1:digit_row=5'b10001; 7'd2:digit_row=5'b10011;
                7'd3:digit_row=5'b10101; 7'd4:digit_row=5'b11001; 7'd5:digit_row=5'b10001;
                7'd6:digit_row=5'b01110;
                7'd7:digit_row=5'b00100; 7'd8:digit_row=5'b01100; 7'd9:digit_row=5'b00100;
                7'd10:digit_row=5'b00100;7'd11:digit_row=5'b00100;7'd12:digit_row=5'b00100;
                7'd13:digit_row=5'b01110;
                7'd14:digit_row=5'b01110;7'd15:digit_row=5'b10001;7'd16:digit_row=5'b00001;
                7'd17:digit_row=5'b00010;7'd18:digit_row=5'b00100;7'd19:digit_row=5'b01000;
                7'd20:digit_row=5'b11111;
                7'd21:digit_row=5'b11111;7'd22:digit_row=5'b00010;7'd23:digit_row=5'b00100;
                7'd24:digit_row=5'b00010;7'd25:digit_row=5'b00001;7'd26:digit_row=5'b10001;
                7'd27:digit_row=5'b01110;
                7'd28:digit_row=5'b00010;7'd29:digit_row=5'b00110;7'd30:digit_row=5'b01010;
                7'd31:digit_row=5'b10010;7'd32:digit_row=5'b11111;7'd33:digit_row=5'b00010;
                7'd34:digit_row=5'b00010;
                7'd35:digit_row=5'b11111;7'd36:digit_row=5'b10000;7'd37:digit_row=5'b11110;
                7'd38:digit_row=5'b00001;7'd39:digit_row=5'b00001;7'd40:digit_row=5'b10001;
                7'd41:digit_row=5'b01110;
                7'd42:digit_row=5'b00110;7'd43:digit_row=5'b01000;7'd44:digit_row=5'b10000;
                7'd45:digit_row=5'b11110;7'd46:digit_row=5'b10001;7'd47:digit_row=5'b10001;
                7'd48:digit_row=5'b01110;
                7'd49:digit_row=5'b11111;7'd50:digit_row=5'b00001;7'd51:digit_row=5'b00010;
                7'd52:digit_row=5'b00100;7'd53:digit_row=5'b01000;7'd54:digit_row=5'b01000;
                7'd55:digit_row=5'b01000;
                7'd56:digit_row=5'b01110;7'd57:digit_row=5'b10001;7'd58:digit_row=5'b10001;
                7'd59:digit_row=5'b01110;7'd60:digit_row=5'b10001;7'd61:digit_row=5'b10001;
                7'd62:digit_row=5'b01110;
                7'd63:digit_row=5'b01110;7'd64:digit_row=5'b10001;7'd65:digit_row=5'b10001;
                7'd66:digit_row=5'b01111;7'd67:digit_row=5'b00001;7'd68:digit_row=5'b00010;
                7'd69:digit_row=5'b01100;
                default: digit_row = 5'b00000;
            endcase
        end
    endfunction

    function bit_at;
        input [4:0] rowbits;
        input [2:0] col;
        begin
            case (col)
                3'd0: bit_at = rowbits[4];
                3'd1: bit_at = rowbits[3];
                3'd2: bit_at = rowbits[2];
                3'd3: bit_at = rowbits[1];
                3'd4: bit_at = rowbits[0];
                default: bit_at = 1'b0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // 8 路读数 -> 十进制三位数（展开写死）
    // n/10 = (n*103)>>10 ，对 0..255 精确
    // ------------------------------------------------------------
    reg [3:0] dh0,dt0,du0, dh1,dt1,du1, dh2,dt2,du2, dh3,dt3,du3;
    reg [3:0] dh4,dt4,du4, dh5,dt5,du5, dh6,dt6,du6, dh7,dt7,du7;

    reg [7:0] n0,n1,n2,n3,n4,n5,n6,n7;
    reg [7:0] a0,a1,a2,a3,a4,a5,a6,a7;
    reg [7:0] b0,b1,b2,b3,b4,b5,b6,b7;

    always @(posedge pclk) begin
        if (!rst_n) begin
            dh0<=0;dt0<=0;du0<=0; dh1<=0;dt1<=0;du1<=0;
            dh2<=0;dt2<=0;du2<=0; dh3<=0;dt3<=0;du3<=0;
            dh4<=0;dt4<=0;du4<=0; dh5<=0;dt5<=0;du5<=0;
            dh6<=0;dt6<=0;du6<=0; dh7<=0;dt7<=0;du7<=0;
        end else begin
            n0 = force_ch[ 7: 0]; n1 = force_ch[15: 8];
            n2 = force_ch[23:16]; n3 = force_ch[31:24];
            n4 = force_ch[39:32]; n5 = force_ch[47:40];
            n6 = force_ch[55:48]; n7 = force_ch[63:56];

            a0=(n0*10'd103)>>10; b0=(a0*10'd103)>>10;
            a1=(n1*10'd103)>>10; b1=(a1*10'd103)>>10;
            a2=(n2*10'd103)>>10; b2=(a2*10'd103)>>10;
            a3=(n3*10'd103)>>10; b3=(a3*10'd103)>>10;
            a4=(n4*10'd103)>>10; b4=(a4*10'd103)>>10;
            a5=(n5*10'd103)>>10; b5=(a5*10'd103)>>10;
            a6=(n6*10'd103)>>10; b6=(a6*10'd103)>>10;
            a7=(n7*10'd103)>>10; b7=(a7*10'd103)>>10;

            dh0<=b0[3:0]; dt0<=(a0-b0*8'd10); du0<=(n0-a0*8'd10);
            dh1<=b1[3:0]; dt1<=(a1-b1*8'd10); du1<=(n1-a1*8'd10);
            dh2<=b2[3:0]; dt2<=(a2-b2*8'd10); du2<=(n2-a2*8'd10);
            dh3<=b3[3:0]; dt3<=(a3-b3*8'd10); du3<=(n3-a3*8'd10);
            dh4<=b4[3:0]; dt4<=(a4-b4*8'd10); du4<=(n4-a4*8'd10);
            dh5<=b5[3:0]; dt5<=(a5-b5*8'd10); du5<=(n5-a5*8'd10);
            dh6<=b6[3:0]; dt6<=(a6-b6*8'd10); du6<=(n6-a6*8'd10);
            dh7<=b7[3:0]; dt7<=(a7-b7*8'd10); du7<=(n7-a7*8'd10);
        end
    end

    // ------------------------------------------------------------
    // 行/列布局（全部显式位切片，不用除法）
    // ------------------------------------------------------------
    localparam ROW_Y0 = 80;
    localparam BAR_X0 = 520;
    localparam BAR_W  = 440;

    wire [11:0] ry  = (y >= ROW_Y0) ? (y - ROW_Y0) : 12'd0;
    wire [2:0]  ch  = ry[8:6];          // ry / 64
    wire [5:0]  ryl = ry[5:0];          // ry % 64

    wire in_rows = (y >= ROW_Y0) && (y < ROW_Y0 + 512);
    wire in_ui   = (x < 12'd1024) && (y < 12'd600);

    // ------------------------------------------------------------
    // 只给第 0 路做 100ms 峰值保持（当前只接了 AIN0 一个传感器）
    // 目的：快速按压只持续几 ms，60Hz 屏幕可能整帧错过。
    // 这里不用数组/变量下标，避免 Gowin 的 SP00018 综合错误。
    // 注意：输入 force_ch 是 ads_raw（实时值），所以不按键、单捏传感器
    // 也能看到读数；峰值保持只在第 0 行生效。
    // ------------------------------------------------------------
    localparam [22:0] HOLD_TICKS = 23'd7_500_000;   // 100ms @ 75MHz
    wire [7:0] raw0 = force_ch[7:0];
    reg  [7:0] row0_peak;
    reg  [22:0] row0_hold;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            row0_peak <= 8'd0;
            row0_hold <= 23'd0;
        end else if (raw0 > row0_peak) begin
            row0_peak <= raw0;
            row0_hold <= HOLD_TICKS;
        end else if (row0_hold != 23'd0) begin
            row0_hold <= row0_hold - 23'd1;
        end else begin
            row0_peak <= raw0;
        end
    end

    wire [7:0] row_raw  = (ch == 3'd0) ? row0_peak : force_ch[{ch,3'b000} +: 8];
    wire       row_seen = seen[ch];

    // 条形长度 = raw * 3（封顶 BAR_W）
    // raw*3 = raw*2 + raw（用移位相加代替乘法，省一个 DSP 且路径更短）
    wire [9:0]  bar_calc = {2'b00, row_raw[7:0], 1'b0} + {2'b00, row_raw[7:0]};
    wire [11:0] bar_len  = (bar_calc > BAR_W) ? BAR_W : {2'b0, bar_calc};

    // ------------------------------------------------------------
    // 数字点亮判断
    // ------------------------------------------------------------
    wire [11:0] ry16 = ryl - 12'd16;

    function lit_at;
        input [11:0] xpos;
        input [11:0] ypos;
        input [11:0] ox;
        input [3:0]  d;
        reg [11:0] dx;
        reg [2:0]  col, row;
        begin
            dx = xpos - ox;
            if (dx[11] | (dx >= 12'd20))                  lit_at = 1'b0;
            else if (ypos[11] | (ypos >= 12'd28))         lit_at = 1'b0;
            else begin
                // dx<20 时 col 应该是 0~4（dx/4），
                // 原来写 dx[3:2] 在 dx=16..19 时算成 0，第 5 列画不出来，
                // 表现为数字缺笔画 / 看起来"消失"。
                col = dx[4:2];
                row = ypos[4:2];
                lit_at = bit_at(digit_row(d, row), col);
            end
        end
    endfunction

    reg [3:0] rh, rt, ru;
    always @(*) begin
        case (ch)
            3'd0: begin rh=dh0; rt=dt0; ru=du0; end
            3'd1: begin rh=dh1; rt=dt1; ru=du1; end
            3'd2: begin rh=dh2; rt=dt2; ru=du2; end
            3'd3: begin rh=dh3; rt=dt3; ru=du3; end
            3'd4: begin rh=dh4; rt=dt4; ru=du4; end
            3'd5: begin rh=dh5; rt=dt5; ru=du5; end
            3'd6: begin rh=dh6; rt=dt6; ru=du6; end
            default: begin rh=dh7; rt=dt7; ru=du7; end
        endcase
    end

    wire lit_ch = lit_at(x, ry16, 12'd24,  {1'b0, ch});
    wire lit_h  = lit_at(x, ry16, 12'd110, rh);
    wire lit_t  = lit_at(x, ry16, 12'd158, rt);
    wire lit_u  = lit_at(x, ry16, 12'd206, ru);
    wire lit_dig= lit_ch | lit_h | lit_t | lit_u;

    // ------------------------------------------------------------
    // 合成颜色
    // ------------------------------------------------------------
    reg [17:0] c;

    always @(*) begin
        c = C_BG;
        if (in_ui) begin
            if (y < 12'd70) begin
                c = C_HEAD;
                if ((x >= 12'd24) && (x < 12'd84) && (y >= 12'd14) && (y < 12'd56))
                    c = i2c_ok ? C_OK : C_ERR;
            end else if (in_rows) begin
                if ((x >= 12'd16) && (x < 12'd64) && (ryl >= 12'd8) && (ryl < 12'd56))
                    c = C_BOX;
                if ((x >= BAR_X0) && (x < BAR_X0 + BAR_W) &&
                    (ryl >= 12'd20) && (ryl < 12'd44)) begin
                    if ((x - BAR_X0) < bar_len) c = C_BARON;
                    else                        c = C_BARBG;
                end
                if ((x >= 12'd1000) && (x < 12'd1024) &&
                    (ryl >= 12'd24) && (ryl < 12'd40))
                    c = row_seen ? C_SEEN : C_NOSEEN;
                if (lit_dig) c = C_TXT;
            end
        end
    end

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            rgb    <= 18'd0;
            de_out <= 1'b0;
        end else begin
            rgb    <= de ? c : 18'd0;
            de_out <= de;
        end
    end

endmodule
