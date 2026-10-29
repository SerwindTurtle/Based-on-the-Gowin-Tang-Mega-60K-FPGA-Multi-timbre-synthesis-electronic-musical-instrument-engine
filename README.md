# 基于高云Tang Mega 60K FPGA的多音色合成电子乐器引擎

> 纯 FPGA 实时音频合成 · 8 键压力感应 · 10 种硬件音色 + 自定义 · 32 个振荡器层  
> 开发板：Sipeed Tang Mega 60K（GW5AT-60B）  
> 文档版本：2026-10-29

## 项目简介

本项目是一台完全由 FPGA 实时合成的电子乐器。演奏输入为 8 键压力感应键盘：按键决定音高，8 路压力传感器决定力度，八度、变调、滑音、颤音和延音负责表情控制。音频链从相位累加器、波形/FM、独立 ADSR、并行混音、发送式效果链到 I2S 输出，全部在 FPGA 内部逐采样生成，不依赖预录 PCM 或 PC 音频处理。

PC 网页只通过 UART 调参数和收遥测，不参与发声；拔掉电脑后乐器仍可独立演奏。

## 核心特性

| 项目 | 实现 |
|---|---|
| 演奏输入 | 8 个白键 + `KBD_UP` / `KBD_DN` 八度键 + 8 路压力传感 |
| 多维控制 | 力度、音高、八度、变调、滑音、颤音、延音 |
| 声部结构 | 8 个独立按键声部，每个声部独立相位与 ADSR |
| 并行规模 | 8 键 × 4 层齐奏 = **32 个振荡器层** |
| 音色 | 10 种硬件音色 + 网页自定义档 |
| 效果 | 每通道 4 路发送（回声/混响/合唱/相位）+ 主失真/限幅/5 段 EQ |
| 调制 | PWM 仅作用于方波；方波/锯齿/三角/正弦/钢琴/FM |
| 显示 | HDMI 720p60：真实音频波形 + 4 段频谱（8 条） |
| 控制 | UART 115200 8N1，约 24Hz 遥测；网页 Web Serial 控制台 |
| 采样率 | 48.828kHz（3.125MHz / 64） |
| 资源 | LUT 44771/59904（74.7%）、DSP 108.5/118（92%）、BSRAM 34/118 |
| 时序 | setup +0.040ns / hold +0.247ns，0 违例 |

### 口径说明

- **32 个振荡器层不是 32 键复音。** 独立按键声部是 8 个，每个主声部带独立 ADSR；另 24 层是微失谐齐奏层，共用主声部包络与力度。
- **HDMI 是 4 段频谱**（一阶滤波器组，显示成 8 条），不是高分辨率 FFT；网页监视器里的波形/频谱是按参数估算的预览。
- **延迟是设计值**：音频链按 48.828kHz 固定流水线运行，设计延迟小于 5ms；没有仪器实测时不要写成“实测 5ms”。
- 未实现：蓝牙/手机 APP、在线音色下载、录音回放、LED 演奏指引、李萨如、9–32 通道独立处理。

## 系统架构

```text
8 键 / 2×ADS1115
        │  GPIO / I²C
        ▼
keyboard_in / ads1115_ctrl
        ▼
voice_alloc（8 个主声部，单音/复音）
        ▼
synth_voices：8 ×（osc_voice + adsr）
        ▼
unison_saw：每键 +3 个微失谐锯齿层（8×4=32）
        ▼
fx_chain
  通道条（音量/失真/4 路发送）
  → echo / reverb / chorus+phaser
  → fx_master（失真 / 5 段 EQ / 限幅 / 主音量）
        ▼
i2s_tx → PT8211 DAC → NS4263 功放 → 耳机/扬声器

旁路：
  fx_chain → scope_capture / spectrum4 → hdmi_ui → HDMI
  PC 网页 ↔ UART ↔ param_regs（只传参数与遥测）
```

时钟域：

- `sys_clk`：50MHz，控制、UART、I2S 位时钟
- `adc_clk`：3.125MHz = `sys_clk / 16`，合成与混音
- `sample_en`：`adc_clk / 64`，得到 48.828kHz 音频采样率
- `clk_px`：75MHz 像素 / 375MHz 位时钟，HDMI 720p60

## 仓库结构

```text
fpga_project/
├─ src/                    # 36 个 Verilog 源文件（含 Gowin IP 包装）
│  ├─ top.v                # 顶层：输入、合成、效果、显示、参数
│  ├─ keyboard_in.v        # 8 键同步/去抖/音高映射
│  ├─ ads1115_ctrl.v       # 两片 ADS1115 读 8 路压力
│  ├─ voice_alloc.v        # 声部分配 / 单音模式
│  ├─ osc_voice.v          # 相位累加、波形/FM/PWM
│  ├─ adsr.v               # 独立包络
│  ├─ synth_voices.v       # 8 个主声部并行
│  ├─ unison_saw.v         # 32 个振荡器层
│  ├─ fx_channel_mix.v     # 通道音量/失真/4 路发送
│  ├─ fx_echo.v            # 回声
│  ├─ fx_reverb.v          # 混响
│  ├─ fx_mod.v             # 合唱 + 相位
│  ├─ fx_master.v          # 失真 + EQ + 限幅 + 主音量
│  ├─ fx_chain.v           # 效果链总装
│  ├─ scope_capture.v      # 波形采集
│  ├─ spectrum4.v          # 4 段频谱
│  ├─ hdmi/                # HDMI 时序与界面
│  ├─ param_regs.v         # 参数寄存器 / 协议 / 预设 / 遥测
│  ├─ uart_rx.v/uart_tx.v  # 115200 8N1
│  ├─ fpga_project.cst     # 引脚约束
│  └─ fpga_project.sdc     # 时序约束
├─ web/                    # 网页控制台（Web Serial）
├─ tools/                  # 协议自测、串口工具、Gowin 构建脚本
├─ sim/tb_ping.v           # PING 帧回归测试
├─ 技术文档/                # 技术文档 + 8 张生成框图 + 图片清单
├─ build.cmd               # Windows 一键构建
├─ fpga_project.gprj       # Gowin 工程
├─ README.md
└─ .gitignore
```

`src/` 下 36 个 `.v` 中有 2 个是 Gowin IP 生成文件（`dvi_tx/dvi_tx.v`、`gowin_adc/gowin_adc.v`），其余为项目源码。

## 快速开始

### 1. 构建

Windows 直接双击：

```text
build.cmd
```

或命令行：

```text
gw_sh.exe tools/gowin/syn.tcl      # 仅综合
gw_sh.exe tools/gowin/pnr.tcl      # 仅布局布线（需已有综合结果）
gw_sh.exe tools/gowin/build.tcl    # 综合 + 布局布线
```

构建产物：

```text
impl/pnr/fpga_project.fs
```

注意：

- 本工程约 44k LUT，**第一次全量构建需要较长时间**（综合十几分钟 + PnR 二十多分钟），不是点一下马上出结果。
- Gowin IDE 的 “Run All” 默认可能是 `place 0 / route 0`，会明显更慢；建议使用 `build.cmd` / `build.tcl`，或在 IDE 的 Place & Route 配置里改成 **2/2**。
- 构建过程可看 `impl/pnr/fpga_project.log`；若长期停在 `Routing Phase 0`，先确认 `impl/pnr/cmd.do` 中是 `place_option 2 / route_option 2`。
- `impl/` 已在 `.gitignore` 中，不随源码提交。

### 2. 烧录

用 Gowin Programmer 烧录 `impl/pnr/fpga_project.fs`。音频输出接耳机或扬声器，HDMI 接 720p60 显示器。

### 3. 打开网页控制台

```text
web/启动控制台.cmd
```

或直接用 Chrome/Edge 打开 `web/index.html`。点击「连接串口」，选择板载 `DEBUG-USB2` 对应的 COM 口（115200 8N1）。

- 板载 UART：`UART_TX = U15`、`UART_RX = V14`，接 BL616 的 USB-JTAG/UART。
- 不要选蓝牙串口；如果分不清 COM 口，用 `tools/串口监视.cmd` 逐个试。
- 网页只调参数，不传输音频。

### 4. 演奏

- 8 个白键对应 C4~C5 一个八度；`KBD_UP` / `KBD_DN` 整体升降八度。
- `KEY0` 循环切换 10 种硬件音色；`LEDs[2:0]` 显示当前音色号（8/9 会显示成 0/1，网页仍显示真实值）。
- 压力传感器控制力度；压力越大，声音越强。
- 网页可切换自定义音色、调 ADSR、效果、齐奏、PWM 和 EQ。

## 硬件接口

| 接口 | 引脚 / 说明 |
|---|---|
| 系统时钟 | `sys_clk = V22`，50MHz |
| 复位 | `sys_rst_n = AA13`，低有效 |
| 8 键键盘 | `KBD[0..7] = AB20, AA19, AA21, AA20, AB22, AB21, Y22, Y21` |
| 八度键 | `KBD_UP = P19`，`KBD_DN = R19` |
| 音色键 | `KEY0 = AB13`，低有效 |
| 状态 LED | `LEDs[0..2] = R17, P16, U21` |
| 压力 I²C | `ADS_SDA = R18`，`ADS_SCL = T18`，4.7kΩ 上拉到 3.3V |
| 音频 I2S | `HP_BCK = Y17`、`HP_WS = AB17`、`HP_DIN = AA16` |
| 功放使能 | `PA_EN = AB16`，低有效 |
| HDMI | TMDS 差分：时钟 `G15/G16`，数据 `J14/H14`、`J15/H15`、`K17/J17` |
| UART | `UART_TX = U15`，`UART_RX = V14` |

完整约束见 [`src/fpga_project.cst`](src/fpga_project.cst)。

### 压力采集

两颗 ADS1115 挂在同一 I²C 总线：

- #1：`ADDR = GND` → 地址 `0x48`，AIN0~3 对应白键 1~4
- #2：`ADDR = VCC` → 地址 `0x49`，AIN0~3 对应白键 5~8

每个键对应一个 AIN 单端通道。I²C 需要外部 4.7kΩ 上拉到 3.3V；FPGA 在按键按下时优先扫描对应通道，并保持本次按下的峰值作为力度。

## 音色与效果

### 10 种硬件音色

| 编号 | 音色 | 实现 | 包络 |
|---|---|---|---|
| 0 | 方波 | 相位高 8 位 + PWM 占空比 | 持续音 |
| 1 | 锯齿 | 相位高 16 位偏移二进制 | 持续音 |
| 2 | 三角 | 相位高 16 位折叠 | 持续音 |
| 3 | 正弦 | 65 点四分之一波表 + 象限镜像 | 持续音 |
| 4 | 钢琴 | 单次查表 + 2/3 次泛音整形 | one-shot |
| 5 | 古筝 | FM ratio 1.0 | one-shot |
| 6 | 木琴 | FM ratio 3.5 | one-shot |
| 7 | 单簧管 | FM ratio 2.0 | 持续音 |
| 8 | 颠琴 | FM ratio 2.0，短促 | one-shot |
| 9 | 钟琴 | FM ratio 3.5，明亮 | one-shot |

网页第 11 档「自定义」不写 FPGA 的 `TIMBRE`，只覆盖音色参数；手动改波形/FM/ADSR 会自动进入自定义档，再点预设或按 KEY0 退出。

### 效果链

- 每通道：音量、失真、4 路发送（回声/混响/合唱/相位）
- 全局：回声（16384 点 BSRAM 延时线）、混响（4 梳状 + 2 全通）、合唱/相位（两条调制延时线）
- 主链：失真 → 5 段 EQ → 限幅 → 主音量平滑
- 发送量拉高会自动打开对应效果器；湿声在 `fx_master` 与干声相加

详细寄存器、参数范围和网页操作见 [`web/README.md`](web/README.md)。

## 验证

### 协议自测

```text
node tools/protocol_test.js
```

当前 **28 项全部通过**，覆盖寄存器帧、16 项打包、遥测 TIMBRE 4 位、PWM、延音、八度、齐奏声部换算等。

### 串口 PING

`sim/tb_ping.v` 是 ModelSim 回归：

```text
A5 5A 03 00 3F  →  A5 5A 83 02 01 01 CF
```

用于确认 UART 接收、CRC、回包状态机没有回归。

### 板上检查

1. 上电后 HDMI 显示波形/频谱和按键状态。
2. 按下 8 个键，声部数增加；同时按 4 个键以上应能听到独立声部。
3. 切换 10 种音色，听感与波形类型对应。
4. 打开齐奏，8 键 × 4 层；网页声部数显示 32 个振荡器层。
5. 调高某通道回声/混响发送，对应效果器自动打开。
6. 拖动 PWM 深度，声音应自动切到方波并听到脉宽变化。
7. 网页遥测约 24Hz 更新；压力调试页显示 8 路压力。

## 文档

- 技术文档：[`技术文档/基于高云Tang_Mega_60K_FPGA的多音色合成电子乐器引擎_技术文档_v1.0.docx`](技术文档/基于高云Tang_Mega_60K_FPGA的多音色合成电子乐器引擎_技术文档_v1.0.docx)
- 技术文档目录与图片状态：[`技术文档/README.md`](技术文档/README.md)
- 需要补拍的图片清单：[`技术文档/图片清单.md`](技术文档/图片清单.md)
- 网页控制台说明：[`web/README.md`](web/README.md)
- 开发过程记录：[`进度交接备注.md`](进度交接备注.md)

## 已知限制

- **32 个振荡器层 ≠ 32 键复音**：独立按键声部为 8 个，附加 24 层共用包络。
- HDMI 频谱是 **4 段能量**，不是 FFT；网页监视器是参数预览，不是音频回传。
- 延迟为设计值；如需实测，用示波器同时观察按键 gate 和 DAC 输出。
- 9–32 通道条是网页预留布局，当前只有 1–8 对应 8 个琴键。
- 未实现蓝牙/APP、在线音色下载、录音回放、LED 演奏指引、李萨如。
- 采样率 48.828kHz 比标准 48kHz 高约 1.7%，这是 50MHz 时钟整数分频的结果。

## 第三方与致谢

- 开发板与原理图：Sipeed Tang Mega 60K
- FPGA 与工具链：Gowin GW5AT-60B / Gowin EDA
- DAC/功放/ADC 器件：PT8211、NS4263、ADS1115
- 第三方 IP、数据手册和商标归各自所有者

本项目代码与文档用于竞赛、学习和项目展示。
