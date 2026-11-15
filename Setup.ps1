# 一键准备：生成本地快捷方式（可选：开机自启）
# 用法：  powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
#         powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Autostart

[CmdletBinding()]
param(
    [switch]$Autostart
)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args  = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $dir 'DesktopClock.ps1') + '"'

function New-ClockShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = $args
    $lnk.WorkingDirectory = $dir
    $lnk.WindowStyle      = 7
    $lnk.Description      = '此刻 · 桌面时钟'
    $icon = Join-Path $dir 'clock.ico'
    if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = $icon + ',0' }
    $lnk.Save()
}

# 1) 文件夹里的快捷方式
$localLnk = Join-Path $dir '此刻桌面时钟.lnk'
New-ClockShortcut $localLnk
"已生成快捷方式： $localLnk"

# 2) 开机自启（可选）
if ($Autostart) {
    $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '此刻桌面时钟.lnk'
    New-ClockShortcut $startupLnk
    "已加入开机自启： $startupLnk"
}

"双击「启动时钟.bat」或上面生成的快捷方式即可运行。"
