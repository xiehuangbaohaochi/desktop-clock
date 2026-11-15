#Requires -Version 5.1
<#
    此刻 · 桌面时钟  (DesktopClock)
    ------------------------------------------------------------
    透明背景的桌面数字时钟：大号时间 + 日期 + 农历 + 当日天气。

    · 左键拖动    移动位置（自动记住）
    · 滚轮        调整不透明度
    · 右键        显示秒 / 24 小时制 / 天气 / 主题 / 尺寸 / 开机自启 / 退出

    依赖：Windows 自带的 .NET Framework (WPF)，无需安装第三方库。
    配置：同目录 clock-settings.json（city 可指定城市，留空则按 IP 自动定位）
    缓存：同目录 weather-cache.json
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

trap {
    $detail = "ERROR: " + $_.Exception.Message + "`r`n" + $_.InvocationInfo.PositionMessage + "`r`n" + $_.ScriptStackTrace
    try { [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot 'clock.log'), $detail + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
    Write-Host $detail
    break
}

$script:Dir              = $PSScriptRoot
$script:SettingsPath     = Join-Path $script:Dir 'clock-settings.json'
$script:WeatherCachePath = Join-Path $script:Dir 'weather-cache.json'
$script:LogPath          = Join-Path $script:Dir 'clock.log'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Net.Http

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log([string]$Message) {
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- 单实例
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DSH.DesktopClock.Widget')
try {
    if (-not $script:Mutex.WaitOne(0)) { return }
} catch [System.Threading.AbandonedMutexException] { } catch { }

# ---------------------------------------------------------------- 设置
$script:Config = [ordered]@{
    left        = $null
    top         = $null
    showSeconds = $false
    hour24      = $true
    desktop     = $false
    weather     = $true
    city        = ''
    theme       = 'glass'
    scale       = 1.0
    opacity     = 1.0
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($script:Config.Keys)) {
            $prop = $saved.PSObject.Properties[$key]
            if ($null -ne $prop -and $null -ne $prop.Value) { $script:Config[$key] = $prop.Value }
        }
    } catch { Write-Log "读取设置失败: $_" }
}

# ---------------------------------------------------------------- 界面
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="ClockWindow"
        Title="此刻 · 桌面时钟"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="{x:Null}"
        Topmost="True"
        ShowInTaskbar="False"
        ShowActivated="False"
        ResizeMode="NoResize"
        SizeToContent="WidthAndHeight"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
    <Grid x:Name="RootGrid" Margin="40">
        <Border x:Name="Card"
                CornerRadius="28"
                Background="#00000000"
                BorderBrush="#00000000"
                BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="36" ShadowDepth="10" Direction="270" Opacity="0" Color="#000000"/>
            </Border.Effect>
        </Border>
        <StackPanel x:Name="Content" Margin="30,12,30,16" HorizontalAlignment="Center">
            <StackPanel x:Name="TimeRow" Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock x:Name="PeriodText"
                           Text="上午"
                           FontFamily="Microsoft YaHei UI"
                           FontSize="14"
                           Foreground="#D9EFE6D8"
                           VerticalAlignment="Bottom"
                           Margin="0,0,8,20"
                           Visibility="Collapsed"/>
                <TextBlock x:Name="TimeText"
                           Text="00:00"
                           FontFamily="Segoe UI Variable Display, Segoe UI"
                           FontWeight="Light"
                           FontSize="76"
                           Foreground="#FFF8EF"/>
                <TextBlock x:Name="SecondsText"
                           Text="00"
                           FontFamily="Segoe UI Variable Display, Segoe UI"
                           FontWeight="Light"
                           FontSize="22"
                           Foreground="#FFFFD9A0"
                           VerticalAlignment="Bottom"
                           Margin="9,0,0,20"
                           Visibility="Collapsed"/>
            </StackPanel>
            <StackPanel x:Name="InfoRow" Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock x:Name="DateText"
                           Text="11月15日周日"
                           FontFamily="Microsoft YaHei UI"
                           FontSize="13.5"
                           Foreground="#D9EFE6D8"
                           VerticalAlignment="Center"/>
                <TextBlock x:Name="LunarText"
                           Text="十月初七"
                           FontFamily="Microsoft YaHei UI"
                           FontSize="13.5"
                           Foreground="#D9EFE6D8"
                           Margin="10,0,0,0"
                           VerticalAlignment="Center"/>
                <StackPanel x:Name="WeatherBlock" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="SepText"
                               Text="|"
                               FontFamily="Microsoft YaHei UI"
                               FontSize="12.5"
                               Foreground="#D9EFE6D8"
                               Opacity="0.4"
                               Margin="10,0,10,0"
                               VerticalAlignment="Center"/>
                    <TextBlock x:Name="WeatherIcon"
                               Text="☁"
                               FontFamily="Segoe UI Symbol"
                               FontSize="14"
                               Foreground="#D9EFE6D8"
                               Margin="0,0,5,1"
                               VerticalAlignment="Center"/>
                    <TextBlock x:Name="WeatherText"
                               Text="17°"
                               FontFamily="Microsoft YaHei UI"
                               FontSize="13.5"
                               Foreground="#D9EFE6D8"
                               VerticalAlignment="Center"/>
                </StackPanel>
            </StackPanel>
        </StackPanel>
    </Grid>
</Window>
'@

try {
    $xmlReader = New-Object System.Xml.XmlTextReader (New-Object System.IO.StringReader $script:Xaml)
    $Root = [Windows.Markup.XamlReader]::Load($xmlReader)
} catch {
    Write-Log "XAML 加载失败: $_"
    [Windows.MessageBox]::Show("界面加载失败：`n$_", '此刻 · 桌面时钟', 'OK', 'Error') | Out-Null
    exit 1
}

$RootGrid     = $Root.FindName('RootGrid')
$Card         = $Root.FindName('Card')
$CardShadow   = $Card.Effect
$TimeText     = $Root.FindName('TimeText')
$SecondsText  = $Root.FindName('SecondsText')
$PeriodText   = $Root.FindName('PeriodText')
$DateText     = $Root.FindName('DateText')
$LunarText    = $Root.FindName('LunarText')
$WeatherBlock = $Root.FindName('WeatherBlock')
$WeatherIcon  = $Root.FindName('WeatherIcon')
$WeatherText  = $Root.FindName('WeatherText')
$SepText      = $Root.FindName('SepText')

# ---------------------------------------------------------------- 配色
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Hex) {
    return [Windows.Media.SolidColorBrush]$script:BrushConverter.ConvertFromString($Hex)
}

$script:Themes = [ordered]@{
    dark = @{
        Label       = '深色玻璃'
        Card        = '#E6101319'
        Border      = '#26FFFFFF'
        BorderHover = '#4DFFFFFF'
        Time        = '#F5FFFFFF'
        Text        = '#8CFFFFFF'
        Accent      = '#FF59C2FF'
        Shadow      = 0.55
        TextShadow  = $false
    }
    light = @{
        Label       = '浅色玻璃'
        Card        = '#F2FFFFFF'
        Border      = '#1F000000'
        BorderHover = '#42000000'
        Time        = '#F20B1220'
        Text        = '#8C0B1220'
        Accent      = '#FF0A84FF'
        Shadow      = 0.16
        TextShadow  = $false
    }
    glass = @{
        Label       = '透明'
        Card        = '#00000000'
        Border      = '#00000000'
        BorderHover = '#00000000'
        Time        = '#FFF8EF'
        Text        = '#D9EFE6D8'
        Accent      = '#FFFFD9A0'
        Shadow      = 0.0
        TextShadow  = $true
    }
}

$script:TextShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:TextShadow.BlurRadius  = 18
$script:TextShadow.ShadowDepth = 0
$script:TextShadow.Opacity     = 0.65
$script:TextShadow.Color       = [Windows.Media.Colors]::Black

$script:TextBlocks = @($TimeText, $SecondsText, $PeriodText, $DateText, $LunarText, $WeatherIcon, $WeatherText, $SepText)

function Apply-Theme([string]$Name) {
    if (-not $script:Themes.Contains($Name)) { $Name = 'glass' }
    $t = $script:Themes[$Name]
    $script:Config.theme = $Name

    $Card.Background    = Get-Brush $t.Card
    $Card.BorderBrush   = Get-Brush $t.Border
    $CardShadow.Opacity = [double]$t.Shadow

    $TimeText.Foreground    = Get-Brush $t.Time
    $SecondsText.Foreground = Get-Brush $t.Accent
    $PeriodText.Foreground  = Get-Brush $t.Text
    $DateText.Foreground    = Get-Brush $t.Text
    $LunarText.Foreground   = Get-Brush $t.Text
    $WeatherIcon.Foreground = Get-Brush $t.Text
    $WeatherText.Foreground = Get-Brush $t.Text
    $SepText.Foreground     = Get-Brush $t.Text

    foreach ($tb in $script:TextBlocks) {
        if ($t.TextShadow) { $tb.Effect = $script:TextShadow } else { $tb.Effect = $null }
    }
}

function Apply-Scale([double]$Scale) {
    if ($Scale -lt 0.6 -or $Scale -gt 2.0) { $Scale = 1.0 }
    $script:Config.scale = $Scale
    $RootGrid.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($Scale, $Scale)
}

# ---------------------------------------------------------------- 日期 / 农历
$script:WeekChars = [char[]]'日一二三四五六'
$script:LunarCalendar = New-Object System.Globalization.ChineseLunisolarCalendar
$script:LunarMonths = @('正月', '二月', '三月', '四月', '五月', '六月', '七月', '八月', '九月', '十月', '冬月', '腊月')
$script:LunarDays = @(
    '初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
    '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
    '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十'
)

function Get-LunarText([datetime]$Date) {
    try {
        $lunarYear  = $script:LunarCalendar.GetYear($Date)
        $monthIndex = $script:LunarCalendar.GetMonth($Date)
        $leapIndex  = $script:LunarCalendar.GetLeapMonth($lunarYear)

        $isLeap = $false
        if ($leapIndex -gt 0) {
            if ($monthIndex -eq $leapIndex) {
                $isLeap = $true
            } elseif ($monthIndex -gt $leapIndex) {
                $monthIndex = $monthIndex - 1
            }
        }
        $day = $script:LunarCalendar.GetDayOfMonth($Date)

        $prefix = if ($isLeap) { '闰' } else { '' }
        return $prefix + $script:LunarMonths[$monthIndex - 1] + $script:LunarDays[$day - 1]
    } catch {
        return ''
    }
}

function Update-Clock {
    $now   = [DateTime]::Now
    $is24h = [bool]$script:Config.hour24

    $clockText = if ($is24h) { $now.ToString('HH:mm') } else { $now.ToString('h:mm') }
    if ($TimeText.Text -ne $clockText) { $TimeText.Text = $clockText }

    $periodLabel = ''
    if (-not $is24h) { $periodLabel = if ($now.Hour -lt 12) { '上午' } else { '下午' } }
    if ($PeriodText.Text -ne $periodLabel) {
        $PeriodText.Text = $periodLabel
        $PeriodText.Visibility = if ($periodLabel -eq '') { 'Collapsed' } else { 'Visible' }
    }

    if ([bool]$script:Config.showSeconds) {
        if ($SecondsText.Visibility -ne 'Visible') { $SecondsText.Visibility = 'Visible' }
        $sec = $now.ToString('ss')
        if ($SecondsText.Text -ne $sec) { $SecondsText.Text = $sec }
    } elseif ($SecondsText.Visibility -ne 'Collapsed') {
        $SecondsText.Visibility = 'Collapsed'
    }

    $dateLine = '{0}月{1}日周{2}' -f $now.Month, $now.Day, $script:WeekChars[[int]$now.DayOfWeek]
    if ($DateText.Text -ne $dateLine) { $DateText.Text = $dateLine }

    $lunarLine = Get-LunarText $now
    if ($LunarText.Text -ne $lunarLine) {
        $LunarText.Text = $lunarLine
        $LunarText.Visibility = if ($lunarLine -eq '') { 'Collapsed' } else { 'Visible' }
    }
}

# ---------------------------------------------------------------- 天气
$script:WeatherClient = New-Object System.Net.Http.HttpClient
$script:WeatherClient.Timeout = [TimeSpan]::FromSeconds(10)

$script:WeatherTask      = $null
$script:WeatherPending   = $false
$script:WeatherTaskStart = $null
$script:HasWeather       = $false

function Get-WeatherGlyph([string]$Desc) {
    if ($Desc -match '雷') { return [char]0x26A1 }
    if ($Desc -match '雪') { return [char]0x2744 }
    if ($Desc -match '雨') { return [char]0x2614 }
    if ($Desc -match '雾|霾|沙|尘') { return [char]0x2601 }
    if ($Desc -match '阴') { return [char]0x2601 }
    if ($Desc -match '多云') { return [char]0x26C5 }
    if ($Desc -match '晴') { return [char]0x2600 }
    return [char]0x2601
}

function Set-WeatherDisplay([string]$Desc, [string]$Temp) {
    if ([string]::IsNullOrWhiteSpace($Temp)) { return }
    $script:HasWeather = $true
    $WeatherIcon.Text = Get-WeatherGlyph $Desc
    $WeatherText.Text = $Temp
    Update-WeatherVisibility
}

function Update-WeatherVisibility {
    if ($script:HasWeather -and [bool]$script:Config.weather) {
        $WeatherBlock.Visibility = 'Visible'
    } else {
        $WeatherBlock.Visibility = 'Collapsed'
    }
}

function Save-WeatherCache([string]$Desc, [string]$Temp) {
    try {
        $obj = [ordered]@{ desc = $Desc; temp = $Temp; saved = (Get-Date).ToString('s') }
        [System.IO.File]::WriteAllText($script:WeatherCachePath, ($obj | ConvertTo-Json),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Load-WeatherCache {
    if (-not (Test-Path -LiteralPath $script:WeatherCachePath)) { return }
    try {
        $cache = Get-Content -LiteralPath $script:WeatherCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cache.desc -and $cache.temp) { Set-WeatherDisplay ([string]$cache.desc) ([string]$cache.temp) }
    } catch { }
}

function Start-WeatherFetch {
    if ($script:WeatherPending) { return }
    try {
        $city = [string]$script:Config.city
        $base = if ([string]::IsNullOrWhiteSpace($city)) {
            'https://wttr.in/'
        } else {
            'https://wttr.in/' + [Uri]::EscapeDataString($city)
        }
        $url = $base + '?format=%C%7C%t&lang=zh-cn'
        $script:WeatherTask      = $script:WeatherClient.GetStringAsync($url)
        $script:WeatherTaskStart = Get-Date
        $script:WeatherPending   = $true
    } catch {
        $script:WeatherPending = $false
        Write-Log "天气请求发起失败: $_"
    }
}

function Complete-WeatherTask {
    $task = $script:WeatherTask
    if ($null -eq $task) { $script:WeatherPending = $false; return }

    if (-not $task.IsCompleted) {
        if ($null -ne $script:WeatherTaskStart -and
            ((Get-Date) - $script:WeatherTaskStart).TotalSeconds -gt 14) {
            try { $script:WeatherClient.CancelPendingRequests() } catch { }
            $script:WeatherPending = $false
            $script:WeatherTask = $null
            Write-Log "天气请求超时"
        }
        return
    }

    if ($task.IsFaulted -or $task.IsCanceled) {
        $msg = if ($task.Exception) { $task.Exception.GetBaseException().Message } else { 'canceled' }
        Write-Log "天气获取失败: $msg"
        $script:WeatherPending = $false
        $script:WeatherTask = $null
        return
    }

    try {
        $raw   = [string]$task.Result
        $parts = $raw.Trim() -split '\|'
        if ($parts.Count -ge 2) {
            $desc = $parts[0].Trim()
            $temp = $parts[1].Trim().Replace('+', '').Replace('C', '')
            if ($temp -match '\d' -and $desc -ne '') {
                Set-WeatherDisplay $desc $temp
                Save-WeatherCache $desc $temp
            }
        }
    } catch {
        Write-Log "天气解析失败: $_"
    }

    $script:WeatherPending = $false
    $script:WeatherTask = $null
}

# ---------------------------------------------------------------- 保存 / 位置
function Save-Settings {
    try {
        if ($null -ne $Root -and -not [double]::IsNaN($Root.Left)) {
            $script:Config.left = [double]$Root.Left
            $script:Config.top  = [double]$Root.Top
        }
        $json = $script:Config | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log "保存设置失败: $_" }
}

function Restore-Position {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w  = if ($Root.ActualWidth  -gt 0) { $Root.ActualWidth }  else { 340 }
    $h  = if ($Root.ActualHeight -gt 0) { $Root.ActualHeight } else { 150 }

    $left = $script:Config.left
    $top  = $script:Config.top
    $valid = $false

    if ($null -ne $left -and $null -ne $top) {
        $l = [double]$left
        $t = [double]$top
        if ($l -gt ($wa.Left - 60) -and $l -lt ($wa.Right - 90) -and
            $t -gt ($wa.Top - 60) -and $t -lt ($wa.Bottom - 70)) {
            $valid = $true
        }
    }
    if (-not $valid) {
        $l = $wa.Left + ($wa.Width - $w) / 2
        $t = $wa.Top + 56
    }
    $Root.Left = [double]$l
    $Root.Top  = [double]$t
}

# ---------------------------------------------------------------- 开机自启
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '此刻桌面时钟.lnk'

function Test-Autostart {
    return (Test-Path -LiteralPath $script:StartupLnk)
}

function Set-Autostart([bool]$Enable) {
    try {
        if ($Enable) {
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut($script:StartupLnk)
            $lnk.TargetPath       = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            $lnk.Arguments        = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $script:Dir 'DesktopClock.ps1') + '"'
            $lnk.WorkingDirectory = $script:Dir
            $lnk.WindowStyle      = 7
            $lnk.Description      = '此刻 · 桌面时钟'
            $icon = Join-Path $script:Dir 'clock.ico'
            if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = $icon + ',0' }
            $lnk.Save()
        } elseif (Test-Path -LiteralPath $script:StartupLnk) {
            Remove-Item -LiteralPath $script:StartupLnk -Force
        }
        return $true
    } catch {
        Write-Log "设置开机自启失败: $_"
        return $false
    }
}

# ---------------------------------------------------------------- 右键菜单
$script:MenuShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:MenuShadow.BlurRadius  = 30
$script:MenuShadow.ShadowDepth = 10
$script:MenuShadow.Opacity     = 0.55
$script:MenuShadow.Color       = [Windows.Media.Colors]::Black

$script:MenuBorder = New-Object System.Windows.Controls.Border
$script:MenuBorder.Background      = Get-Brush '#F5161B24'
$script:MenuBorder.BorderBrush     = Get-Brush '#2EFFFFFF'
$script:MenuBorder.BorderThickness = New-Object System.Windows.Thickness(1)
$script:MenuBorder.CornerRadius    = New-Object System.Windows.CornerRadius(12)
$script:MenuBorder.Padding         = New-Object System.Windows.Thickness(6)
$script:MenuBorder.MinWidth        = 224
$script:MenuBorder.Effect          = $script:MenuShadow
$script:MenuBorder.Focusable       = $true

$script:MenuPanel = New-Object System.Windows.Controls.StackPanel
$script:MenuBorder.Child = $script:MenuPanel

$script:MenuHost = New-Object System.Windows.Controls.Grid
$script:MenuHost.Margin = New-Object System.Windows.Thickness(18)
[void]$script:MenuHost.Children.Add($script:MenuBorder)

$script:MenuWindow = New-Object System.Windows.Window
$script:MenuWindow.WindowStyle           = 'None'
$script:MenuWindow.AllowsTransparency    = $true
$script:MenuWindow.Background            = [Windows.Media.Brushes]::Transparent
$script:MenuWindow.ShowInTaskbar         = $false
$script:MenuWindow.ShowActivated         = $true
$script:MenuWindow.Topmost               = $true
$script:MenuWindow.ResizeMode            = 'NoResize'
$script:MenuWindow.SizeToContent         = 'WidthAndHeight'
$script:MenuWindow.WindowStartupLocation = 'Manual'
$script:MenuWindow.Content               = $script:MenuHost
$script:MenuWindow.Add_Deactivated({ try { $script:MenuWindow.Hide() } catch { } })

function Hide-Menu {
    try { if ($script:MenuWindow.IsVisible) { $script:MenuWindow.Hide() } } catch { }
}

$script:MenuTextBrush   = Get-Brush '#F2F6EFE3'
$script:MenuMutedBrush  = Get-Brush '#80EFE6D8'
$script:MenuAccentBrush = Get-Brush '#FFF2C87E'
$script:MenuHoverBrush  = Get-Brush '#1FFFFFFF'

function Add-MenuRow([string]$Text, [scriptblock]$OnClick, [bool]$Checked = $false) {
    $prefix = if ($Checked) { '✓  ' } else { '     ' }

    $row = New-Object System.Windows.Controls.Border
    $row.CornerRadius = New-Object System.Windows.CornerRadius(7)
    $row.Padding      = New-Object System.Windows.Thickness(9, 7, 12, 7)
    $row.Background   = [Windows.Media.Brushes]::Transparent
    $row.Cursor       = [System.Windows.Input.Cursors]::Hand

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text       = $prefix + $Text
    $tb.FontFamily = 'Microsoft YaHei UI'
    $tb.FontSize   = 12.5
    $tb.Foreground = $script:MenuTextBrush
    $row.Child     = $tb

    $row.Tag = $OnClick
    $row.Add_MouseEnter({ param($s, $e) $s.Background = $script:MenuHoverBrush })
    $row.Add_MouseLeave({ param($s, $e) $s.Background = [Windows.Media.Brushes]::Transparent })
    $row.Add_MouseLeftButtonUp({ param($s, $e) & $s.Tag; Hide-Menu })

    [void]$script:MenuPanel.Children.Add($row)
}

function Add-MenuSeparator {
    $line = New-Object System.Windows.Controls.Border
    $line.Height     = 1
    $line.Margin     = New-Object System.Windows.Thickness(9, 5, 9, 5)
    $line.Background = Get-Brush '#26FFFFFF'
    [void]$script:MenuPanel.Children.Add($line)
}

function Add-MenuSegments([string]$Label, $Options, [scriptblock]$OnPick) {
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = New-Object System.Windows.Thickness(9, 6, 9, 8)

    $lab = New-Object System.Windows.Controls.TextBlock
    $lab.Text       = $Label
    $lab.FontFamily = 'Microsoft YaHei UI'
    $lab.FontSize   = 10.5
    $lab.Foreground = $script:MenuMutedBrush
    $lab.Margin     = New-Object System.Windows.Thickness(0, 0, 0, 6)
    [void]$wrap.Children.Add($lab)

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'

    foreach ($opt in $Options) {
        $chip = New-Object System.Windows.Controls.Border
        $chip.CornerRadius = New-Object System.Windows.CornerRadius(5)
        $chip.Padding      = New-Object System.Windows.Thickness(8, 3, 8, 3)
        $chip.Margin       = New-Object System.Windows.Thickness(0, 0, 6, 0)
        $chip.Cursor       = [System.Windows.Input.Cursors]::Hand
        $chip.Tag          = @{ Action = $OnPick; Value = $opt.Value }

        if ($opt.Active) {
            $chip.Background = Get-Brush '#33F2C87E'
        } else {
            $chip.Background = Get-Brush '#12FFFFFF'
        }

        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text       = $opt.Label
        $tb.FontFamily = 'Microsoft YaHei UI'
        $tb.FontSize   = 11.5
        $tb.Foreground = if ($opt.Active) { $script:MenuAccentBrush } else { $script:MenuMutedBrush }
        $chip.Child = $tb

        if (-not $opt.Active) {
            $chip.Add_MouseEnter({ param($s, $e) $s.Background = $script:MenuHoverBrush })
            $chip.Add_MouseLeave({ param($s, $e) $s.Background = Get-Brush '#12FFFFFF' })
        }
        $chip.Add_MouseLeftButtonUp({ param($s, $e) $act = $s.Tag; & $act.Action $act.Value; Hide-Menu })

        [void]$row.Children.Add($chip)
    }

    [void]$wrap.Children.Add($row)
    [void]$script:MenuPanel.Children.Add($wrap)
}

function Build-ThemeOptions {
    $opts = @()
    foreach ($key in @('dark', 'light', 'glass')) {
        $opts += @{ Label = $script:Themes[$key].Label; Value = $key; Active = ($key -eq $script:Config.theme) }
    }
    return $opts
}

function Build-ScaleOptions {
    $current = [double]$script:Config.scale
    $opts = @()
    foreach ($pair in @(@('0.85', '小'), @('1.0', '标准'), @('1.15', '大'), @('1.35', '特大'))) {
        $val = [double]$pair[0]
        $opts += @{ Label = $pair[1]; Value = $val; Active = ([math]::Abs($val - $current) -lt 0.001) }
    }
    return $opts
}

function Build-OpacityOptions {
    $current = [double]$script:Config.opacity
    $opts = @()
    foreach ($v in @(1.0, 0.85, 0.7, 0.55)) {
        $opts += @{ Label = ('{0}%' -f [int]($v * 100)); Value = $v; Active = ([math]::Abs($v - $current) -lt 0.001) }
    }
    return $opts
}

function Show-Menu {
    $script:MenuPanel.Children.Clear()

    Add-MenuRow '显示秒' {
        $script:Config.showSeconds = -not [bool]$script:Config.showSeconds
        Update-Clock
        Save-Settings
    } ([bool]$script:Config.showSeconds)

    Add-MenuRow '24 小时制' {
        $script:Config.hour24 = -not [bool]$script:Config.hour24
        Update-Clock
        Save-Settings
    } ([bool]$script:Config.hour24)

    Add-MenuRow '显示天气' {
        $script:Config.weather = -not [bool]$script:Config.weather
        Update-WeatherVisibility
        Save-Settings
    } ([bool]$script:Config.weather)

    Add-MenuRow '置于底层' {
        Set-DesktopMode (-not [bool]$script:Config.desktop)
        Save-Settings
    } ([bool]$script:Config.desktop)

    Add-MenuSeparator

    Add-MenuSegments '外观主题' (Build-ThemeOptions) {
        param($value)
        Apply-Theme ([string]$value)
        Save-Settings
    }

    Add-MenuSegments '显示尺寸' (Build-ScaleOptions) {
        param($value)
        Apply-Scale ([double]$value)
        Save-Settings
    }

    Add-MenuSegments '不透明度' (Build-OpacityOptions) {
        param($value)
        $script:Config.opacity = [double]$value
        $Root.Opacity = [double]$value
        Save-Settings
    }

    Add-MenuSeparator

    Add-MenuRow '刷新天气' { Start-WeatherFetch }

    Add-MenuRow '开机自动启动' {
        $want = -not (Test-Autostart)
        if (-not (Set-Autostart $want)) {
            [Windows.MessageBox]::Show('无法写入开机启动项。可以把「此刻桌面时钟.lnk」的副本放进启动文件夹（Win+R 输入 shell:startup）。',
                '此刻 · 桌面时钟', 'OK', 'Warning') | Out-Null
        }
    } (Test-Autostart)

    Add-MenuRow '回到默认位置' {
        $script:Config.left = $null
        $script:Config.top  = $null
        Restore-Position
        Save-Settings
    }

    Add-MenuSeparator

    Add-MenuRow '退出' { $Root.Close() }

    $pos = [System.Windows.Input.Mouse]::GetPosition($Root)
    $script:MenuWindow.Left = $Root.Left + $pos.X
    $script:MenuWindow.Top  = $Root.Top + $pos.Y

    $script:MenuWindow.Show()
    $script:MenuWindow.Activate()
    $script:MenuBorder.Focus() | Out-Null

    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($script:MenuWindow.Left + $script:MenuWindow.ActualWidth - 36 -gt $wa.Right) {
        $script:MenuWindow.Left = $wa.Right - $script:MenuWindow.ActualWidth
    }
    if ($script:MenuWindow.Top + $script:MenuWindow.ActualHeight - 36 -gt $wa.Bottom) {
        $script:MenuWindow.Top = $wa.Bottom - $script:MenuWindow.ActualHeight
    }
}

$script:MenuBorder.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { Hide-Menu; $e.Handled = $true }
})

$script:MenuWindow.Add_Loaded({
    $script:MenuBorder.Focus() | Out-Null
})

# ---------------------------------------------------------------- 交互
$Root.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    try {
        $Root.DragMove()
        if ([bool]$script:Config.desktop) { Send-ClockToBottom }
        Save-Settings
    } catch { }
})

$Root.Add_MouseRightButtonUp({
    param($sender, $e)
    Show-Menu
    $e.Handled = $true
})

$Root.Add_MouseWheel({
    param($sender, $e)
    $step = if ($e.Delta -gt 0) { 0.05 } else { -0.05 }
    $val  = [Math]::Round([Math]::Min(1.0, [Math]::Max(0.3, $Root.Opacity + $step)), 2)
    $Root.Opacity = $val
    $script:Config.opacity = $val
    Save-Settings
    $e.Handled = $true
})

$Root.Add_MouseEnter({
    $Card.BorderBrush = Get-Brush $script:Themes[$script:Config.theme].BorderHover
})

$Root.Add_MouseLeave({
    $Card.BorderBrush = Get-Brush $script:Themes[$script:Config.theme].Border
})

# 作为「工具窗口」运行：不出现在 Alt+Tab 切换器里
Add-Type -Namespace ClockNative -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
'@

$Root.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Root)
        $style  = [ClockNative.Win32]::GetWindowLong($helper.Handle, -20)
        [void][ClockNative.Win32]::SetWindowLong($helper.Handle, -20, ($style -bor 0x00000080))
        if ([bool]$script:Config.desktop) { Set-DesktopMode $true }
    } catch {
        Write-Log "设置工具窗口样式失败: $_"
    }
})

# ---------------------------------------------------------------- 桌面层模式
function Get-WindowHandle {
    return (New-Object System.Windows.Interop.WindowInteropHelper($Root)).Handle
}

function Send-ClockToBottom {
    $h = Get-WindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [void][ClockNative.Win32]::SetWindowPos($h, [IntPtr]::new(1), 0, 0, 0, 0, 0x0013)
    }
}

function Set-DesktopMode([bool]$On) {
    $script:Config.desktop = $On
    $h = Get-WindowHandle
    if ($h -eq [IntPtr]::Zero) { return }

    $ex = [ClockNative.Win32]::GetWindowLong($h, -20)
    if ($On) {
        $ex = $ex -bor 0x08000000          # WS_EX_NOACTIVATE：点击不抢焦点、不被抬升
        $Root.Topmost = $false
    } else {
        $ex = $ex -band (-bnot 0x08000000)
        $Root.Topmost = $true
    }
    [void][ClockNative.Win32]::SetWindowLong($h, -20, $ex)

    if ($On) { Send-ClockToBottom }
}

# ---------------------------------------------------------------- 启动
Apply-Theme $script:Config.theme
Apply-Scale ([double]$script:Config.scale)
$Root.Opacity = [double]$script:Config.opacity
$Root.Topmost = -not [bool]$script:Config.desktop
Update-Clock
Load-WeatherCache

$RootGrid.Opacity = 0.0

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:Timer.Add_Tick({ Update-Clock })
$script:Timer.Start()

$script:WeatherPoll = New-Object System.Windows.Threading.DispatcherTimer
$script:WeatherPoll.Interval = [TimeSpan]::FromMilliseconds(400)
$script:WeatherPoll.Add_Tick({
    if ($script:WeatherPending) { Complete-WeatherTask }
})
$script:WeatherPoll.Start()

$script:WeatherRefresh = New-Object System.Windows.Threading.DispatcherTimer
$script:WeatherRefresh.Interval = [TimeSpan]::FromMinutes(20)
$script:WeatherRefresh.Add_Tick({
    if ([bool]$script:Config.weather) { Start-WeatherFetch }
})
$script:WeatherRefresh.Start()

$Root.Add_Loaded({
    Restore-Position

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From     = 0.0
    $fade.To       = 1.0
    $fade.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds(280)
    $RootGrid.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    if ([bool]$script:Config.weather) {
        $script:WeatherDelay = New-Object System.Windows.Threading.DispatcherTimer
        $script:WeatherDelay.Interval = [TimeSpan]::FromMilliseconds(1200)
        $script:WeatherDelay.Add_Tick({
            $script:WeatherDelay.Stop()
            Start-WeatherFetch
        })
        $script:WeatherDelay.Start()
    }
})

$Root.Add_Closing({
    $script:Timer.Stop()
    $script:WeatherPoll.Stop()
    $script:WeatherRefresh.Stop()
    Save-Settings
    try { $script:Mutex.ReleaseMutex() } catch { }
})

try {
    $script:App = New-Object System.Windows.Application
    $script:App.ShutdownMode = 'OnMainWindowClose'
    [void]$script:App.Run($Root)
} catch {
    Write-Log "运行失败: $_"
    [Windows.MessageBox]::Show("运行失败：`n$_", '此刻 · 桌面时钟', 'OK', 'Error') | Out-Null
} finally {
    try { $script:Mutex.ReleaseMutex() } catch { }
}
