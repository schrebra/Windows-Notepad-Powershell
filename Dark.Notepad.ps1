#Requires -Version 5.1
Set-StrictMode -Version Latest
 $ErrorActionPreference = "Stop"

#region ==================== CONSTANTS ====================
 $script:APP_NAME         = "Notepad"
 $script:APP_VERSION      = "5.0.14"
 $script:SETTINGS_FOLDER  = "Notepad"
 $script:SETTINGS_FILE    = "settings.ini"

 $script:MIN_WINDOW_W = 400;   $script:MIN_WINDOW_H = 300
 $script:MAX_WINDOW_W = 3840;  $script:MAX_WINDOW_H = 2160
 $script:DEF_WINDOW_W = 900;   $script:DEF_WINDOW_H = 650

 $script:MIN_FONT      = 8;    $script:MAX_FONT      = 72
 $script:DEF_FONT_SIZE = 14;   $script:DEF_FONT_FAMILY = "Consolas"

 $script:MIN_MARGIN   = 0;     $script:MAX_MARGIN   = 200;  $script:DEF_MARGIN = 0
 $script:MIN_SPACING  = 1.0;   $script:MAX_SPACING  = 3.0;  $script:DEF_SPACING = 1.2

 $script:MIN_ZOOM = 10;        $script:MAX_ZOOM = 500;       $script:DEF_ZOOM = 100; $script:ZOOM_STEP = 10

 $script:ZOOM_FONT_MIN = 4.0;  $script:ZOOM_FONT_MAX = 200.0
 $script:WHEEL_DELTA   = 120.0
 $script:SCROLL_LINES_PER_DELTA = 5.0

 $script:COLOR_CHROME     = "#2D2D30"
 $script:COLOR_EDITOR_BG  = "#1E1E1E"
 $script:COLOR_EDITOR_FG  = "#D4D4D4"
 $script:COLOR_FIND_BG    = "#005A9E"
 $script:COLOR_BORDER     = "#3F3F46"
 $script:COLOR_BORDER_LIT = "#555555"
 $script:COLOR_BTN_BG     = "#3F3F46"

 $script:ENCODINGS = [ordered]@{
    "UTF-8 (no BOM)"     = [System.Text.UTF8Encoding]::new($false)
    "UTF-8 (BOM)"        = [System.Text.UTF8Encoding]::new($true)
    "UTF-16 LE (BOM)"    = [System.Text.UnicodeEncoding]::new($false, $true)
    "UTF-16 BE (BOM)"    = [System.Text.UnicodeEncoding]::new($true, $true)
    "UTF-16 LE (no BOM)" = [System.Text.UnicodeEncoding]::new($false, $false)
    "UTF-16 BE (no BOM)" = [System.Text.UnicodeEncoding]::new($true, $false)
    "UTF-32 LE (BOM)"    = [System.Text.UTF32Encoding]::new($false, $true)
    "UTF-32 BE (BOM)"    = [System.Text.UTF32Encoding]::new($true, $true)
}

 $script:StatusUpdatePending = $false
 $script:AppIcon             = $null
 $script:BrushCache          = @{}
 $script:DarkButtonStyle     = $null
#endregion

#region ==================== ASSEMBLIES ====================
try {
    foreach ($asm in @("PresentationFramework","PresentationCore","WindowsBase")) {
        Add-Type -AssemblyName $asm -ErrorAction Stop
    }
} catch {
    $null = [System.Windows.MessageBox]::Show("Failed to load WPF assembly: $($_.Exception.Message)", "Fatal Error", "OK", "Error")
    exit 1
}
#endregion

#region ==================== WIN32 HELPERS ====================
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Helper {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHDefExtractIcon(string pszIconFile, int iIndex, uint uFlags, out IntPtr phiconLarge, out IntPtr phiconSmall, uint nIconSize);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr hIcon);
    public static IntPtr ExtractSized(string path, int index, int largeSize, int smallSize) {
        IntPtr hLarge, hSmall;
        uint packed = (uint)((smallSize << 16) | (largeSize & 0xFFFF));
        int hr = SHDefExtractIcon(path, index, 0, out hLarge, out hSmall, packed);
        if (hSmall != IntPtr.Zero) DestroyIcon(hSmall);
        if (hr == 0 && hLarge != IntPtr.Zero) return hLarge;
        return IntPtr.Zero;
    }
}
"@ -ErrorAction SilentlyContinue
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MaximizeHelper {
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool GetMonitorInfo(IntPtr hMonitor, IntPtr lpmi);
}
"@ -ErrorAction SilentlyContinue
} catch {}

function script:ExtractNotepadIcon {
    $paths = @("$env:SystemRoot\System32\notepad.exe", "$env:SystemRoot\notepad.exe", "${env:ProgramFiles}\Windows NT\Accessories\notepad.exe")
    foreach ($size in @(48, 64, 256, 32)) {
        foreach ($p in $paths) {
            if (-not (Test-Path $p -PathType Leaf)) { continue }
            try {
                $hIcon = [Win32Helper]::ExtractSized($p, 0, $size, 16)
                if ($hIcon -ne [IntPtr]::Zero) {
                    $bmp = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($hIcon, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                    [Win32Helper]::DestroyIcon($hIcon) | Out-Null
                    $bmp.Freeze(); return $bmp
                }
            } catch {}
        }
    }
    return $null
}
 $script:AppIcon = ExtractNotepadIcon

function script:ApplyIcon([System.Windows.Window]$w) {
    if ($null -ne $script:AppIcon -and $null -ne $w) { try { $w.Icon = $script:AppIcon } catch {} }
}
#endregion

#region ==================== STATE ====================
 $script:State = @{
    FilePath = ""; IsModified = $false; FindText = ""; FindCase = $false
    LineEnding = "CRLF"; Encoding = "UTF-8"; ZoomLevel = $script:DEF_ZOOM
    BaseFontSize = [double]$script:DEF_FONT_SIZE; BaseLineSpacing = [double]$script:DEF_SPACING
    SettingsDir = Join-Path $env:APPDATA $script:SETTINGS_FOLDER
    SettingsFile = Join-Path (Join-Path $env:APPDATA $script:SETTINGS_FOLDER) $script:SETTINGS_FILE
}
 $script:UI = @{}; $script:Settings = $null; $script:Window = $null; $script:EditorScrollViewer = $null

 $script:MinMaxInfoPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(40)
for ($i = 0; $i -lt 40; $i++) { [System.Runtime.InteropServices.Marshal]::WriteByte($script:MinMaxInfoPtr, $i, 0) }
[System.Runtime.InteropServices.Marshal]::WriteInt32($script:MinMaxInfoPtr, 0, 40)
#endregion

#region ==================== UTILITY ====================
function script:Clamp([double]$V, [double]$Lo, [double]$Hi) { if ([double]::IsNaN($V) -or [double]::IsInfinity($V)) { return $Lo }; return [Math]::Max($Lo, [Math]::Min($Hi, $V)) }
function script:ToDouble([string]$T, [double]$D) { if ([string]::IsNullOrWhiteSpace($T)) { return $D }; $r = 0.0; if ([double]::TryParse($T.Trim(), [ref]$r)) { return $r }; return $D }
function script:ToInt([string]$T, [int]$D) { if ([string]::IsNullOrWhiteSpace($T)) { return $D }; $r = 0; if ([int]::TryParse($T.Trim(), [ref]$r)) { return $r }; return $D }
function script:ToBool([string]$T, [bool]$D) { if ([string]::IsNullOrWhiteSpace($T)) { return $D }; switch ($T.Trim().ToLower()) { "true" { return $true } "1" { return $true } "false" { return $false } "0" { return $false } default { return $D } } }

function script:TestFont([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    try {
        foreach ($f in [System.Windows.Media.Fonts]::SystemFontFamilies) { if ($f.Source -eq $Name) { return $true } }
    } catch {}
    return $false
}

function script:GetBrush([string]$hex) {
    if (-not $script:BrushCache.ContainsKey($hex)) {
        try { $b = [System.Windows.Media.BrushConverter]::new().ConvertFrom($hex); $b.Freeze(); $script:BrushCache[$hex] = $b } catch { $script:BrushCache[$hex] = $null }
    }
    return $script:BrushCache[$hex]
}

function script:EolDisplayLabel([string]$Eol) { switch ($Eol) { "CRLF" { return "Windows (CRLF)" } "LF" { return "Unix (LF)" } "CR" { return "Macintosh (CR)" } default { return "Windows (CRLF)" } } }
function script:GetScrollViewer([System.Windows.DependencyObject]$d) { if ($null -eq $d) { return $null }; if ($d -is [System.Windows.Controls.ScrollViewer]) { return $d }; $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($d); for ($i = 0; $i -lt $count; $i++) { $r = GetScrollViewer ([System.Windows.Media.VisualTreeHelper]::GetChild($d, $i)); if ($null -ne $r) { return $r } }; return $null }

function script:GetDarkButtonStyle {
    if ($null -ne $script:DarkButtonStyle) { return $script:DarkButtonStyle }
    $xaml = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
    <Setter Property="Background" Value="#3F3F46"/><Setter Property="Foreground" Value="#D4D4D4"/><Setter Property="BorderBrush" Value="#555555"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="6,0"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" TextBlock.Foreground="{TemplateBinding Foreground}" Margin="{TemplateBinding Padding}"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#505057"/><Setter TargetName="bd" Property="BorderBrush" Value="#6A6A72"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#2D2D30"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
</Style>
"@
    $script:DarkButtonStyle = [System.Windows.Markup.XamlReader]::Parse($xaml); return $script:DarkButtonStyle
}

function script:ApplyDarkControlTheme { param($Control); $Control.Background = GetBrush $script:COLOR_EDITOR_BG; $Control.Foreground = GetBrush $script:COLOR_EDITOR_FG; $Control.BorderBrush = GetBrush $script:COLOR_BORDER_LIT; if ($Control -is [System.Windows.Controls.TextBox]) { $Control.CaretBrush = GetBrush $script:COLOR_EDITOR_FG } }
function script:NewDarkTextBox { $tb = [System.Windows.Controls.TextBox]::new(); $tb.Height = 26; $tb.VerticalContentAlignment = "Center"; ApplyDarkControlTheme $tb; return $tb }
function script:NewDarkButton([string]$Text, [double]$W = 90, [double]$H = 28) { $b = [System.Windows.Controls.Button]::new(); $b.Content = $Text; $b.Width = $W; $b.Height = $H; $b.Background = GetBrush $script:COLOR_BTN_BG; $b.Foreground = GetBrush $script:COLOR_EDITOR_FG; $b.BorderBrush = GetBrush $script:COLOR_BORDER_LIT; $b.Style = (GetDarkButtonStyle); return $b }

function script:BuildDarkDialog([System.Windows.Window]$d, [System.Windows.FrameworkElement]$content) {
    $d.WindowStyle = "None"; $d.ResizeMode = "NoResize"; $d.ShowInTaskbar = $false; ApplyIcon $d
    $chrome = [System.Windows.Shell.WindowChrome]::new(); $chrome.CaptionHeight = 32; $chrome.CornerRadius = [System.Windows.CornerRadius]::new(0); $chrome.GlassFrameThickness = [System.Windows.Thickness]::new(0); $chrome.UseAeroCaptionButtons = $false
    [System.Windows.Shell.WindowChrome]::SetWindowChrome($d, $chrome)
    
    $mainBorder = [System.Windows.Controls.Border]::new(); $mainBorder.BorderBrush = GetBrush $script:COLOR_BORDER; $mainBorder.BorderThickness = [System.Windows.Thickness]::new(1); $mainBorder.Background = GetBrush $script:COLOR_CHROME
    $root = [System.Windows.Controls.Grid]::new()
    $r0 = [System.Windows.Controls.RowDefinition]::new(); $r0.Height = [System.Windows.GridLength]::new(32)
    $r1 = [System.Windows.Controls.RowDefinition]::new(); $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $null = $root.RowDefinitions.Add($r0); $null = $root.RowDefinitions.Add($r1)
    
    $tb = [System.Windows.Controls.Grid]::new(); $tb.Background = GetBrush $script:COLOR_EDITOR_BG; [System.Windows.Controls.Grid]::SetRow($tb, 0)
    $lbl = [System.Windows.Controls.TextBlock]::new(); $lbl.Text = $d.Title; $lbl.Foreground = GetBrush $script:COLOR_EDITOR_FG; $lbl.VerticalAlignment = "Center"; $lbl.Margin = [System.Windows.Thickness]::new(10,0,0,0)
    $null = $tb.Children.Add($lbl)
    
    $btnClose = [System.Windows.Controls.Button]::new(); $btnClose.Content = "✕"; $btnClose.Width = 46; $btnClose.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI"); $btnClose.HorizontalAlignment = "Right"; $btnClose.Style = $script:Window.FindResource("TitleBarCloseButton")
    [System.Windows.Shell.WindowChrome]::SetIsHitTestVisibleInChrome($btnClose, $true); $btnClose.Add_Click({ $d.Close() })
    $null = $tb.Children.Add($btnClose); $null = $root.Children.Add($tb)
    
    [System.Windows.Controls.Grid]::SetRow($content, 1); $null = $root.Children.Add($content)
    $mainBorder.Child = $root; $d.Content = $mainBorder
}
#endregion

#region ==================== ENCODING DETECTION ====================
function script:DetectEncoding([string]$FilePath) {
    $fallback = @{ Encoding = [System.Text.UTF8Encoding]::new($false); Name = "UTF-8"; BOM = $false }
    $maxBytes = 8192; $bytes = New-Object byte[] $maxBytes; $len = 0
    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
        $len = $fs.Read($bytes, 0, $maxBytes)
    } catch { return $fallback }
    finally { if ($null -ne $fs) { $fs.Dispose() } }

    if ($len -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) { return @{ Encoding = [System.Text.UTF32Encoding]::new($true, $true);  Name = "UTF-32 BE (BOM)"; BOM = $true } }
    if ($len -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) { return @{ Encoding = [System.Text.UTF32Encoding]::new($false, $true); Name = "UTF-32 LE (BOM)"; BOM = $true } }
    if ($len -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return @{ Encoding = [System.Text.UTF8Encoding]::new($true);  Name = "UTF-8 (BOM)";  BOM = $true } }
    if ($len -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($true, $true);  Name = "UTF-16 BE (BOM)"; BOM = $true } }
    if ($len -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($false, $true); Name = "UTF-16 LE (BOM)"; BOM = $true } }

    if ($len -ge 2) {
        $nullOdd = 0; $nullEven = 0; $check = [Math]::Min($len, 4096)
        for ($i = 0; $i -lt $check; $i++) { if ($bytes[$i] -eq 0x00) { if (($i % 2) -eq 0) { $nullEven++ } else { $nullOdd++ } } }
        $halfCheck = $check / 4
        if ($nullOdd -gt $halfCheck -and $nullEven -lt ($halfCheck / 4)) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($false, $false); Name = "UTF-16 LE (no BOM)"; BOM = $false } }
        if ($nullEven -gt $halfCheck -and $nullOdd -lt ($halfCheck / 4)) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($true, $false);  Name = "UTF-16 BE (no BOM)"; BOM = $false } }
    }

    $isValidUtf8 = $true; $i = 0; $check = [Math]::Min($len, 8192)
    while ($i -lt $check) {
        $b = $bytes[$i]; if ($b -le 0x7F) { $i++; continue }
        if (($b -band 0xE0) -eq 0xC0) { $seq = 1 } elseif (($b -band 0xF0) -eq 0xE0) { $seq = 2 } elseif (($b -band 0xF8) -eq 0xF0) { $seq = 3 } else { $isValidUtf8 = $false; break }
        for ($j = 0; $j -lt $seq; $j++) { $i++; if ($i -ge $check -or ($bytes[$i] -band 0xC0) -ne 0x80) { $isValidUtf8 = $false; break } }
        if (-not $isValidUtf8) { break }; $i++
    }
    return @{ Encoding = [System.Text.UTF8Encoding]::new($false); Name = "UTF-8"; BOM = $false }
}

function script:DetectLineEnding([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return "CRLF" }
    $crlf = ($Text.Length - $Text.Replace("`r`n", "").Length) / 2
    $lf = ($Text.Length - $Text.Replace("`n", "").Length) - $crlf
    $cr = ($Text.Length - $Text.Replace("`r", "").Length) - $crlf
    if ($crlf -ge $lf -and $crlf -ge $cr) { return "CRLF" }
    if ($lf   -gt $crlf -and $lf -ge $cr) { return "LF"   }
    if ($cr   -gt 0)                      { return "CR"   }
    return "CRLF"
}

function script:ConvertLineEndings([string]$Text, [string]$Target) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $norm = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    switch ($Target) { "CRLF" { return $norm.Replace("`n", "`r`n") } "LF" { return $norm } "CR" { return $norm.Replace("`n", "`r") } default { return $norm.Replace("`n", "`r`n") } }
}
#endregion

#region ==================== SETTINGS ====================
function script:DefaultSettings { @{ Window = @{ Width = "$script:DEF_WINDOW_W"; Height = "$script:DEF_WINDOW_H" }; Font = @{ Family = $script:DEF_FONT_FAMILY; Size = "$script:DEF_FONT_SIZE" }; View = @{ WordWrap = "False"; StatusBar = "True" }; Editor = @{ MarginLeft = "$script:DEF_MARGIN"; MarginRight = "$script:DEF_MARGIN"; LineSpacing = $script:DEF_SPACING.ToString("F1") } } }
function script:EnsureSettingsDir { try { if (-not (Test-Path $script:State.SettingsDir -PathType Container)) { $null = New-Item -Path $script:State.SettingsDir -ItemType Directory -Force -ErrorAction Stop }; return $true } catch { return $false } }
function script:ReadIni([string]$Path, [hashtable]$Defaults) {
    $out = @{}; foreach ($s in $Defaults.Keys) { $out[$s] = @{}; foreach ($k in $Defaults[$s].Keys) { $out[$s][$k] = $Defaults[$s][$k] } }
    try { if (-not (Test-Path $Path -PathType Leaf)) { return $out }; $sec = ""; foreach ($raw in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) { $line = $raw.Trim(); if ($line.Length -eq 0 -or $line[0] -eq '#' -or $line[0] -eq ';') { continue }; if ($line[0] -eq '[' -and $line[-1] -eq ']') { $sec = $line.Substring(1,$line.Length-2).Trim(); if (-not $out.ContainsKey($sec)) { $out[$sec] = @{} }; continue }; $eq = $line.IndexOf('='); if ($eq -gt 0 -and $sec.Length -gt 0) { $k = $line.Substring(0,$eq).Trim(); $v = $line.Substring($eq+1).Trim(); if ($out.ContainsKey($sec) -and $k.Length -gt 0) { $out[$sec][$k] = $v } } } } catch {}
    return $out
}
function script:WriteIni([string]$Path, [hashtable]$Data) {
    if (-not (EnsureSettingsDir)) { return $false }
    try { $sb = [System.Text.StringBuilder]::new(512); $null = $sb.AppendLine("# $script:APP_NAME Settings v$script:APP_VERSION`n# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"); foreach ($sec in $Data.Keys) { $null = $sb.AppendLine("[$sec]"); foreach ($k in ($Data[$sec].Keys | Sort-Object)) { $null = $sb.AppendLine("$k=$($Data[$sec][$k])") }; $null = $sb.AppendLine() }; [System.IO.File]::WriteAllText($Path, $sb.ToString().TrimEnd(), [System.Text.Encoding]::UTF8); return $true } catch { return $false }
}
function script:LoadSettings { return (ReadIni $script:State.SettingsFile (DefaultSettings)) }
function script:SaveSettings {
    try {
        $rb = $script:Window.RestoreBounds; $w = [int]$rb.Width; $h = [int]$rb.Height
        if ($w -le 0) { $w = [int]$script:Window.ActualWidth }; if ($h -le 0) { $h = [int]$script:Window.ActualHeight }
        $script:Settings.Window.Width = "$w"; $script:Settings.Window.Height = "$h"
        $script:Settings.Font.Family = $script:UI.txtEditor.FontFamily.Source; $script:Settings.Font.Size = "$([int]$script:State.BaseFontSize)"
        $script:Settings.View.WordWrap = $script:UI.mnuWordWrap.IsChecked.ToString(); $script:Settings.View.StatusBar = $script:UI.mnuStatusBar.IsChecked.ToString()
        $script:Settings.Editor.MarginLeft = "$([int]$script:UI.txtEditor.Margin.Left)"; $script:Settings.Editor.MarginRight = "$([int]$script:UI.txtEditor.Margin.Right)"; $script:Settings.Editor.LineSpacing = $script:State.BaseLineSpacing.ToString("F1")
        $null = WriteIni $script:State.SettingsFile $script:Settings
    } catch {}
}
 $null = EnsureSettingsDir; $script:Settings = LoadSettings
#endregion

#region ==================== LINE SPACING & ZOOM ====================
function script:ApplyLineSpacingToEditor { try { $sp = Clamp $script:State.BaseLineSpacing $script:MIN_SPACING $script:MAX_SPACING; $cfs = $script:UI.txtEditor.FontSize; if ($cfs -le 0) { return }; $lh = [Math]::Max(1.0, [double]($cfs * $sp)); $script:UI.txtEditor.SetValue([System.Windows.Controls.TextBlock]::LineHeightProperty, $lh); $script:UI.txtEditor.SetValue([System.Windows.Controls.TextBlock]::LineStackingStrategyProperty, [System.Windows.LineStackingStrategy]::BlockLineHeight) } catch {} }
function script:UpdateZoomMenuState { try { $script:UI.mnuZoomReset.IsEnabled = ($script:State.ZoomLevel -ne $script:DEF_ZOOM) } catch {} }
function script:ApplyZoom { $factor = [double]$script:State.ZoomLevel / 100.0; $script:UI.txtEditor.FontSize = Clamp ([double]$script:State.BaseFontSize * $factor) $script:ZOOM_FONT_MIN $script:ZOOM_FONT_MAX; ApplyLineSpacingToEditor; try { $script:UI.txtZoom.Text = "$($script:State.ZoomLevel)%" } catch {}; UpdateZoomMenuState }
function script:ZoomIn { $script:State.ZoomLevel = [Math]::Min($script:MAX_ZOOM, $script:State.ZoomLevel + $script:ZOOM_STEP); ApplyZoom }
function script:ZoomOut { $script:State.ZoomLevel = [Math]::Max($script:MIN_ZOOM, $script:State.ZoomLevel - $script:ZOOM_STEP); ApplyZoom }
function script:ZoomReset { if ($script:State.ZoomLevel -eq $script:DEF_ZOOM) { return }; $script:State.ZoomLevel = $script:DEF_ZOOM; ApplyZoom }
#endregion

#region ==================== XAML ====================
[xml]$script:Xaml = @"
<Window x:Name="mainWindow" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Untitled - Notepad" WindowStartupLocation="CenterScreen" MinWidth="$script:MIN_WINDOW_W" MinHeight="$script:MIN_WINDOW_H" Background="$script:COLOR_CHROME">
    <WindowChrome.WindowChrome><WindowChrome CaptionHeight="32" ResizeBorderThickness="6" CornerRadius="0" GlassFrameThickness="0" UseAeroCaptionButtons="False"/></WindowChrome.WindowChrome>
    <Window.Resources>
        <!-- FIX: Restored custom ScrollViewer template to explicitly paint the lower-right scrollbar intersection corner dark -->
        <Style TargetType="ScrollViewer">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollViewer">
                        <Grid Background="{TemplateBinding Background}">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <ScrollContentPresenter x:Name="PART_ScrollContentPresenter" Grid.Column="0" Grid.Row="0" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" CanContentScroll="{TemplateBinding CanContentScroll}" Margin="{TemplateBinding Padding}" />
                            <ScrollBar x:Name="PART_VerticalScrollBar" Grid.Column="1" Grid.Row="0" Value="{TemplateBinding VerticalOffset}" Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}" Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
                            <ScrollBar x:Name="PART_HorizontalScrollBar" Grid.Column="0" Grid.Row="1" Orientation="Horizontal" Value="{TemplateBinding HorizontalOffset}" Maximum="{TemplateBinding ScrollableWidth}" ViewportSize="{TemplateBinding ViewportWidth}" Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"/>
                            <Rectangle Grid.Column="1" Grid.Row="1" Fill="#1E1E1E"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollBarThumb" TargetType="Thumb"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb"><Border Background="#4D4D4D" BorderBrush="#1E1E1E" BorderThickness="1"/></ControlTemplate></Setter.Value></Setter></Style>
        <Style x:Key="ScrollBarButton" TargetType="RepeatButton"><Setter Property="Background" Value="#1E1E1E"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter></Style>
        <Style x:Key="ScrollBarPageButton" TargetType="RepeatButton"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter></Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="#1E1E1E"/><Setter Property="Width" Value="17"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="{TemplateBinding Background}"><Grid.RowDefinitions><RowDefinition Height="17"/><RowDefinition Height="0.00001*"/><RowDefinition Height="17"/></Grid.RowDefinitions><RepeatButton Grid.Row="0" Style="{StaticResource ScrollBarButton}" Command="ScrollBar.LineUpCommand"><Path Data="M 2,5 L 5,2 L 8,5" Stroke="#999999" StrokeThickness="1.5"/></RepeatButton><Track x:Name="PART_Track" Grid.Row="1" IsDirectionReversed="true"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource ScrollBarPageButton}"/></Track.DecreaseRepeatButton><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource ScrollBarPageButton}"/></Track.IncreaseRepeatButton><Track.Thumb><Thumb Style="{StaticResource ScrollBarThumb}"/></Track.Thumb></Track><RepeatButton Grid.Row="2" Style="{StaticResource ScrollBarButton}" Command="ScrollBar.LineDownCommand"><Path Data="M 2,2 L 5,5 L 8,2" Stroke="#999999" StrokeThickness="1.5"/></RepeatButton></Grid></ControlTemplate></Setter.Value></Setter>
            <Style.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="17"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="{TemplateBinding Background}"><Grid.ColumnDefinitions><ColumnDefinition Width="17"/><ColumnDefinition Width="0.00001*"/><ColumnDefinition Width="17"/></Grid.ColumnDefinitions><RepeatButton Grid.Column="0" Style="{StaticResource ScrollBarButton}" Command="ScrollBar.LineLeftCommand"><Path Data="M 5,2 L 2,5 L 5,8" Stroke="#999999" StrokeThickness="1.5"/></RepeatButton><Track x:Name="PART_Track" Grid.Column="1" IsDirectionReversed="False"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Style="{StaticResource ScrollBarPageButton}"/></Track.DecreaseRepeatButton><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Style="{StaticResource ScrollBarPageButton}"/></Track.IncreaseRepeatButton><Track.Thumb><Thumb Style="{StaticResource ScrollBarThumb}"/></Track.Thumb></Track><RepeatButton Grid.Column="2" Style="{StaticResource ScrollBarButton}" Command="ScrollBar.LineRightCommand"><Path Data="M 2,2 L 5,5 L 2,8" Stroke="#999999" StrokeThickness="1.5"/></RepeatButton></Grid></ControlTemplate></Setter.Value></Setter></Trigger></Style.Triggers>
        </Style>
        <Style TargetType="Menu"><Setter Property="Background" Value="#2D2D30"/><Setter Property="Foreground" Value="#D4D4D4"/></Style>
        <Style TargetType="ContextMenu"><Setter Property="SnapsToDevicePixels" Value="True"/><Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContextMenu"><Border Background="#2D2D30" BorderBrush="#3F3F46" BorderThickness="1" Padding="0,2"><ItemsPresenter Grid.IsSharedSizeScope="True" KeyboardNavigation.DirectionalNavigation="Cycle"/></Border></ControlTemplate></Setter.Value></Setter></Style>
        <Style TargetType="Separator"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Separator"><Rectangle Height="1" Fill="#3F3F46" Margin="25,3,5,3"/></ControlTemplate></Setter.Value></Setter></Style>
        <ControlTemplate x:Key="TopLevelHeaderTemplate" TargetType="MenuItem"><Border x:Name="Border" Background="Transparent" SnapsToDevicePixels="True"><Grid><ContentPresenter Margin="{TemplateBinding Padding}" RecognizesAccessKey="True" ContentSource="Header" VerticalAlignment="Center"/><Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsSubmenuOpen}" AllowsTransparency="True" Focusable="False"><Border Background="#2D2D30" BorderBrush="#3F3F46" BorderThickness="1"><ItemsPresenter Grid.IsSharedSizeScope="True" KeyboardNavigation.DirectionalNavigation="Cycle" Margin="0,2"/></Border></Popup></Grid></Border><ControlTemplate.Triggers><Trigger Property="IsSubmenuOpen" Value="True"><Setter Property="Background" TargetName="Border" Value="#3E3E42"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger><Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" TargetName="Border" Value="#3E3E42"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></ControlTemplate.Triggers></ControlTemplate>
        <ControlTemplate x:Key="SubmenuItemTemplate" TargetType="MenuItem"><Border x:Name="Border" Background="{TemplateBinding Background}" SnapsToDevicePixels="True"><Grid><Grid.ColumnDefinitions><ColumnDefinition x:Name="Col0" MinWidth="25" Width="Auto" SharedSizeGroup="MenuItemIconColumnGroup"/><ColumnDefinition Width="Auto" SharedSizeGroup="MenuTextColumnGroup"/><ColumnDefinition Width="Auto" SharedSizeGroup="MenuItemIGTColumnGroup"/><ColumnDefinition x:Name="Col3" Width="15"/></Grid.ColumnDefinitions><ContentPresenter Grid.Column="0" x:Name="Icon" Margin="5,0" VerticalAlignment="Center" ContentSource="Icon"/><Path x:Name="CheckMark" Visibility="Hidden" Grid.Column="0" Margin="5,0" VerticalAlignment="Center" HorizontalAlignment="Center" Data="M 0,4 L 3,7 L 8,0" Stroke="#D4D4D4" StrokeThickness="2"/><ContentPresenter Grid.Column="1" x:Name="HeaderHost" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True" ContentSource="Header" VerticalAlignment="Center"/><TextBlock Grid.Column="2" x:Name="InputGestureText" Margin="20,0,10,0" Text="{TemplateBinding InputGestureText}" VerticalAlignment="Center" Foreground="#888888"/><Path Grid.Column="3" x:Name="RightArrow" Visibility="Hidden" Margin="0,0,5,0" VerticalAlignment="Center" HorizontalAlignment="Right" Data="M 0,0 L 4,3 L 0,6 Z" Fill="#D4D4D4"/><Popup x:Name="Popup" Placement="Right" HorizontalOffset="0" VerticalOffset="-2" IsOpen="{TemplateBinding IsSubmenuOpen}" AllowsTransparency="True" Focusable="False"><Border x:Name="SubmenuBorder" Background="#2D2D30" BorderBrush="#3F3F46" BorderThickness="1"><ItemsPresenter Grid.IsSharedSizeScope="True" KeyboardNavigation.DirectionalNavigation="Cycle" Margin="0,2"/></Border></Popup></Grid></Border><ControlTemplate.Triggers><Trigger Property="Role" Value="SubmenuHeader"><Setter TargetName="RightArrow" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="IsChecked" Value="True"><Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#666666"/></Trigger><MultiTrigger><MultiTrigger.Conditions><Condition Property="IsHighlighted" Value="True"/><Condition Property="IsEnabled" Value="True"/></MultiTrigger.Conditions><Setter Property="Background" TargetName="Border" Value="#3E3E42"/><Setter Property="Foreground" Value="#FFFFFF"/></MultiTrigger></ControlTemplate.Triggers></ControlTemplate>
        <Style TargetType="MenuItem"><Setter Property="Background" Value="#2D2D30"/><Setter Property="Foreground" Value="#D4D4D4"/><Setter Property="Padding" Value="5,3"/><Setter Property="Template" Value="{StaticResource SubmenuItemTemplate}"/><Style.Triggers><Trigger Property="Role" Value="TopLevelHeader"><Setter Property="Template" Value="{StaticResource TopLevelHeaderTemplate}"/><Setter Property="Padding" Value="8,4"/></Trigger><Trigger Property="Role" Value="TopLevelItem"><Setter Property="Template" Value="{StaticResource TopLevelHeaderTemplate}"/><Setter Property="Padding" Value="8,4"/></Trigger></Style.Triggers></Style>
        <Style x:Key="TitleBarButton" TargetType="Button"><Setter Property="Background" Value="#1E1E1E"/><Setter Property="Foreground" Value="#D4D4D4"/><Setter Property="Width" Value="46"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#3E3E42"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
        <Style x:Key="TitleBarCloseButton" TargetType="Button" BasedOn="{StaticResource TitleBarButton}"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#E81123"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
        <Style x:Key="SBText" TargetType="TextBlock"><Setter Property="FontSize" Value="11"/><Setter Property="Foreground" Value="#999999"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
        <Style x:Key="SBSep" TargetType="Rectangle"><Setter Property="Width" Value="1"/><Setter Property="Height" Value="14"/><Setter Property="Fill" Value="#555555"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    </Window.Resources>
    <Grid x:Name="RootGrid">
        <Grid.Style><Style TargetType="Grid"><Style.Triggers><DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType=Window}}" Value="Maximized"><Setter Property="Margin" Value="6"/></DataTrigger></Style.Triggers></Style></Grid.Style>
        <Grid.RowDefinitions><RowDefinition Height="32"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid Grid.Row="0" Background="#1E1E1E"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Viewbox Grid.Column="0" Width="14" Height="14" Margin="10,0,5,0" VerticalAlignment="Center"><Canvas Width="16" Height="16"><Path Data="M2,0 L10,0 L14,4 L14,16 L2,16 Z" Stroke="#D4D4D4" StrokeThickness="1.5" Fill="Transparent"/><Path Data="M10,0 L10,4 L14,4" Stroke="#D4D4D4" StrokeThickness="1.5" Fill="Transparent"/><Path Data="M4,7 L10,7 M4,10 L12,10 M4,13 L9,13" Stroke="#D4D4D4" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas></Viewbox>
            <TextBlock Name="txtWindowTitle" Grid.Column="1" Text="Untitled - Notepad" Foreground="#D4D4D4" VerticalAlignment="Center" Margin="5,0,0,0" FontSize="12"/>
            <StackPanel Grid.Column="2" Orientation="Horizontal" WindowChrome.IsHitTestVisibleInChrome="True">
                <Button Name="btnMin" Style="{StaticResource TitleBarButton}"><Path Data="M 0.5,5.5 L 9.5,5.5" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1" SnapsToDevicePixels="True"/></Button>
                <Button Name="btnMax" Style="{StaticResource TitleBarButton}"><Grid Width="12" Height="12"><Path Data="M 0.5,0.5 L 9.5,0.5 L 9.5,9.5 L 0.5,9.5 Z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1" Fill="Transparent" SnapsToDevicePixels="True"><Path.Style><Style TargetType="Path"><Setter Property="Visibility" Value="Visible"/><Style.Triggers><DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType=Window}}" Value="Maximized"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers></Style></Path.Style></Path><Grid><Grid.Style><Style TargetType="Grid"><Setter Property="Visibility" Value="Collapsed"/><Style.Triggers><DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType=Window}}" Value="Maximized"><Setter Property="Visibility" Value="Visible"/></DataTrigger></Style.Triggers></Style></Grid.Style><Path Data="M 0.5,0.5 L 7.5,0.5 L 7.5,7.5 L 0.5,7.5 Z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1" Fill="Transparent" SnapsToDevicePixels="True" Margin="3,0,0,3"/><Path Data="M 0.5,0.5 L 7.5,0.5 L 7.5,7.5 L 0.5,7.5 Z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1" Fill="{Binding Background, RelativeSource={RelativeSource AncestorType=Button}}" SnapsToDevicePixels="True" Margin="0,3,3,0"/></Grid></Grid></Button>
                <Button Name="btnClose" Style="{StaticResource TitleBarCloseButton}"><Path Data="M 0.5,0.5 L 9.5,9.5 M 0.5,9.5 L 9.5,0.5" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.2" SnapsToDevicePixels="True"/></Button>
            </StackPanel>
        </Grid>
        <Border Grid.Row="1" BorderBrush="#3F3F46" BorderThickness="0,0,0,1"><Menu Name="menuBar" Padding="4,0,0,0">
            <MenuItem Header="_File"><MenuItem Header="_New" Name="mnuNew" InputGestureText="Ctrl+N"/><MenuItem Header="_Open..." Name="mnuOpen" InputGestureText="Ctrl+O"/><MenuItem Header="_Save" Name="mnuSave" InputGestureText="Ctrl+S"/><MenuItem Header="Save _As..." Name="mnuSaveAs" InputGestureText="Ctrl+Shift+S"/><Separator/><MenuItem Header="E_xit" Name="mnuExit" InputGestureText="Alt+F4"/></MenuItem>
            <MenuItem Header="_Edit"><MenuItem Header="_Undo" Name="mnuUndo" InputGestureText="Ctrl+Z"/><MenuItem Header="_Redo" Name="mnuRedo" InputGestureText="Ctrl+Y"/><Separator/><MenuItem Header="Cu_t" Name="mnuCut" InputGestureText="Ctrl+X"/><MenuItem Header="_Copy" Name="mnuCopy" InputGestureText="Ctrl+C"/><MenuItem Header="_Paste" Name="mnuPaste" InputGestureText="Ctrl+V"/><MenuItem Header="De_lete" Name="mnuDelete" InputGestureText="Del"/><Separator/><MenuItem Header="_Find..." Name="mnuFind" InputGestureText="Ctrl+F"/><MenuItem Header="Find _Next" Name="mnuFindNext" InputGestureText="F3"/><MenuItem Header="_Replace..." Name="mnuReplace" InputGestureText="Ctrl+H"/><Separator/><MenuItem Header="Select _All" Name="mnuSelAll" InputGestureText="Ctrl+A"/><MenuItem Header="Time/_Date" Name="mnuDate" InputGestureText="F5"/></MenuItem>
            <MenuItem Header="F_ormat"><MenuItem Header="_Word Wrap" Name="mnuWordWrap" IsCheckable="True"/><MenuItem Header="_Font..." Name="mnuFont"/><Separator/><MenuItem Header="_Zoom"><MenuItem Header="Zoom _In" Name="mnuZoomIn" InputGestureText="Ctrl++"/><MenuItem Header="Zoom _Out" Name="mnuZoomOut" InputGestureText="Ctrl+-"/><MenuItem Header="_Reset (100%)" Name="mnuZoomReset" InputGestureText="Ctrl+0"/></MenuItem><Separator/><MenuItem Header="_Line Endings" Name="mnuLineEndings"><MenuItem Header="Windows (CRLF)" Name="mnuEolCRLF" ToolTip="Carriage Return + Line Feed."/><MenuItem Header="Unix (LF)" Name="mnuEolLF" ToolTip="Line Feed only."/><MenuItem Header="Macintosh (CR)" Name="mnuEolCR" ToolTip="Carriage Return only."/></MenuItem><MenuItem Header="_Encoding" Name="mnuEncoding"><MenuItem Header="UTF-8 (no BOM)" Name="mnuEncUtf8"/><MenuItem Header="UTF-8 (BOM)" Name="mnuEncUtf8Bom"/><Separator/><MenuItem Header="UTF-16 LE (BOM)" Name="mnuEncUtf16LE"/><MenuItem Header="UTF-16 BE (BOM)" Name="mnuEncUtf16BE"/></MenuItem><Separator/><MenuItem Header="_Editor Settings..." Name="mnuEditorCfg"/></MenuItem>
            <MenuItem Header="_View"><MenuItem Header="_Status Bar" Name="mnuStatusBar" IsCheckable="True" IsChecked="True"/></MenuItem>
        </Menu></Border>
        <Border Grid.Row="2" Background="$script:COLOR_CHROME">
            <TextBox Name="txtEditor" AcceptsReturn="True" AcceptsTab="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" BorderThickness="0" Background="$script:COLOR_EDITOR_BG" Foreground="$script:COLOR_EDITOR_FG" Padding="12,10" UndoLimit="100" IsUndoEnabled="True" CaretBrush="$script:COLOR_EDITOR_FG" ScrollViewer.CanContentScroll="False">
                <TextBox.ContextMenu><ContextMenu FontFamily="Segoe UI" FontSize="12"><MenuItem Name="ctxCut" Header="Cu_t" InputGestureText="Ctrl+X"/><MenuItem Name="ctxCopy" Header="_Copy" InputGestureText="Ctrl+C"/><MenuItem Name="ctxPaste" Header="_Paste" InputGestureText="Ctrl+V"/><Separator/><MenuItem Name="ctxSelAll" Header="Select _All" InputGestureText="Ctrl+A"/></ContextMenu></TextBox.ContextMenu>
            </TextBox>
        </Border>
        <Border Grid.Row="3" Name="statusBorder" BorderBrush="#3F3F46" BorderThickness="0,1,0,0"><Border BorderBrush="#1E1E1E" BorderThickness="0,1,0,0"><StatusBar Name="statusBar" Background="#2D2D30" Foreground="#D4D4D4" Padding="6,1" Height="22">
            <StatusBar.ItemsPanel><ItemsPanelTemplate><DockPanel LastChildFill="False"/></ItemsPanelTemplate></StatusBar.ItemsPanel>
            <StatusBarItem DockPanel.Dock="Right" Padding="8,0"><TextBlock Name="txtEnc" Text="UTF-8" Style="{StaticResource SBText}"/></StatusBarItem><StatusBarItem DockPanel.Dock="Right" Padding="0"><Rectangle Style="{StaticResource SBSep}"/></StatusBarItem>
            <StatusBarItem DockPanel.Dock="Right" Padding="8,0"><TextBlock Name="txtEol" Text="Windows (CRLF)" Style="{StaticResource SBText}"/></StatusBarItem><StatusBarItem DockPanel.Dock="Right" Padding="0"><Rectangle Style="{StaticResource SBSep}"/></StatusBarItem>
            <StatusBarItem DockPanel.Dock="Right" Padding="8,0"><TextBlock Name="txtZoom" Text="100%" Style="{StaticResource SBText}"/></StatusBarItem><StatusBarItem DockPanel.Dock="Right" Padding="0"><Rectangle Style="{StaticResource SBSep}"/></StatusBarItem>
            <StatusBarItem DockPanel.Dock="Right" Padding="8,0"><TextBlock Name="txtLines" Text="Lines: 1" Style="{StaticResource SBText}"/></StatusBarItem><StatusBarItem DockPanel.Dock="Right" Padding="0"><Rectangle Style="{StaticResource SBSep}"/></StatusBarItem>
            <StatusBarItem DockPanel.Dock="Right" Padding="8,0"><TextBlock Name="txtChars" Text="Chars: 0" Style="{StaticResource SBText}"/></StatusBarItem><StatusBarItem DockPanel.Dock="Right" Padding="0"><Rectangle Style="{StaticResource SBSep}"/></StatusBarItem>
            <StatusBarItem DockPanel.Dock="Right" Padding="8,0"><TextBlock Name="txtWords" Text="Words: 0" Style="{StaticResource SBText}"/></StatusBarItem><StatusBarItem DockPanel.Dock="Right" Padding="0"><Rectangle Style="{StaticResource SBSep}"/></StatusBarItem>
            <StatusBarItem DockPanel.Dock="Right" Padding="8,0,10,0"><TextBlock Name="txtPos" Text="Ln 1, Col 1" Style="{StaticResource SBText}"/></StatusBarItem>
        </StatusBar></Border></Border>
    </Grid>
</Window>
"@
#endregion

#region ==================== INIT WINDOW & TIMERS ====================
try { $reader = [System.Xml.XmlNodeReader]::new($script:Xaml); $script:Window = [System.Windows.Markup.XamlReader]::Load($reader); $reader.Dispose() } catch { exit 1 }
ApplyIcon $script:Window
 $script:ControlNames = @("RootGrid","txtEditor","txtPos","txtWords","txtChars","txtLines","txtEnc","txtEol","txtZoom","statusBar","statusBorder","menuBar","mnuNew","mnuOpen","mnuSave","mnuSaveAs","mnuExit","mnuUndo","mnuRedo","mnuCut","mnuCopy","mnuPaste","mnuDelete","mnuFind","mnuFindNext","mnuReplace","mnuSelAll","mnuDate","mnuWordWrap","mnuFont","mnuEditorCfg","mnuStatusBar","mnuZoomIn","mnuZoomOut","mnuZoomReset","mnuLineEndings","mnuEolCRLF","mnuEolLF","mnuEolCR","mnuEncoding","mnuEncUtf8","mnuEncUtf8Bom","mnuEncUtf16LE","mnuEncUtf16BE","txtWindowTitle","btnMin","btnMax","btnClose","ctxCut","ctxCopy","ctxPaste","ctxSelAll")
foreach ($n in $script:ControlNames) { $script:UI[$n] = $script:Window.FindName($n) }

try {
    $script:Window.Width = Clamp (ToDouble $script:Settings.Window.Width $script:DEF_WINDOW_W) $script:MIN_WINDOW_W $script:MAX_WINDOW_W
    $script:Window.Height = Clamp (ToDouble $script:Settings.Window.Height $script:DEF_WINDOW_H) $script:MIN_WINDOW_H $script:MAX_WINDOW_H
    $fam = if (TestFont $script:Settings.Font.Family) { $script:Settings.Font.Family } else { $script:DEF_FONT_FAMILY }
    $script:UI.txtEditor.FontFamily = [System.Windows.Media.FontFamily]::new($fam)
    $fsize = Clamp (ToDouble $script:Settings.Font.Size $script:DEF_FONT_SIZE) $script:MIN_FONT $script:MAX_FONT
    $script:State.BaseFontSize = [double]$fsize; $script:UI.txtEditor.FontSize = [double]$fsize
    $script:UI.txtEditor.Margin = [System.Windows.Thickness]::new((Clamp (ToDouble $script:Settings.Editor.MarginLeft $script:DEF_MARGIN) $script:MIN_MARGIN $script:MAX_MARGIN),0,(Clamp (ToDouble $script:Settings.Editor.MarginRight $script:DEF_MARGIN) $script:MIN_MARGIN $script:MAX_MARGIN),0)
    $script:State.BaseLineSpacing = [double](Clamp (ToDouble $script:Settings.Editor.LineSpacing $script:DEF_SPACING) $script:MIN_SPACING $script:MAX_SPACING); ApplyLineSpacingToEditor
    $script:UI.mnuWordWrap.IsChecked = ToBool $script:Settings.View.WordWrap $false
    $script:UI.mnuStatusBar.IsChecked = ToBool $script:Settings.View.StatusBar $true
} catch {}

 $script:LightStatusTimer = [System.Windows.Threading.DispatcherTimer]::new()
 $script:LightStatusTimer.Interval = [TimeSpan]::FromMilliseconds(50)
 $script:LightStatusTimer.Add_Tick({
    $script:LightStatusTimer.Stop()
    try {
        $txt = $script:UI.txtEditor.Text; $car = [Math]::Max(0, [Math]::Min($script:UI.txtEditor.CaretIndex, $txt.Length))
        if ($car -eq 0) { $ln = 1; $col = 1 } else {
            $before = $txt.Substring(0, $car)
            $ln = ($before.Length - $before.Replace("`n", "").Length) + 1
            $nlPos = $before.LastIndexOf("`n")
            $col = if ($nlPos -ge 0) { $car - $nlPos } else { $car + 1 }
        }
        $script:UI.txtPos.Text = "Ln $ln, Col $col"
    } catch {}
})

 $script:HeavyStatusTimer = [System.Windows.Threading.DispatcherTimer]::new()
 $script:HeavyStatusTimer.Interval = [TimeSpan]::FromMilliseconds(500)
 $script:HeavyStatusTimer.Add_Tick({
    $script:HeavyStatusTimer.Stop()
    try {
        $txt = $script:UI.txtEditor.Text; $len = if ($null -eq $txt) { 0 } else { $txt.Length }
        if ($len -eq 0) { $wc = 0; $lc = 1 } else {
            $lc = ($txt.Length - $txt.Replace("`n", "").Length) + 1
            $wc = ([regex]::Matches($txt, '\S+')).Count
        }
        $script:UI.txtWords.Text = "Words: $wc"; $script:UI.txtChars.Text = "Chars: $len"; $script:UI.txtLines.Text = "Lines: $lc"
        $script:UI.txtEol.Text = EolDisplayLabel $script:State.LineEnding; $script:UI.txtEnc.Text = $script:State.Encoding
    } catch {}
})
#endregion

#region ==================== UI UPDATES & DOCUMENT OPS ====================
function script:UpdateTitle { try { $n = if ([string]::IsNullOrEmpty($script:State.FilePath)) { "Untitled" } else { [System.IO.Path]::GetFileName($script:State.FilePath) }; $m = if ($script:State.IsModified) { "*" } else { "" }; $t = "$m$n - $script:APP_NAME"; $script:Window.Title = $t; if ($null -ne $script:UI.txtWindowTitle) { $script:UI.txtWindowTitle.Text = $t } } catch {} }
function script:RequestStatusUpdate { if (-not $script:LightStatusTimer.IsEnabled) { $script:LightStatusTimer.Stop(); $script:LightStatusTimer.Start() }; $script:HeavyStatusTimer.Stop(); $script:HeavyStatusTimer.Start() }
function script:ConfirmSave { if (-not $script:State.IsModified) { return $true }; $n = if ([string]::IsNullOrEmpty($script:State.FilePath)) { "Untitled" } else { [System.IO.Path]::GetFileName($script:State.FilePath) }; switch ([System.Windows.MessageBox]::Show("Do you want to save changes to $n`?", $script:APP_NAME, "YesNoCancel", "Warning")) { "Yes" { return (DoSave) } "No" { return $true } default { return $false } } }
function script:DoNew { if (-not (ConfirmSave)) { return }; $script:UI.txtEditor.Clear(); $script:State.FilePath = ""; $script:State.IsModified = $false; $script:State.LineEnding = "CRLF"; $script:State.Encoding = "UTF-8"; $script:State.ZoomLevel = $script:DEF_ZOOM; ApplyZoom; UpdateTitle; RequestStatusUpdate; $null = $script:UI.txtEditor.Focus() }

function script:DoOpen {
    if (-not (ConfirmSave)) { return }
    $dlg = [Microsoft.Win32.OpenFileDialog]::new(); $dlg.Title = "Open"; $dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"; $dlg.CheckFileExists = $true; $dlg.RestoreDirectory = $true
    try {
        if ($dlg.ShowDialog() -ne $true) { return }
        $fi = [System.IO.FileInfo]::new($dlg.FileName)
        if ($fi.Length -gt 10MB) { if ([System.Windows.MessageBox]::Show("File exceeds 10 MB. Loading may be slow. Continue?", "Large File", "YesNo", "Warning") -ne "Yes") { return } }
        $det = DetectEncoding $dlg.FileName; $script:State.Encoding = $det.Name
        $content = [System.IO.File]::ReadAllText($dlg.FileName, $det.Encoding)
        $script:State.LineEnding = DetectLineEnding $content
        $script:UI.txtEditor.Text = $content; $script:State.FilePath = $dlg.FileName; $script:State.IsModified = $false
        UpdateTitle; RequestStatusUpdate; $script:UI.txtEditor.CaretIndex = 0; $script:UI.txtEditor.ScrollToHome(); $null = $script:UI.txtEditor.Focus()
    } catch { [System.Windows.MessageBox]::Show("Cannot open file:`n$($_.Exception.Message)", "Error", "OK", "Error") }
}
function script:GetCurrentEncoding { $n = $script:State.Encoding; foreach ($k in $script:ENCODINGS.Keys) { if ($k -eq $n) { return $script:ENCODINGS[$k] } }; switch -Wildcard ($n) { "*UTF-8*BOM*" { return [System.Text.UTF8Encoding]::new($true) } "*UTF-8*" { return [System.Text.UTF8Encoding]::new($false) } "*UTF-16 LE*" { return [System.Text.UnicodeEncoding]::new($false,$true) } "*UTF-16 BE*" { return [System.Text.UnicodeEncoding]::new($true,$true) } default { return [System.Text.UTF8Encoding]::new($false) } } }
function script:DoSave { if ([string]::IsNullOrEmpty($script:State.FilePath)) { return DoSaveAs }; try { [System.IO.File]::WriteAllText($script:State.FilePath, (ConvertLineEndings $script:UI.txtEditor.Text $script:State.LineEnding), (GetCurrentEncoding)); $script:State.IsModified = $false; UpdateTitle; return $true } catch { [System.Windows.MessageBox]::Show("Cannot save file:`n$($_.Exception.Message)", "Error", "OK", "Error"); return $false } }
function script:DoSaveAs {
    $dlg = [Microsoft.Win32.SaveFileDialog]::new(); $dlg.Title = "Save As"; $dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"; $dlg.DefaultExt = "txt"; $dlg.AddExtension = $true; $dlg.OverwritePrompt = $true; $dlg.RestoreDirectory = $true
    if (-not [string]::IsNullOrEmpty($script:State.FilePath)) { $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($script:State.FilePath); $dlg.FileName = [System.IO.Path]::GetFileName($script:State.FilePath) } else { $dlg.FileName = "Untitled.txt" }
    try { if ($dlg.ShowDialog() -ne $true) { return $false }; [System.IO.File]::WriteAllText($dlg.FileName, (ConvertLineEndings $script:UI.txtEditor.Text $script:State.LineEnding), (GetCurrentEncoding)); $script:State.FilePath = $dlg.FileName; $script:State.IsModified = $false; UpdateTitle; return $true } catch { [System.Windows.MessageBox]::Show("Cannot save file:`n$($_.Exception.Message)", "Error", "OK", "Error"); return $false }
}
#endregion

#region ==================== FIND / REPLACE ====================
function script:DoFind([string]$T, [bool]$C, [bool]$M = $true) {
    if ([string]::IsNullOrWhiteSpace($T)) { return $false }; $script:State.FindText = $T; $script:State.FindCase = $C; $b = $script:UI.txtEditor.Text
    if ([string]::IsNullOrEmpty($b)) { if ($M) { [System.Windows.MessageBox]::Show("Cannot find `"$T`"", $script:APP_NAME, "OK", "Information") }; return $false }
    $cmp = if ($C) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $s = $script:UI.txtEditor.SelectionStart + $script:UI.txtEditor.SelectionLength; if ($s -ge $b.Length) { $s = 0 }
    $i = $b.IndexOf($T, $s, $cmp); if ($i -lt 0 -and $s -gt 0) { $i = $b.IndexOf($T, 0, $cmp) }
    if ($i -ge 0) { $null = $script:UI.txtEditor.Focus(); $script:UI.txtEditor.Select($i, $T.Length); try { $script:UI.txtEditor.SelectionBrush = GetBrush $script:COLOR_FIND_BG } catch {}; $li = $script:UI.txtEditor.GetLineIndexFromCharacterIndex($i); if ($li -ge 0) { $script:UI.txtEditor.ScrollToLine($li) }; return $true }
    if ($M) { [System.Windows.MessageBox]::Show("Cannot find `"$T`"", $script:APP_NAME, "OK", "Information") }; return $false
}
function script:DoFindNext { if ([string]::IsNullOrWhiteSpace($script:State.FindText)) { ShowFindDlg } else { $null = DoFind $script:State.FindText $script:State.FindCase } }
function script:ShowFindDlg {
    $d = [System.Windows.Window]::new(); $d.Title = "Find"; $d.Width = 460; $d.Height = 150; $d.WindowStartupLocation = "CenterOwner"; $d.Owner = $script:Window
    $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(15); $null = $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()); $null = $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
    foreach ($cw in @("Auto","1*","Auto")) { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($cw -eq "1*") { [System.Windows.GridLength]::new(1,"Star") } else { [System.Windows.GridLength]::Auto }; $null = $g.ColumnDefinitions.Add($cd) }
    $lbl = [System.Windows.Controls.Label]::new(); $lbl.Content = "Find what:"; $lbl.VerticalAlignment = "Center"; $lbl.Foreground = GetBrush $script:COLOR_EDITOR_FG; [System.Windows.Controls.Grid]::SetRow($lbl,0); [System.Windows.Controls.Grid]::SetColumn($lbl,0); $null = $g.Children.Add($lbl)
    $tb = NewDarkTextBox; $tb.Margin = [System.Windows.Thickness]::new(10,0,10,0); $tb.Text = $script:State.FindText; [System.Windows.Controls.Grid]::SetRow($tb,0); [System.Windows.Controls.Grid]::SetColumn($tb,1); $null = $g.Children.Add($tb)
    $bf = NewDarkButton "Find Next"; $bf.IsDefault = $true; [System.Windows.Controls.Grid]::SetRow($bf,0); [System.Windows.Controls.Grid]::SetColumn($bf,2); $null = $g.Children.Add($bf)
    $ck = [System.Windows.Controls.CheckBox]::new(); $ck.Content = "Match case"; $ck.Margin = [System.Windows.Thickness]::new(0,15,0,0); $ck.IsChecked = $script:State.FindCase; $ck.Foreground = GetBrush $script:COLOR_EDITOR_FG; [System.Windows.Controls.Grid]::SetRow($ck,1); [System.Windows.Controls.Grid]::SetColumn($ck,1); $null = $g.Children.Add($ck)
    $bc = NewDarkButton "Cancel"; $bc.IsCancel = $true; $bc.Margin = [System.Windows.Thickness]::new(0,15,0,0); [System.Windows.Controls.Grid]::SetRow($bc,1); [System.Windows.Controls.Grid]::SetColumn($bc,2); $null = $g.Children.Add($bc)
    BuildDarkDialog $d $g; $bf.Add_Click({ $null = DoFind $tb.Text $ck.IsChecked }); $bc.Add_Click({ $d.Close() }); $null = $tb.Focus(); $tb.SelectAll(); $null = $d.ShowDialog()
}
function script:ShowReplaceDlg {
    $d = [System.Windows.Window]::new(); $d.Title = "Replace"; $d.Width = 480; $d.Height = 210; $d.WindowStartupLocation = "CenterOwner"; $d.Owner = $script:Window
    $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(15); for ($i=0; $i -lt 4; $i++) { $null = $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) }
    foreach ($cw in @("Auto","1*","Auto")) { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($cw -eq "1*") { [System.Windows.GridLength]::new(1,"Star") } else { [System.Windows.GridLength]::Auto }; $null = $g.ColumnDefinitions.Add($cd) }
    $l1 = [System.Windows.Controls.Label]::new(); $l1.Content = "Find what:"; $l1.VerticalAlignment = "Center"; $l1.Foreground = GetBrush $script:COLOR_EDITOR_FG; [System.Windows.Controls.Grid]::SetRow($l1,0); [System.Windows.Controls.Grid]::SetColumn($l1,0); $null = $g.Children.Add($l1)
    $tFind = NewDarkTextBox; $tFind.Margin = [System.Windows.Thickness]::new(10,5,10,5); $tFind.Text = $script:State.FindText; [System.Windows.Controls.Grid]::SetRow($tFind,0); [System.Windows.Controls.Grid]::SetColumn($tFind,1); $null = $g.Children.Add($tFind)
    $bfn = NewDarkButton "Find Next" 100 28; $bfn.Margin = [System.Windows.Thickness]::new(0,5,0,5); [System.Windows.Controls.Grid]::SetRow($bfn,0); [System.Windows.Controls.Grid]::SetColumn($bfn,2); $null = $g.Children.Add($bfn)
    $l2 = [System.Windows.Controls.Label]::new(); $l2.Content = "Replace with:"; $l2.VerticalAlignment = "Center"; $l2.Foreground = GetBrush $script:COLOR_EDITOR_FG; [System.Windows.Controls.Grid]::SetRow($l2,1); [System.Windows.Controls.Grid]::SetColumn($l2,0); $null = $g.Children.Add($l2)
    $tRepl = NewDarkTextBox; $tRepl.Margin = [System.Windows.Thickness]::new(10,5,10,5); [System.Windows.Controls.Grid]::SetRow($tRepl,1); [System.Windows.Controls.Grid]::SetColumn($tRepl,1); $null = $g.Children.Add($tRepl)
    $brp = NewDarkButton "Replace" 100 28; $brp.Margin = [System.Windows.Thickness]::new(0,5,0,5); [System.Windows.Controls.Grid]::SetRow($brp,1); [System.Windows.Controls.Grid]::SetColumn($brp,2); $null = $g.Children.Add($brp)
    $ck = [System.Windows.Controls.CheckBox]::new(); $ck.Content = "Match case"; $ck.Margin = [System.Windows.Thickness]::new(0,10,0,0); $ck.IsChecked = $script:State.FindCase; $ck.Foreground = GetBrush $script:COLOR_EDITOR_FG; [System.Windows.Controls.Grid]::SetRow($ck,2); [System.Windows.Controls.Grid]::SetColumn($ck,1); $null = $g.Children.Add($ck)
    $bra = NewDarkButton "Replace All" 100 28; $bra.Margin = [System.Windows.Thickness]::new(0,5,0,5); [System.Windows.Controls.Grid]::SetRow($bra,2); [System.Windows.Controls.Grid]::SetColumn($bra,2); $null = $g.Children.Add($bra)
    $bcx = NewDarkButton "Cancel" 100 28; $bcx.IsCancel = $true; $bcx.Margin = [System.Windows.Thickness]::new(0,5,0,5); [System.Windows.Controls.Grid]::SetRow($bcx,3); [System.Windows.Controls.Grid]::SetColumn($bcx,2); $null = $g.Children.Add($bcx)
    BuildDarkDialog $d $g
    $bfn.Add_Click({ $null = DoFind $tFind.Text $ck.IsChecked })
    $brp.Add_Click({ $s=$tFind.Text; $r=$tRepl.Text; $mc=$ck.IsChecked; if ([string]::IsNullOrEmpty($s)) { return }; $sel = $script:UI.txtEditor.SelectedText; if ($sel.Length -gt 0) { $m = if ($mc) { $sel -ceq $s } else { $sel.Equals($s, [System.StringComparison]::OrdinalIgnoreCase) }; if ($m) { $script:UI.txtEditor.SelectedText = $r } }; $null = DoFind $s $mc })
    $bra.Add_Click({ $s=$tFind.Text; $r=$tRepl.Text; $mc=$ck.IsChecked; if ([string]::IsNullOrEmpty($s)) { return }; $b = $script:UI.txtEditor.Text; if ([string]::IsNullOrEmpty($b)) { return }; $rx = [regex]::new([regex]::Escape($s), $(if ($mc) { [System.Text.RegularExpressions.RegexOptions]::None } else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase })); $c = $rx.Matches($b).Count; if ($c -gt 0) { $script:UI.txtEditor.Text = $rx.Replace($b, $r); RequestStatusUpdate; [System.Windows.MessageBox]::Show("$c occurrence(s) replaced.", $script:APP_NAME, "OK", "Information") } })
    $bcx.Add_Click({ $d.Close() }); $null = $tFind.Focus(); $tFind.SelectAll(); $null = $d.ShowDialog()
}
#endregion

#region ==================== FONT DIALOG ====================
function script:ShowFontDlg {
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { return }
    $dlg = [System.Windows.Forms.FontDialog]::new(); $dlg.ShowColor = $false; $dlg.ShowEffects = $false; $dlg.MinSize = $script:MIN_FONT; $dlg.MaxSize = $script:MAX_FONT; $dlg.FontMustExist = $true; $dlg.AllowVerticalFonts = $false
    try { $dlg.Font = [System.Drawing.Font]::new($script:UI.txtEditor.FontFamily.Source, [float][Math]::Round($script:State.BaseFontSize * 72 / 96)) } catch { $dlg.Font = [System.Drawing.Font]::new($script:DEF_FONT_FAMILY, 11) }
    try { if ($dlg.ShowDialog() -eq "OK") { $script:UI.txtEditor.FontFamily = [System.Windows.Media.FontFamily]::new($dlg.Font.FontFamily.Name); $script:State.BaseFontSize = [double]($dlg.Font.Size * 96 / 72); ApplyZoom } } finally { $dlg.Dispose() }
}
#endregion

#region ==================== EDITOR SETTINGS ====================
function script:ShowEditorCfg {
    $d = [System.Windows.Window]::new(); $d.Title = "Editor Settings"; $d.SizeToContent = "WidthAndHeight"; $d.WindowStartupLocation = "CenterOwner"; $d.Owner = $script:Window
    $brFg = GetBrush $script:COLOR_EDITOR_FG; $brBdr = GetBrush $script:COLOR_BORDER_LIT
    $ob = [System.Windows.Controls.Border]::new(); $ob.Padding = [System.Windows.Thickness]::new(14,12,14,12); $ob.MinWidth = 290
    $st = [System.Windows.Controls.StackPanel]::new(); $cm = $script:UI.txtEditor.Margin; $cs = [double]$script:State.BaseLineSpacing
    $mgb = [System.Windows.Controls.GroupBox]::new(); $mgb.Header = " Margins (px) "; $mgb.Padding = [System.Windows.Thickness]::new(8,4,8,4); $mgb.Margin = [System.Windows.Thickness]::new(0,0,0,6); $mgb.FontSize = 11; $mgb.Foreground = $brFg; $mgb.BorderThickness = [System.Windows.Thickness]::new(1); $mgb.BorderBrush = $brBdr
    $mg = [System.Windows.Controls.Grid]::new(); $null = $mg.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()); $null = $mg.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
    $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(45); $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(1,"Star"); $null = $mg.ColumnDefinitions.Add($c0); $null = $mg.ColumnDefinitions.Add($c1)
    $ll = [System.Windows.Controls.Label]::new(); $ll.Content = "Left:"; $ll.VerticalAlignment = "Center"; $ll.FontSize = 11; $ll.Padding = [System.Windows.Thickness]::new(0); $ll.Foreground = $brFg; [System.Windows.Controls.Grid]::SetRow($ll,0); [System.Windows.Controls.Grid]::SetColumn($ll,0); $null = $mg.Children.Add($ll)
    $tL = NewDarkTextBox; $tL.Width = 60; $tL.Height = 20; $tL.FontSize = 11; $tL.Margin = [System.Windows.Thickness]::new(0,2,0,2); $tL.HorizontalAlignment = "Left"; $tL.Padding = [System.Windows.Thickness]::new(3,0,3,0); $tL.Text = "$([int]$cm.Left)"; [System.Windows.Controls.Grid]::SetRow($tL,0); [System.Windows.Controls.Grid]::SetColumn($tL,1); $null = $mg.Children.Add($tL)
    $rl = [System.Windows.Controls.Label]::new(); $rl.Content = "Right:"; $rl.VerticalAlignment = "Center"; $rl.FontSize = 11; $rl.Padding = [System.Windows.Thickness]::new(0); $rl.Foreground = $brFg; [System.Windows.Controls.Grid]::SetRow($rl,1); [System.Windows.Controls.Grid]::SetColumn($rl,0); $null = $mg.Children.Add($rl)
    $tR = NewDarkTextBox; $tR.Width = 60; $tR.Height = 20; $tR.FontSize = 11; $tR.Margin = [System.Windows.Thickness]::new(0,2,0,2); $tR.HorizontalAlignment = "Left"; $tR.Padding = [System.Windows.Thickness]::new(3,0,3,0); $tR.Text = "$([int]$cm.Right)"; [System.Windows.Controls.Grid]::SetRow($tR,1); [System.Windows.Controls.Grid]::SetColumn($tR,1); $null = $mg.Children.Add($tR)
    $mgb.Content = $mg; $null = $st.Children.Add($mgb)
    $sgb = [System.Windows.Controls.GroupBox]::new(); $sgb.Header = " Line Spacing ($script:MIN_SPACING - $script:MAX_SPACING) "; $sgb.Padding = [System.Windows.Thickness]::new(8,4,8,4); $sgb.Margin = [System.Windows.Thickness]::new(0,0,0,6); $sgb.FontSize = 11; $sgb.Foreground = $brFg; $sgb.BorderThickness = [System.Windows.Thickness]::new(1); $sgb.BorderBrush = $brBdr
    $sg = [System.Windows.Controls.StackPanel]::new(); $sg.Orientation = "Horizontal"; $sl = [System.Windows.Controls.Label]::new(); $sl.Content = "Multiplier:"; $sl.VerticalAlignment = "Center"; $sl.FontSize = 11; $sl.Padding = [System.Windows.Thickness]::new(0); $sl.Foreground = $brFg; $null = $sg.Children.Add($sl)
    $tS = NewDarkTextBox; $tS.Width = 60; $tS.Height = 20; $tS.FontSize = 11; $tS.Margin = [System.Windows.Thickness]::new(8,0,0,0); $tS.Padding = [System.Windows.Thickness]::new(3,0,3,0); $tS.Text = $cs.ToString("F1"); $null = $sg.Children.Add($tS); $sgb.Content = $sg; $null = $st.Children.Add($sgb)
    $bp = [System.Windows.Controls.StackPanel]::new(); $bp.Orientation = "Horizontal"; $bp.HorizontalAlignment = "Left"; $bp.Margin = [System.Windows.Thickness]::new(0,6,0,0)
    $bOK = NewDarkButton "OK" 65 22; $bOK.FontSize = 11; $bOK.IsDefault = $true; $bOK.Margin = [System.Windows.Thickness]::new(0,0,5,0); $null = $bp.Children.Add($bOK)
    $bAp = NewDarkButton "Apply" 65 22; $bAp.FontSize = 11; $bAp.Margin = [System.Windows.Thickness]::new(0,0,5,0); $null = $bp.Children.Add($bAp)
    $bCa = NewDarkButton "Cancel" 65 22; $bCa.FontSize = 11; $bCa.IsCancel = $true; $null = $bp.Children.Add($bCa)
    $null = $st.Children.Add($bp); $ob.Child = $st; BuildDarkDialog $d $ob
    $om = $cm; $os = $cs
    $tryApply = { $lv = ToInt $tL.Text -1; if ($lv -lt $script:MIN_MARGIN -or $lv -gt $script:MAX_MARGIN) { [System.Windows.MessageBox]::Show("Left margin must be $script:MIN_MARGIN-$script:MAX_MARGIN.", "Invalid", "OK", "Warning"); $null = $tL.Focus(); $tL.SelectAll(); return $false }; $rv = ToInt $tR.Text -1; if ($rv -lt $script:MIN_MARGIN -or $rv -gt $script:MAX_MARGIN) { [System.Windows.MessageBox]::Show("Right margin must be $script:MIN_MARGIN-$script:MAX_MARGIN.", "Invalid", "OK", "Warning"); $null = $tR.Focus(); $tR.SelectAll(); return $false }; $sv = ToDouble $tS.Text -1; if ($sv -lt $script:MIN_SPACING -or $sv -gt $script:MAX_SPACING) { [System.Windows.MessageBox]::Show("Line spacing must be $script:MIN_SPACING-$script:MAX_SPACING.", "Invalid", "OK", "Warning"); $null = $tS.Focus(); $tS.SelectAll(); return $false }; $script:UI.txtEditor.Margin = [System.Windows.Thickness]::new($lv,0,$rv,0); $script:State.BaseLineSpacing = [double]$sv; ApplyLineSpacingToEditor; $script:Settings.Editor.MarginLeft = "$lv"; $script:Settings.Editor.MarginRight = "$rv"; $script:Settings.Editor.LineSpacing = $sv.ToString("F1"); return $true }
    $bAp.Add_Click({ $null = & $tryApply })
    $bOK.Add_Click({ if (& $tryApply) { $null = WriteIni $script:State.SettingsFile $script:Settings; $d.DialogResult = $true; $d.Close() } })
    $rest = { $script:UI.txtEditor.Margin = $om; $script:State.BaseLineSpacing = [double]$os; ApplyLineSpacingToEditor }
    $bCa.Add_Click({ & $rest; $d.Close() }); $d.Add_Closing({ param($s,$e); if ($d.DialogResult -ne $true) { & $rest } }); $null = $tL.Focus(); $tL.SelectAll(); $null = $d.ShowDialog()
}
#endregion

#region ==================== VIEW & WIRE EVENTS ====================
function script:SetWordWrap([bool]$On) { if ($On) { $script:UI.txtEditor.TextWrapping = "Wrap"; $script:UI.txtEditor.HorizontalScrollBarVisibility = "Disabled" } else { $script:UI.txtEditor.TextWrapping = "NoWrap"; $script:UI.txtEditor.HorizontalScrollBarVisibility = "Auto" } }
function script:SetStatusBar([bool]$On) { $v = if ($On) { "Visible" } else { "Collapsed" }; $script:UI.statusBar.Visibility = $v; $script:UI.statusBorder.Visibility = $v }

 $script:Window.Add_SourceInitialized({
    try {
        $src = [System.Windows.Interop.HwndSource]::FromVisual($script:Window); if ($null -eq $src) { return }
        $hook = [System.Windows.Interop.HwndSourceHook] {
            param($hwnd, $msg, $wParam, $lParam, $handled)
            if ($msg -eq 0x0024) { # WM_GETMINMAXINFO
                try {
                    $hMon = [MaximizeHelper]::MonitorFromWindow($hwnd, 2); if ($hMon -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
                    if ([MaximizeHelper]::GetMonitorInfo($hMon, $script:MinMaxInfoPtr)) {
                        $wL = [System.Runtime.InteropServices.Marshal]::ReadInt32($script:MinMaxInfoPtr, 20); $wT = [System.Runtime.InteropServices.Marshal]::ReadInt32($script:MinMaxInfoPtr, 24)
                        $wR = [System.Runtime.InteropServices.Marshal]::ReadInt32($script:MinMaxInfoPtr, 28); $wB = [System.Runtime.InteropServices.Marshal]::ReadInt32($script:MinMaxInfoPtr, 32)
                        $scale = [System.Windows.PresentationSource]::FromVisual($script:Window).CompositionTarget.TransformToDevice.M11
                        $bp = 6 * $scale; $mW = ($wR - $wL) + ($bp * 2); $mH = ($wB - $wT) + ($bp * 2); $mX = $wL - $bp; $mY = $wT - $bp
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 8, [int]$mW); [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 12, [int]$mH)
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 16, [int]$mX); [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 20, [int]$mY)
                        if ($handled -is [System.Management.Automation.PSReference]) { $handled.Value = $true } else { $handled = $true }
                    }
                } catch {}
            }
            return [IntPtr]::Zero
        }
        $src.AddHook($hook)
    } catch {}
})
 $script:UI.btnMin.Add_Click({ $script:Window.WindowState = "Minimized" })
 $script:UI.btnMax.Add_Click({ if ($script:Window.WindowState -eq "Maximized") { $script:Window.WindowState = "Normal" } else { $script:Window.WindowState = "Maximized" } })
 $script:UI.btnClose.Add_Click({ $script:Window.Close() })
 $script:UI.mnuNew.Add_Click({ DoNew }); $script:UI.mnuOpen.Add_Click({ DoOpen }); $script:UI.mnuSave.Add_Click({ $null = DoSave }); $script:UI.mnuSaveAs.Add_Click({ $null = DoSaveAs }); $script:UI.mnuExit.Add_Click({ $script:Window.Close() })
 $script:UI.mnuUndo.Add_Click({ if ($script:UI.txtEditor.CanUndo) { $script:UI.txtEditor.Undo() } }); $script:UI.mnuRedo.Add_Click({ if ($script:UI.txtEditor.CanRedo) { $script:UI.txtEditor.Redo() } })
 $script:UI.mnuCut.Add_Click({ $script:UI.txtEditor.Cut() }); $script:UI.mnuCopy.Add_Click({ $script:UI.txtEditor.Copy() }); $script:UI.mnuPaste.Add_Click({ $script:UI.txtEditor.Paste() })
 $script:UI.mnuDelete.Add_Click({ if ($script:UI.txtEditor.SelectionLength -gt 0) { $script:UI.txtEditor.SelectedText = "" } })
 $script:UI.mnuFind.Add_Click({ ShowFindDlg }); $script:UI.mnuFindNext.Add_Click({ DoFindNext }); $script:UI.mnuReplace.Add_Click({ ShowReplaceDlg })
 $script:UI.mnuSelAll.Add_Click({ $script:UI.txtEditor.SelectAll() }); $script:UI.mnuDate.Add_Click({ $script:UI.txtEditor.SelectedText = (Get-Date).ToString("h:mm tt M/d/yyyy") })
 $script:UI.ctxCut.Add_Click({ $script:UI.txtEditor.Cut() }); $script:UI.ctxCopy.Add_Click({ $script:UI.txtEditor.Copy() }); $script:UI.ctxPaste.Add_Click({ $script:UI.txtEditor.Paste() }); $script:UI.ctxSelAll.Add_Click({ $script:UI.txtEditor.SelectAll() })
 $script:UI.mnuFont.Add_Click({ ShowFontDlg }); $script:UI.mnuEditorCfg.Add_Click({ ShowEditorCfg })
 $script:UI.mnuWordWrap.Add_Checked({ SetWordWrap $true }); $script:UI.mnuWordWrap.Add_Unchecked({ SetWordWrap $false })
 $script:UI.mnuZoomIn.Add_Click({ ZoomIn }); $script:UI.mnuZoomOut.Add_Click({ ZoomOut }); $script:UI.mnuZoomReset.Add_Click({ ZoomReset })
 $script:UI.mnuEolCRLF.Add_Click({ $script:State.LineEnding = "CRLF"; $script:State.IsModified = $true; $script:UI.txtEol.Text = EolDisplayLabel "CRLF"; UpdateTitle })
 $script:UI.mnuEolLF.Add_Click({ $script:State.LineEnding = "LF"; $script:State.IsModified = $true; $script:UI.txtEol.Text = EolDisplayLabel "LF"; UpdateTitle })
 $script:UI.mnuEolCR.Add_Click({ $script:State.LineEnding = "CR"; $script:State.IsModified = $true; $script:UI.txtEol.Text = EolDisplayLabel "CR"; UpdateTitle })
 $script:UI.mnuEncUtf8.Add_Click({ $script:State.Encoding = "UTF-8 (no BOM)"; $script:State.IsModified = $true; $script:UI.txtEnc.Text = "UTF-8 (no BOM)"; UpdateTitle })
 $script:UI.mnuEncUtf8Bom.Add_Click({ $script:State.Encoding = "UTF-8 (BOM)"; $script:State.IsModified = $true; $script:UI.txtEnc.Text = "UTF-8 (BOM)"; UpdateTitle })
 $script:UI.mnuEncUtf16LE.Add_Click({ $script:State.Encoding = "UTF-16 LE (BOM)"; $script:State.IsModified = $true; $script:UI.txtEnc.Text = "UTF-16 LE (BOM)"; UpdateTitle })
 $script:UI.mnuEncUtf16BE.Add_Click({ $script:State.Encoding = "UTF-16 BE (BOM)"; $script:State.IsModified = $true; $script:UI.txtEnc.Text = "UTF-16 BE (BOM)"; UpdateTitle })
 $script:UI.mnuStatusBar.Add_Checked({ SetStatusBar $true }); $script:UI.mnuStatusBar.Add_Unchecked({ SetStatusBar $false })

 $script:Window.Add_PreviewKeyDown({
    param($s, $e); $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band "Control") -ne 0; $shift = ([System.Windows.Input.Keyboard]::Modifiers -band "Shift") -ne 0
    if ($ctrl -and -not $shift) { switch ($e.Key) { "N" { DoNew; $e.Handled = $true } "O" { DoOpen; $e.Handled = $true } "S" { $null = DoSave; $e.Handled = $true } "F" { ShowFindDlg; $e.Handled = $true } "H" { ShowReplaceDlg; $e.Handled = $true } "D0" { ZoomReset; $e.Handled = $true } "NumPad0" { ZoomReset; $e.Handled = $true } }; if ($e.Key -eq "OemPlus" -or $e.Key -eq "Add") { ZoomIn; $e.Handled = $true }; if ($e.Key -eq "OemMinus" -or $e.Key -eq "Subtract") { ZoomOut; $e.Handled = $true } }
    elseif ($ctrl -and $shift) { if ($e.Key -eq "S") { $null = DoSaveAs; $e.Handled = $true }; if ($e.Key -eq "OemPlus" -or $e.Key -eq "Add") { ZoomIn; $e.Handled = $true } }
    else { switch ($e.Key) { "F3" { DoFindNext; $e.Handled = $true } "F5" { $script:UI.txtEditor.SelectedText = (Get-Date).ToString("h:mm tt M/d/yyyy"); $e.Handled = $true } } }
})
 $script:UI.txtEditor.Add_PreviewMouseWheel({
    param($s, $e)
    if (([System.Windows.Input.Keyboard]::Modifiers -band "Control") -ne 0) { if ($e.Delta -gt 0) { ZoomIn } else { ZoomOut }; $e.Handled = $true; return }
    if ($null -eq $script:EditorScrollViewer) { return }; $e.Handled = $true
    $lh = $script:UI.txtEditor.GetValue([System.Windows.Controls.TextBlock]::LineHeightProperty); if ($lh -le 0) { $lh = $script:UI.txtEditor.FontSize * 1.2 }
    $nO = $script:EditorScrollViewer.VerticalOffset - ($e.Delta * ($script:SCROLL_LINES_PER_DELTA / $script:WHEEL_DELTA) * $lh)
    if ($nO -lt 0) { $nO = 0 }; if ($nO -gt $script:EditorScrollViewer.ScrollableHeight) { $nO = $script:EditorScrollViewer.ScrollableHeight }
    $script:EditorScrollViewer.ScrollToVerticalOffset($nO)
})
 $script:UI.txtEditor.Add_TextChanged({ $script:State.IsModified = $true; UpdateTitle; RequestStatusUpdate })
 $script:UI.txtEditor.Add_SelectionChanged({ RequestStatusUpdate })
 $script:Window.Add_Loaded({ if ($script:UI.mnuWordWrap.IsChecked) { SetWordWrap $true }; SetStatusBar $script:UI.mnuStatusBar.IsChecked; UpdateTitle; RequestStatusUpdate; $script:EditorScrollViewer = GetScrollViewer $script:UI.txtEditor; $null = $script:UI.txtEditor.Focus() })
 $script:Window.Add_Closing({ param($s,$e); if (-not (ConfirmSave)) { $e.Cancel = $true; return }; try { $script:LightStatusTimer.Stop(); $script:HeavyStatusTimer.Stop() } catch {}; SaveSettings })
#endregion

#region ==================== RUN & CLEANUP ====================
 $null = $script:Window.ShowDialog()

try { $script:LightStatusTimer.Stop(); $script:HeavyStatusTimer.Stop() } catch {}
[System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:MinMaxInfoPtr)
 $script:Window = $null; $script:UI.Clear(); $script:State.Clear(); $script:Settings.Clear(); $script:BrushCache.Clear()
 $script:EditorScrollViewer = $null; $script:DarkButtonStyle = $null; $script:AppIcon = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
#endregion
