# ============================================================
#  tools/synthctl.ps1 —— 不打开网页也能调参数的命令行工具
# ------------------------------------------------------------
#  用途：
#    1) 验证 FPGA 的串口是否通（不依赖浏览器）
#    2) 在网页还没连上时，先改几个参数听声音
#    3) 打印遥测，检查力度 / I²C / 复音数
#
#  ★ 不想敲命令：直接双击 ..\tools\串口监视.cmd
#     它会列出现有 COM 口、提示你输入串口名，然后监听 30 秒遥测。
#
#  用法（Windows PowerShell 5.1 及以上）：
#    .\tools\synthctl.ps1 -Cmd list
#    .\tools\synthctl.ps1 -Port COM7 -Cmd ping
#    .\tools\synthctl.ps1 -Port COM7 -Cmd get   -Reg 0x10
#    .\tools\synthctl.ps1 -Port COM7 -Cmd set   -Reg 0x10 -Val 4
#    .\tools\synthctl.ps1 -Port COM7 -Cmd preset -Val 4
#    .\tools\synthctl.ps1 -Port COM7 -Cmd monitor -Seconds 10
#    .\tools\synthctl.ps1 -Port 7    -Cmd monitor      # 数字会自动补成 COM7
#
#  ★ 串口位置：板上丝印 DEBUG-USB2 的 USB-C 口（板载 BL616 USB-JTAG&UART），
#    不是 USB3.0 那个口。不用外接 CH340。
#  ★ 协议：115200 8N1，A5 5A | TYPE | LEN | PAYLOAD | CRC8(0x07)
# ============================================================
param(
    [string]$Port = "",
    [ValidateSet('list', 'ping', 'get', 'set', 'preset', 'monitor')]
    [string]$Cmd = 'ping',
    [string]$Reg = '0x10',
    [int]$Val = 0,
    [int]$Seconds = 8
)

$ErrorActionPreference = 'Stop'

$REG_MAP = [ordered]@{
    '0x01' = 'VERSION (ro)'
    '0x10' = 'TIMBRE      0..7'
    '0x11' = 'WAVE        0方波 1锯齿 2三角 3正弦 4钢琴 5FM'
    '0x12' = 'FM_RATIO    0..7 -> 0.5,1,1.5,2,2.5,3,3.5,4'
    '0x13' = 'FM_DEPTH    0..4'
    '0x14' = 'HARM1_ATT   0..3'
    '0x15' = 'HARM2_ATT   0..3'
    '0x16' = 'HARM3_ATT   0..3'
    '0x17' = 'HARM4_ATT   0..3'
    '0x18' = 'VEL_PRESS   0/1'
    '0x19' = 'ENV_ONESHOT 0/1'
    '0x20' = 'ENV_RATE    0..4'
    '0x21' = 'ENV_EXP     0..15'
    '0x22' = 'ATK_STEP    1..65535'
    '0x23' = 'DEC_STEP    0..65535'
    '0x24' = 'SUS_LEVEL   0..65535'
    '0x25' = 'REL_STEP    0..65535'
    '0x30' = 'MIX_SHIFT   0..6'
    '0x31' = 'MASTER_VOL  0..255'
    '0x32' = 'MUTE        0/1'
    '0x38' = 'KEY_VOL0    0..128'
    '0x39' = 'KEY_VOL1'
    '0x3A' = 'KEY_VOL2'
    '0x3B' = 'KEY_VOL3'
    '0x3C' = 'KEY_VOL4'
    '0x3D' = 'KEY_VOL5'
    '0x3E' = 'KEY_VOL6'
    '0x3F' = 'KEY_VOL7'
    '0x40' = 'ADS_VEL (ro)'
    '0x41' = 'ADS_RAW (ro)'
    '0x42' = 'POLY (ro)'
    '0x43' = 'POLY_PEAK (ro)'
    '0x44' = 'OCT_SHIFT (ro)'
    '0x45' = 'KEY_MASK (ro)'
    '0x46' = 'FLAGS (ro)'
    '0x47' = 'ADS_ERR (ro)'
}

if ($Cmd -eq 'list') {
    $REG_MAP.GetEnumerator() | ForEach-Object { '{0}  {1}' -f $_.Key, $_.Value }
    return
}

# 允许直接写数字：-Port 7 等价于 COM7；大小写都行
$Port = ("$Port").Trim()
if ($Port -match '^\d+$') { $Port = "COM$Port" }
if ($Port) { $Port = $Port.ToUpper() }

if (-not $Port) {
    $ports = @([System.IO.Ports.SerialPort]::GetPortNames())
    Write-Host ''
    if ($ports.Count -gt 0) {
        Write-Host '当前系统里的串口：' -ForegroundColor Cyan
        $ports | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor White }
    } else {
        Write-Host '系统里一个串口都没找到。' -ForegroundColor Yellow
        Write-Host '  -> 设备管理器 -> 端口(COM 和 LPT) 里要有 "USB Serial Port (COMx)"' -ForegroundColor Gray
        Write-Host '  -> 没有的话检查 USB 线 / 驱动 / 是否插在 DEBUG-USB2 口' -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '用法： .\tools\synthctl.ps1 -Port COM7 -Cmd monitor' -ForegroundColor Gray
    Write-Host '      也可以写 -Port 7（数字会自动补成 COM7）' -ForegroundColor Gray
    return
}

# ---------- CRC8/ATM ----------
function Get-Crc8 {
    param([byte[]]$Data, [int]$From, [int]$To)
    [int]$c = 0
    for ($i = $From; $i -lt $To; $i++) {
        $c = $c -bxor [int]$Data[$i]
        for ($b = 0; $b -lt 8; $b++) {
            if ($c -band 0x80) { $c = (($c -shl 1) -bxor 0x07) -band 0xFF }
            else { $c = ($c -shl 1) -band 0xFF }
        }
    }
    return [byte]$c
}

# ---------- 组帧 ----------
function New-Frame {
    param([byte]$Type, [byte[]]$Payload)
    $list = New-Object System.Collections.Generic.List[byte]
    $list.Add(0xA5); $list.Add(0x5A); $list.Add($Type); $list.Add([byte]$Payload.Count)
    foreach ($b in $Payload) { $list.Add($b) }
    $body = $list.ToArray()
    $crc = Get-Crc8 -Data $body -From 2 -To $body.Length
    $list.Add($crc)
    return $list.ToArray()
}

# ---------- 串口 ----------
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$sp.ReadTimeout = 60
$sp.WriteTimeout = 500
$sp.DtrEnable = $false
$sp.RtsEnable = $false

$script:rx = New-Object System.Collections.Generic.List[byte]
$script:gotFrames = 0

function Read-For {
    param([int]$Milliseconds)
    $deadline = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $b = $sp.ReadByte()
            if ($b -ge 0) { $script:rx.Add([byte]$b) }
        } catch [System.TimeoutException] {
            # 没数据，继续等
        } catch {
            # 端口错误（被拔出 / 关闭）
            return
        }

        # ---- 解帧 ----
        while ($true) {
            $start = -1
            for ($k = 0; $k -lt $script:rx.Count - 1; $k++) {
                if ($script:rx[$k] -eq 0xA5 -and $script:rx[$k + 1] -eq 0x5A) { $start = $k; break }
            }
            if ($start -lt 0) {
                if ($script:rx.Count -gt 1) { $script:rx.RemoveRange(0, $script:rx.Count - 1) }
                break
            }
            if ($start -gt 0) { $script:rx.RemoveRange(0, $start) }
            if ($script:rx.Count -lt 4) { break }
            $len = [int]$script:rx[3]
            if ($script:rx.Count -lt (5 + $len)) { break }

            $snapshot = $script:rx.ToArray()
            $crc = Get-Crc8 -Data $snapshot -From 2 -To (4 + $len)
            if ($crc -ne $snapshot[4 + $len]) {
                $script:rx.RemoveAt(0)
                continue
            }

            $type = $snapshot[2]
            $payload = @()
            if ($len -gt 0) { $payload = $snapshot[4..(3 + $len)] }
            $script:rx.RemoveRange(0, 5 + $len)
            $script:gotFrames++

            switch ($type) {
                0x81 {
                    for ($i = 0; $i + 2 -lt $payload.Count; $i += 3) {
                        $addr = [int]$payload[$i]
                        $value = [int]$payload[$i + 1] -bor ([int]$payload[$i + 2] -shl 8)
                        Write-Host ('VALUE  {0} = {1} (0x{2:X4})' -f ('0x{0:X2}' -f $addr), $value, $value) -ForegroundColor Cyan
                    }
                }
                0x82 {
                    if ($payload.Count -ge 16) {
                        $timbre = $payload[0]; $wave = $payload[1]; $vel = $payload[2]; $raw = $payload[3]
                        $poly = $payload[4]; $peak = $payload[5]; $oct = [int]$payload[6]
                        if ($oct -gt 127) { $oct -= 256 }
                        $keys = $payload[7]; $flags = $payload[8]; $err = $payload[9]
                        $master = $payload[10]; $mixmute = $payload[11]
                        $mix = ($mixmute -shr 1) -band 7; $mute = $mixmute -band 1
                        $sets = $payload[12]; $rxerr = $payload[13]
                        $frame = [int]$payload[14] -bor ([int]$payload[15] -shl 8)
                        $i2c = 'OK'; if (($flags -band 1) -eq 0) { $i2c = '无通信' }
                        $page = '主界面'; if ($flags -band 2) { $page = '压力调试页' }
                        Write-Host ('遥测 #{0,-5} 音色={1} 波形={2} 力度={3,3} ADC={4,3} 复音={5} 峰值={6} 八度={7,2} 按键=0x{8:X2} I2C={9} 错误={10} 主音量={11} 衰减=÷{12} 静音={13} 页面={14} 写入={15} 串口错={16}' -f `
                            $frame, $timbre, $wave, $vel, $raw, $poly, $peak, $oct, $keys, $i2c, $err, $master, [math]::Pow(2, $mix), $mute, $page, $sets, $rxerr) `
                            -ForegroundColor DarkCyan
                    }
                }
                0x83 {
                    if ($payload.Count -ge 2) {
                        Write-Host ('PONG 固件 v{0}.{1} —— 串口通了！' -f $payload[0], $payload[1]) -ForegroundColor Green
                    }
                }
                default {
                    Write-Host ('RX type=0x{0:X2} len={1}' -f $type, $len) -ForegroundColor DarkGray
                }
            }
        }
    }
}

function Send-Frame {
    param([byte]$Type, [byte[]]$Payload)
    $f = New-Frame -Type $Type -Payload $Payload
    $sp.Write($f, 0, $f.Length)
    $sp.BaseStream.Flush()
}

try {
    $sp.Open()
} catch {
    Write-Host ''
    Write-Host ('打不开 {0}：{1}' -f $Port, $_.Exception.Message) -ForegroundColor Red
    Write-Host '  -> 串口名对吗？设备管理器 -> 端口(COM 和 LPT) 里看' -ForegroundColor Gray
    Write-Host '  -> 是不是被别的软件占用了？先关掉串口助手/网页再试' -ForegroundColor Gray
    Write-Host '  -> 拔插一次 USB，COM 号可能会变' -ForegroundColor Gray
    $sp.Dispose()
    return
}
try {
    Start-Sleep -Milliseconds 80
    $sp.DiscardInBuffer()
    Write-Host ('已打开 {0} @115200（等待 FPGA 遥测…）' -f $Port) -ForegroundColor Gray

    # 先听 300ms，确认遥测 / 端口正常
    Read-For -Milliseconds 300

    switch ($Cmd) {
        'ping' {
            $sp.DiscardInBuffer()
            $script:rx.Clear()
            Send-Frame -Type 0x03 -Payload @()
            Write-Host 'TX PING' -ForegroundColor Yellow
            Read-For -Milliseconds 500
        }
        'get' {
            $addr = [Convert]::ToInt32($Reg, 16)
            $sp.DiscardInBuffer()
            $script:rx.Clear()
            Send-Frame -Type 0x02 -Payload @([byte]$addr)
            Write-Host ('TX GET {0}' -f $Reg) -ForegroundColor Yellow
            Read-For -Milliseconds 500
        }
        'set' {
            $addr = [Convert]::ToInt32($Reg, 16)
            $lo = [byte]($Val -band 0xFF)
            $hi = [byte](($Val -shr 8) -band 0xFF)
            Send-Frame -Type 0x01 -Payload @([byte]$addr, $lo, $hi)
            Write-Host ('TX SET {0} = {1}' -f $Reg, $Val) -ForegroundColor Yellow
            Read-For -Milliseconds 600
        }
        'preset' {
            if ($Val -lt 0 -or $Val -gt 7) { throw '-Val 必须是 0..7（音色号）' }
            Send-Frame -Type 0x01 -Payload @(0x10, [byte]$Val, 0x00)
            Write-Host ('TX TIMBRE = {0}（FPGA 会自动装载该音色的出厂预设）' -f $Val) -ForegroundColor Yellow
            Read-For -Milliseconds 600
        }
        'monitor' {
            Write-Host ('监视 {0} 秒（Ctrl+C 退出）…' -f $Seconds) -ForegroundColor Yellow
            Read-For -Milliseconds ($Seconds * 1000)
        }
    }

    Write-Host ('共收到 {0} 帧。' -f $script:gotFrames) -ForegroundColor Gray
    if ($script:gotFrames -eq 0) {
        Write-Host '一帧都没收到：检查 COM 口是否选对、板子是否上电、FPGA 是否烧了最新码流。' -ForegroundColor Red
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
