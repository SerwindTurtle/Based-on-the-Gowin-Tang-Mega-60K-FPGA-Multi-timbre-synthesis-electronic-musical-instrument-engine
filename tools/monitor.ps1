# ============================================================
#  tools/monitor.ps1
#  ------------------------------------------------------------
#  串口监视小工具（由 tools\串口监视.cmd 双击调用）
#
#  也可以手动运行：
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\monitor.ps1
#
#  做四件事：
#    1) 列出系统里的 COM 口
#    2) 自动识别板载 BL616 调试器的 UART（FTDI B 通道）
#    3) 让你确认 / 输入串口名（COM6 或直接 6）
#    4) 调用 synthctl.ps1 监听 30 秒遥测
#
#  ★ 板载调试器会枚举出两个 FTDI 串口：
#      USB Serial Converter A -> JTAG（Gowin 下载用）
#      USB Serial Converter B -> UART（我们要的这个）
#    本脚本会把 B 通道挑出来做默认值。
# ============================================================

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host '  串口监视（不用打开网页，先确认 FPGA 串口通不通）' -ForegroundColor Cyan
Write-Host '  - 板子要上电；已经烧了最新码流（旧码流没有 UART）' -ForegroundColor Gray
Write-Host '  - USB 线插在板上丝印 DEBUG-USB2 的口（不是 USB3.0）' -ForegroundColor Gray
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host ''

$ports = @([System.IO.Ports.SerialPort]::GetPortNames())
if ($ports.Count -gt 0) {
    Write-Host '当前系统里的串口：' -ForegroundColor Cyan
    $ports | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor White }
} else {
    Write-Host '系统里一个串口都没找到。' -ForegroundColor Yellow
    Write-Host '  -> 设备管理器 -> 端口(COM 和 LPT) 里要有 "USB Serial Port (COMx)"' -ForegroundColor Gray
    Write-Host '  -> 没有的话查 USB 线 / 驱动 / 是不是插在 DEBUG-USB2 口' -ForegroundColor Gray
}

# ---- 从注册表找 FTDI B 通道（板载调试器的 UART）----
#  Sipeed 的 BL616 调试器固件把两个通道的序列号做成 ...xxxA / ...xxxB
$suggest = $null
try {
    foreach ($dev in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\FTDIBUS' -ErrorAction Stop) {
        if ($dev.PSChildName -match 'B$') {
            foreach ($iface in Get-ChildItem $dev.PSPath -ErrorAction SilentlyContinue) {
                $pn = (Get-ItemProperty (Join-Path $iface.PSPath 'Device Parameters') -ErrorAction SilentlyContinue).PortName
                if ($pn -and ($ports -contains $pn)) { $suggest = $pn }
            }
        }
    }
} catch { }

Write-Host ''
if ($suggest) {
    Write-Host ("检测到板载调试器的 UART：{0}" -f $suggest) -ForegroundColor Green
    Write-Host '  （USB Serial Converter B = UART；A 通道是 JTAG，下载码流用，别选错）' -ForegroundColor Gray
} else {
    Write-Host '没自动认出板载调试器，请手动选串口。' -ForegroundColor DarkYellow
    Write-Host '  （Device Manager 里 "USB Serial Converter B" 下面那个才是 UART）' -ForegroundColor Gray
}

if ($suggest) {
    $p = Read-Host ("输入串口名（直接回车用 {0}，输入 q 退出）" -f $suggest)
} else {
    $p = Read-Host '输入串口名（例如 COM7，或直接输入数字 7；回车退出）'
}
$p = ("$p").Trim()

if ($p -eq 'q' -or $p -eq 'Q') { return }
if (-not $p) {
    if (-not $suggest) { return }
    $p = $suggest
}

$p = $p.ToUpper()
if ($p -match '^\d+$') { $p = 'COM' + $p }

Write-Host ''
Write-Host ('开始监视 {0}，30 秒（Ctrl+C 可提前结束）…' -f $p) -ForegroundColor Yellow
& (Join-Path $PSScriptRoot 'synthctl.ps1') -Port $p -Cmd monitor -Seconds 30
