#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
#region ==================== CONSTANTS ====================
$script:APP_NAME = "Notepad"; $script:APP_VERSION = "5.0.1"
$script:SETTINGS_FOLDER = "Notepad"; $script:SETTINGS_FILE = "settings.ini"
$script:MIN_WINDOW_W = 400; $script:MIN_WINDOW_H = 300; $script:MAX_WINDOW_W = 3840; $script:MAX_WINDOW_H = 2160
$script:DEF_WINDOW_W = 900; $script:DEF_WINDOW_H = 650
$script:MIN_FONT = 8; $script:MAX_FONT = 72; $script:DEF_FONT_SIZE = 14; $script:DEF_FONT_FAMILY = "Consolas"
$script:MIN_MARGIN = 0; $script:MAX_MARGIN = 200; $script:DEF_MARGIN = 0
$script:MIN_SPACING = 1.0; $script:MAX_SPACING = 3.0; $script:DEF_SPACING = 1.2
$script:MIN_ZOOM = 10; $script:MAX_ZOOM = 500; $script:DEF_ZOOM = 100; $script:ZOOM_STEP = 10
$script:COLOR_CHROME = "#F0F0F0"; $script:COLOR_EDITOR_BG = "#FFFFFF"; $script:COLOR_EDITOR_FG = "#1E1E1E"
$script:COLOR_FIND_BG = "#FFFF00"
$script:ENCODINGS = [ordered]@{
    "UTF-8 (no BOM)" = [System.Text.UTF8Encoding]::new($false); "UTF-8 (BOM)" = [System.Text.UTF8Encoding]::new($true)
    "UTF-16 LE (BOM)" = [System.Text.UnicodeEncoding]::new($false,$true); "UTF-16 BE (BOM)" = [System.Text.UnicodeEncoding]::new($true,$true)
    "UTF-16 LE (no BOM)" = [System.Text.UnicodeEncoding]::new($false,$false); "UTF-16 BE (no BOM)" = [System.Text.UnicodeEncoding]::new($true,$false)
    "UTF-32 LE (BOM)" = [System.Text.UTF32Encoding]::new($false,$true); "UTF-32 BE (BOM)" = [System.Text.UTF32Encoding]::new($true,$true)
}
$script:StatusUpdatePending = $false; $script:StatusUpdateTimer = $null; $script:AppIcon = $null
#endregion
#region ==================== ASSEMBLIES ====================
try { foreach ($asm in @("PresentationFramework","PresentationCore","WindowsBase","System.Windows.Forms","System.Drawing")) { Add-Type -AssemblyName $asm -ErrorAction Stop } }
catch { $null = [System.Windows.Forms.MessageBox]::Show("Failed to load assembly: $($_.Exception.Message)","Fatal Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error); exit 1 }
#endregion
#region ==================== ICON EXTRACTION ====================
try { Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class IconHelper {
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
"@ -ErrorAction SilentlyContinue } catch {}
function script:ExtractNotepadIcon {
    $paths = @((Join-Path $env:SystemRoot "System32\notepad.exe"),(Join-Path $env:SystemRoot "notepad.exe"),(Join-Path ${env:ProgramFiles} "Windows NT\Accessories\notepad.exe"))
    foreach ($size in @(48, 64, 256, 32)) {
        foreach ($p in $paths) {
            if (-not (Test-Path $p -PathType Leaf)) { continue }
            try {
                $hIcon = [IconHelper]::ExtractSized($p, 0, $size, 16)
                if ($hIcon -ne [IntPtr]::Zero) {
                    $bmp = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($hIcon, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
                    [IconHelper]::DestroyIcon($hIcon) | Out-Null
                    $bmp.Freeze(); return $bmp
                }
            } catch {}
        }
    }
    return $null
}
$script:AppIcon = ExtractNotepadIcon
#endregion
#region ==================== STATE ====================
$script:State = @{ FilePath = ""; IsModified = $false; FindText = ""; FindCase = $false; LineEnding = "CRLF"; Encoding = "UTF-8"; ZoomLevel = $script:DEF_ZOOM; BaseFontSize = [double]$script:DEF_FONT_SIZE; BaseLineSpacing = [double]$script:DEF_SPACING; SettingsDir = Join-Path $env:APPDATA $script:SETTINGS_FOLDER; SettingsFile = Join-Path (Join-Path $env:APPDATA $script:SETTINGS_FOLDER) $script:SETTINGS_FILE }
$script:UI = @{}; $script:Settings = $null; $script:Window = $null
#endregion
#region ==================== UTILITY ====================
function script:Clamp([double]$V,[double]$Lo,[double]$Hi) { if ([double]::IsNaN($V) -or [double]::IsInfinity($V)) { return $Lo }; [Math]::Max($Lo,[Math]::Min($Hi,$V)) }
function script:ToDouble([string]$T,[double]$D) { if ([string]::IsNullOrWhiteSpace($T)) { return $D }; $r = 0.0; $ci = [System.Globalization.CultureInfo]::InvariantCulture; if ([double]::TryParse($T.Trim(),[System.Globalization.NumberStyles]::Float,$ci,[ref]$r)) { return $r }; if ([double]::TryParse($T.Trim(),[ref]$r)) { return $r }; $D }
function script:ToInt([string]$T,[int]$D) { if ([string]::IsNullOrWhiteSpace($T)) { return $D }; $r = 0; if ([int]::TryParse($T.Trim(),[ref]$r)) { return $r }; $D }
function script:ToBool([string]$T,[bool]$D) { if ([string]::IsNullOrWhiteSpace($T)) { return $D }; switch ($T.Trim().ToLower()) { "true" { return $true } "1" { return $true } "false" { return $false } "0" { return $false } default { return $D } } }
function script:TestFont([string]$Name) { if ([string]::IsNullOrWhiteSpace($Name)) { return $false }; try { foreach ($f in [System.Windows.Media.Fonts]::SystemFontFamilies) { if ($f.Source -eq $Name) { return $true } } } catch {}; $false }
function script:EolDisplayLabel([string]$Eol) { switch ($Eol) { "CRLF" { return "Windows (CRLF)" } "LF" { return "Unix (LF)" } "CR" { return "Macintosh (CR)" } default { return "Windows (CRLF)" } } }
function script:ApplyIcon([System.Windows.Window]$w) { if ($null -ne $script:AppIcon -and $null -ne $w) { try { $w.Icon = $script:AppIcon } catch {} } }
#endregion
#region ==================== ENCODING DETECTION ====================
function script:DetectEncoding([string]$FilePath) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath); $len = $bytes.Length
        if ($len -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) { return @{ Encoding = [System.Text.UTF32Encoding]::new($true,$true); Name = "UTF-32 BE (BOM)"; BOM = $true } }
        if ($len -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) { return @{ Encoding = [System.Text.UTF32Encoding]::new($false,$true); Name = "UTF-32 LE (BOM)"; BOM = $true } }
        if ($len -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return @{ Encoding = [System.Text.UTF8Encoding]::new($true); Name = "UTF-8 (BOM)"; BOM = $true } }
        if ($len -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($true,$true); Name = "UTF-16 BE (BOM)"; BOM = $true } }
        if ($len -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($false,$true); Name = "UTF-16 LE (BOM)"; BOM = $true } }
        if ($len -ge 2) {
            $nullOdd = 0; $nullEven = 0; $check = [Math]::Min($len,4096)
            for ($i = 0; $i -lt $check; $i++) { if ($bytes[$i] -eq 0x00) { if ($i % 2 -eq 0) { $nullEven++ } else { $nullOdd++ } } }
            $halfCheck = $check / 4
            if ($nullOdd -gt $halfCheck -and $nullEven -lt ($halfCheck / 4)) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($false,$false); Name = "UTF-16 LE (no BOM)"; BOM = $false } }
            if ($nullEven -gt $halfCheck -and $nullOdd -lt ($halfCheck / 4)) { return @{ Encoding = [System.Text.UnicodeEncoding]::new($true,$false); Name = "UTF-16 BE (no BOM)"; BOM = $false } }
        }
        $isValidUtf8 = $true; $i = 0; $check = [Math]::Min($len,8192)
        while ($i -lt $check) {
            $b = $bytes[$i]; if ($b -le 0x7F) { $i++; continue }
            if (($b -band 0xE0) -eq 0xC0) { $seq = 1 } elseif (($b -band 0xF0) -eq 0xE0) { $seq = 2 } elseif (($b -band 0xF8) -eq 0xF0) { $seq = 3 } else { $isValidUtf8 = $false; break }
            for ($j = 0; $j -lt $seq; $j++) { $i++; if ($i -ge $check -or ($bytes[$i] -band 0xC0) -ne 0x80) { $isValidUtf8 = $false; break } }
            if (-not $isValidUtf8) { break }; $i++
        }
        if ($isValidUtf8) { return @{ Encoding = [System.Text.UTF8Encoding]::new($false); Name = "UTF-8"; BOM = $false } }
        return @{ Encoding = [System.Text.UTF8Encoding]::new($false); Name = "UTF-8"; BOM = $false }
    } catch { return @{ Encoding = [System.Text.UTF8Encoding]::new($false); Name = "UTF-8"; BOM = $false } }
}
function script:DetectLineEnding([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return "CRLF" }
    $crlf = 0; $lf = 0; $cr = 0; $i = 0; $tlen = $Text.Length
    while ($i -lt $tlen) { $c = $Text[$i]; if ($c -eq "`r") { if (($i+1) -lt $tlen -and $Text[$i+1] -eq "`n") { $crlf++; $i += 2 } else { $cr++; $i++ } } elseif ($c -eq "`n") { $lf++; $i++ } else { $i++ } }
    if ($crlf -ge $lf -and $crlf -ge $cr) { return "CRLF" }; if ($lf -gt $crlf -and $lf -ge $cr) { return "LF" }; if ($cr -gt 0) { return "CR" }; return "CRLF"
}
function script:ConvertLineEndings([string]$Text,[string]$Target) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }; $norm = $Text.Replace("`r`n","`n").Replace("`r","`n")
    switch ($Target) { "CRLF" { return $norm.Replace("`n","`r`n") } "LF" { return $norm } "CR" { return $norm.Replace("`n","`r") } default { return $norm.Replace("`n","`r`n") } }
}
#endregion
#region ==================== SETTINGS ====================
function script:DefaultSettings { @{ Window = @{ Width = "$script:DEF_WINDOW_W"; Height = "$script:DEF_WINDOW_H" }; Font = @{ Family = $script:DEF_FONT_FAMILY; Size = "$script:DEF_FONT_SIZE" }; View = @{ WordWrap = "False"; StatusBar = "True" }; Editor = @{ MarginLeft = "$script:DEF_MARGIN"; MarginRight = "$script:DEF_MARGIN"; LineSpacing = $script:DEF_SPACING.ToString("F1") } } }
function script:EnsureSettingsDir { try { if (-not (Test-Path $script:State.SettingsDir -PathType Container)) { $null = New-Item -Path $script:State.SettingsDir -ItemType Directory -Force -ErrorAction Stop }; return $true } catch { return $false } }
function script:ReadIni([string]$Path,[hashtable]$Defaults) {
    $out = @{}; foreach ($section in $Defaults.Keys) { $out[$section] = @{}; foreach ($key in $Defaults[$section].Keys) { $out[$section][$key] = $Defaults[$section][$key] } }
    try { if (-not (Test-Path $Path -PathType Leaf)) { return $out }; $sec = ""
        foreach ($raw in [System.IO.File]::ReadAllLines($Path,[System.Text.Encoding]::UTF8)) { $line = $raw.Trim()
            if ($line.Length -eq 0 -or $line[0] -eq '#' -or $line[0] -eq ';') { continue }
            if ($line[0] -eq '[' -and $line[-1] -eq ']') { $sec = $line.Substring(1,$line.Length-2).Trim(); if (-not $out.ContainsKey($sec)) { $out[$sec] = @{} }; continue }
            $eq = $line.IndexOf('='); if ($eq -gt 0 -and $sec.Length -gt 0) { $k = $line.Substring(0,$eq).Trim(); $v = $line.Substring($eq+1).Trim(); if ($out.ContainsKey($sec) -and $k.Length -gt 0) { $out[$sec][$k] = $v } }
        }
    } catch {}; $out
}
function script:WriteIni([string]$Path,[hashtable]$Data) {
    if (-not (EnsureSettingsDir)) { return $false }
    try { $sb = [System.Text.StringBuilder]::new(512); $null = $sb.AppendLine("# $script:APP_NAME Settings v$script:APP_VERSION"); $null = $sb.AppendLine("# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"); $null = $sb.AppendLine()
        foreach ($sec in @("Window","Font","View","Editor")) { if (-not $Data.ContainsKey($sec)) { continue }; $null = $sb.AppendLine("[$sec]"); foreach ($k in ($Data[$sec].Keys | Sort-Object)) { $null = $sb.AppendLine("$k=$($Data[$sec][$k])") }; $null = $sb.AppendLine() }
        [System.IO.File]::WriteAllText($Path,$sb.ToString().TrimEnd(),[System.Text.Encoding]::UTF8); return $true
    } catch { return $false }
}
function script:LoadSettings { ReadIni $script:State.SettingsFile (DefaultSettings) }
function script:SaveSettings {
    try { $script:Settings.Window.Width = [string][int]$script:Window.ActualWidth; $script:Settings.Window.Height = [string][int]$script:Window.ActualHeight
        $script:Settings.Font.Family = $script:UI.txtEditor.FontFamily.Source; $script:Settings.Font.Size = [string][int]$script:State.BaseFontSize
        $script:Settings.View.WordWrap = $script:UI.mnuWordWrap.IsChecked.ToString(); $script:Settings.View.StatusBar = $script:UI.mnuStatusBar.IsChecked.ToString()
        $script:Settings.Editor.MarginLeft = [string][int]$script:UI.txtEditor.Margin.Left; $script:Settings.Editor.MarginRight = [string][int]$script:UI.txtEditor.Margin.Right
        $script:Settings.Editor.LineSpacing = $script:State.BaseLineSpacing.ToString("F1")
        $null = WriteIni $script:State.SettingsFile $script:Settings
    } catch {}
}
$null = EnsureSettingsDir; $script:Settings = LoadSettings
#endregion
#region ==================== LINE SPACING ====================
function script:ApplyLineSpacingToEditor {
    try {
        $sp = Clamp $script:State.BaseLineSpacing $script:MIN_SPACING $script:MAX_SPACING
        $currentFontSize = $script:UI.txtEditor.FontSize
        if ($currentFontSize -le 0) { return }
        $lh = [Math]::Max(1.0, [double]($currentFontSize * $sp))
        $script:UI.txtEditor.SetValue([System.Windows.Controls.TextBlock]::LineHeightProperty, $lh)
        $script:UI.txtEditor.SetValue([System.Windows.Controls.TextBlock]::LineStackingStrategyProperty, [System.Windows.LineStackingStrategy]::BlockLineHeight)
    } catch {}
}
#endregion
#region ==================== ZOOM ====================
function script:UpdateZoomMenuState { try { $script:UI.mnuZoomReset.IsEnabled = ($script:State.ZoomLevel -ne $script:DEF_ZOOM) } catch {} }
function script:ApplyZoom {
    $factor = [double]$script:State.ZoomLevel / 100.0
    $newSize = Clamp ([double]$script:State.BaseFontSize * $factor) 4.0 200.0
    $script:UI.txtEditor.FontSize = $newSize
    ApplyLineSpacingToEditor; UpdateZoomDisplay; UpdateZoomMenuState
}
function script:ZoomIn { $script:State.ZoomLevel = [Math]::Min($script:MAX_ZOOM, $script:State.ZoomLevel + $script:ZOOM_STEP); ApplyZoom }
function script:ZoomOut { $script:State.ZoomLevel = [Math]::Max($script:MIN_ZOOM, $script:State.ZoomLevel - $script:ZOOM_STEP); ApplyZoom }
function script:ZoomReset { if ($script:State.ZoomLevel -eq $script:DEF_ZOOM) { return }; $script:State.ZoomLevel = $script:DEF_ZOOM; ApplyZoom }
function script:UpdateZoomDisplay { try { $script:UI.txtZoom.Text = "$($script:State.ZoomLevel)%" } catch {} }
#endregion
#region ==================== XAML ====================
[xml]$script:Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Untitled - Notepad" WindowStartupLocation="CenterScreen" MinWidth="$script:MIN_WINDOW_W" MinHeight="$script:MIN_WINDOW_H" Background="$script:COLOR_CHROME">
    <Window.Resources>
        <Style TargetType="MenuItem"><Setter Property="Padding" Value="4,1"/><Setter Property="FontSize" Value="12"/></Style>
        <Style x:Key="SBText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Normal"/>
            <Setter Property="Foreground" Value="#444444"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style x:Key="SBSep" TargetType="Rectangle">
            <Setter Property="Width" Value="1"/>
            <Setter Property="Height" Value="14"/>
            <Setter Property="Fill" Value="#AAAAAA"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
    </Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Top" BorderBrush="#B0B0B0" BorderThickness="0,0,0,1"><Border BorderBrush="#E8E8E8" BorderThickness="0,0,0,1">
            <Menu Name="menuBar" Background="#FFFFFF" Padding="1,0,1,0">
                <MenuItem Header="_File">
                    <MenuItem Header="_New" Name="mnuNew" InputGestureText="Ctrl+N"/><MenuItem Header="_Open..." Name="mnuOpen" InputGestureText="Ctrl+O"/>
                    <MenuItem Header="_Save" Name="mnuSave" InputGestureText="Ctrl+S"/><MenuItem Header="Save _As..." Name="mnuSaveAs" InputGestureText="Ctrl+Shift+S"/>
                    <Separator/><MenuItem Header="E_xit" Name="mnuExit" InputGestureText="Alt+F4"/></MenuItem>
                <MenuItem Header="_Edit">
                    <MenuItem Header="_Undo" Name="mnuUndo" InputGestureText="Ctrl+Z"/><MenuItem Header="_Redo" Name="mnuRedo" InputGestureText="Ctrl+Y"/><Separator/>
                    <MenuItem Header="Cu_t" Name="mnuCut" InputGestureText="Ctrl+X"/><MenuItem Header="_Copy" Name="mnuCopy" InputGestureText="Ctrl+C"/>
                    <MenuItem Header="_Paste" Name="mnuPaste" InputGestureText="Ctrl+V"/><MenuItem Header="De_lete" Name="mnuDelete" InputGestureText="Del"/><Separator/>
                    <MenuItem Header="_Find..." Name="mnuFind" InputGestureText="Ctrl+F"/><MenuItem Header="Find _Next" Name="mnuFindNext" InputGestureText="F3"/>
                    <MenuItem Header="_Replace..." Name="mnuReplace" InputGestureText="Ctrl+H"/><Separator/>
                    <MenuItem Header="Select _All" Name="mnuSelAll" InputGestureText="Ctrl+A"/><MenuItem Header="Time/_Date" Name="mnuDate" InputGestureText="F5"/></MenuItem>
                <MenuItem Header="F_ormat">
                    <MenuItem Header="_Word Wrap" Name="mnuWordWrap" IsCheckable="True"/><MenuItem Header="_Font..." Name="mnuFont"/><Separator/>
                    <MenuItem Header="_Zoom"><MenuItem Header="Zoom _In" Name="mnuZoomIn" InputGestureText="Ctrl++"/><MenuItem Header="Zoom _Out" Name="mnuZoomOut" InputGestureText="Ctrl+-"/><MenuItem Header="_Reset (100%)" Name="mnuZoomReset" InputGestureText="Ctrl+0"/></MenuItem><Separator/>
                    <MenuItem Header="_Line Endings" Name="mnuLineEndings">
                        <MenuItem Header="Windows (CRLF)" Name="mnuEolCRLF" ToolTip="Carriage Return + Line Feed (0D 0A).&#x0a;The standard line ending on Windows.&#x0a;Used by most Windows text editors and applications."/>
                        <MenuItem Header="Unix (LF)" Name="mnuEolLF" ToolTip="Line Feed only (0A).&#x0a;The standard line ending on Linux, macOS (10.0+), and Unix.&#x0a;Used by most programming tools and version control systems."/>
                        <MenuItem Header="Macintosh (CR)" Name="mnuEolCR" ToolTip="Carriage Return only (0D).&#x0a;Used by classic Mac OS (version 9 and earlier).&#x0a;Rarely encountered in modern files."/></MenuItem>
                    <MenuItem Header="_Encoding" Name="mnuEncoding">
                        <MenuItem Header="UTF-8 (no BOM)" Name="mnuEncUtf8" ToolTip="Unicode text without byte-order mark.&#x0a;This is the modern default for most applications and the web.&#x0a;Recommended for new files."/>
                        <MenuItem Header="UTF-8 (BOM)" Name="mnuEncUtf8Bom" ToolTip="Unicode text with a 3-byte BOM marker (EF BB BF).&#x0a;Some Windows apps (e.g. old Notepad) add this to identify UTF-8.&#x0a;The BOM is usually unnecessary but aids detection."/><Separator/>
                        <MenuItem Header="UTF-16 LE (BOM)" Name="mnuEncUtf16LE" ToolTip="Little-endian UTF-16 with byte-order mark (FF FE).&#x0a;This is the native Windows Unicode encoding.&#x0a;Used internally by Windows APIs and .NET strings.&#x0a;Files are roughly 2x the size of UTF-8 for ASCII text."/>
                        <MenuItem Header="UTF-16 BE (BOM)" Name="mnuEncUtf16BE" ToolTip="Big-endian UTF-16 with byte-order mark (FE FF).&#x0a;Common on older Mac/Unix systems and network protocols.&#x0a;Rarely used on Windows."/></MenuItem>
                    <Separator/><MenuItem Header="_Editor Settings..." Name="mnuEditorCfg"/></MenuItem>
                <MenuItem Header="_View"><MenuItem Header="_Status Bar" Name="mnuStatusBar" IsCheckable="True" IsChecked="True"/></MenuItem>
            </Menu></Border></Border>
        <Border DockPanel.Dock="Bottom" Name="statusBorder" BorderBrush="#808080" BorderThickness="0,1,0,0"><Border BorderBrush="#DFDFDF" BorderThickness="0,1,0,0">
            <StatusBar Name="statusBar" Background="#E8E8E8" Padding="6,1" Height="22">
                <StatusBar.ItemsPanel><ItemsPanelTemplate><DockPanel LastChildFill="False"/></ItemsPanelTemplate></StatusBar.ItemsPanel>

                <!-- Encoding -->
                <StatusBarItem DockPanel.Dock="Right" Padding="8,0">
                    <TextBlock Name="txtEnc" Text="UTF-8" Style="{StaticResource SBText}"/>
                </StatusBarItem>
                <StatusBarItem DockPanel.Dock="Right" Padding="0">
                    <Rectangle Style="{StaticResource SBSep}"/>
                </StatusBarItem>

                <!-- Line ending -->
                <StatusBarItem DockPanel.Dock="Right" Padding="8,0">
                    <TextBlock Name="txtEol" Text="Windows (CRLF)" Style="{StaticResource SBText}"/>
                </StatusBarItem>
                <StatusBarItem DockPanel.Dock="Right" Padding="0">
                    <Rectangle Style="{StaticResource SBSep}"/>
                </StatusBarItem>

                <!-- Zoom -->
                <StatusBarItem DockPanel.Dock="Right" Padding="8,0">
                    <TextBlock Name="txtZoom" Text="100%" Style="{StaticResource SBText}"/>
                </StatusBarItem>
                <StatusBarItem DockPanel.Dock="Right" Padding="0">
                    <Rectangle Style="{StaticResource SBSep}"/>
                </StatusBarItem>

                <!-- Line count -->
                <StatusBarItem DockPanel.Dock="Right" Padding="8,0">
                    <TextBlock Name="txtLines" Text="Lines: 1" Style="{StaticResource SBText}"/>
                </StatusBarItem>
                <StatusBarItem DockPanel.Dock="Right" Padding="0">
                    <Rectangle Style="{StaticResource SBSep}"/>
                </StatusBarItem>

                <!-- Character count -->
                <StatusBarItem DockPanel.Dock="Right" Padding="8,0">
                    <TextBlock Name="txtChars" Text="Chars: 0" Style="{StaticResource SBText}"/>
                </StatusBarItem>
                <StatusBarItem DockPanel.Dock="Right" Padding="0">
                    <Rectangle Style="{StaticResource SBSep}"/>
                </StatusBarItem>

                <!-- Word count -->
                <StatusBarItem DockPanel.Dock="Right" Padding="8,0">
                    <TextBlock Name="txtWords" Text="Words: 0" Style="{StaticResource SBText}"/>
                </StatusBarItem>
                <StatusBarItem DockPanel.Dock="Right" Padding="0">
                    <Rectangle Style="{StaticResource SBSep}"/>
                </StatusBarItem>

                <!-- Caret position (leftmost of the right-docked items) -->
                <StatusBarItem DockPanel.Dock="Right" Padding="8,0,10,0">
                    <TextBlock Name="txtPos" Text="Ln 1, Col 1" Style="{StaticResource SBText}"/>
                </StatusBarItem>

            </StatusBar></Border></Border>
        <Border Background="$script:COLOR_CHROME"><TextBox Name="txtEditor" AcceptsReturn="True" AcceptsTab="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" BorderThickness="0" Background="$script:COLOR_EDITOR_BG" Foreground="$script:COLOR_EDITOR_FG" Padding="8,6" UndoLimit="1000" IsUndoEnabled="True"/></Border>
    </DockPanel>
</Window>
"@
#endregion
#region ==================== INIT WINDOW ====================
try { $reader = [System.Xml.XmlNodeReader]::new($script:Xaml); $script:Window = [System.Windows.Markup.XamlReader]::Load($reader); $reader.Dispose() }
catch { $null = [System.Windows.MessageBox]::Show("XAML load failed: $($_.Exception.Message)","Fatal Error","OK","Error"); exit 1 }
ApplyIcon $script:Window
$script:ControlNames = @("txtEditor","txtPos","txtWords","txtChars","txtLines","txtEnc","txtEol","txtZoom","statusBar","statusBorder","menuBar","mnuNew","mnuOpen","mnuSave","mnuSaveAs","mnuExit","mnuUndo","mnuRedo","mnuCut","mnuCopy","mnuPaste","mnuDelete","mnuFind","mnuFindNext","mnuReplace","mnuSelAll","mnuDate","mnuWordWrap","mnuFont","mnuEditorCfg","mnuStatusBar","mnuZoomIn","mnuZoomOut","mnuZoomReset","mnuLineEndings","mnuEolCRLF","mnuEolLF","mnuEolCR","mnuEncoding","mnuEncUtf8","mnuEncUtf8Bom","mnuEncUtf16LE","mnuEncUtf16BE")
foreach ($n in $script:ControlNames) { $c = $script:Window.FindName($n); if ($null -eq $c) { $null = [System.Windows.MessageBox]::Show("Missing control: $n","Fatal Error","OK","Error"); exit 1 }; $script:UI[$n] = $c }
try {
    $w = Clamp (ToDouble $script:Settings.Window.Width $script:DEF_WINDOW_W) $script:MIN_WINDOW_W $script:MAX_WINDOW_W
    $h = Clamp (ToDouble $script:Settings.Window.Height $script:DEF_WINDOW_H) $script:MIN_WINDOW_H $script:MAX_WINDOW_H
    $script:Window.Width = $w; $script:Window.Height = $h
    $family = $script:Settings.Font.Family; if (-not (TestFont $family)) { $family = $script:DEF_FONT_FAMILY }
    $script:UI.txtEditor.FontFamily = [System.Windows.Media.FontFamily]::new($family)
    $fsize = Clamp (ToDouble $script:Settings.Font.Size $script:DEF_FONT_SIZE) $script:MIN_FONT $script:MAX_FONT
    $script:State.BaseFontSize = [double]$fsize; $script:UI.txtEditor.FontSize = [double]$fsize
    $ml = Clamp (ToDouble $script:Settings.Editor.MarginLeft $script:DEF_MARGIN) $script:MIN_MARGIN $script:MAX_MARGIN
    $mr = Clamp (ToDouble $script:Settings.Editor.MarginRight $script:DEF_MARGIN) $script:MIN_MARGIN $script:MAX_MARGIN
    $script:UI.txtEditor.Margin = [System.Windows.Thickness]::new($ml,0,$mr,0)
    $sp = Clamp (ToDouble $script:Settings.Editor.LineSpacing $script:DEF_SPACING) $script:MIN_SPACING $script:MAX_SPACING
    $script:State.BaseLineSpacing = [double]$sp; ApplyLineSpacingToEditor
    $script:UI.mnuWordWrap.IsChecked = ToBool $script:Settings.View.WordWrap $false
    $script:UI.mnuStatusBar.IsChecked = ToBool $script:Settings.View.StatusBar $true
} catch {}
$script:StatusUpdateTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:StatusUpdateTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$script:StatusUpdateTimer.Add_Tick({ $script:StatusUpdateTimer.Stop(); $script:StatusUpdatePending = $false; UpdateStatusImmediate })
#endregion
#region ==================== UI UPDATES ====================
function script:UpdateTitle {
    try { $name = if ([string]::IsNullOrEmpty($script:State.FilePath)) { "Untitled" } else { [System.IO.Path]::GetFileName($script:State.FilePath) }
        $mod = if ($script:State.IsModified) { "*" } else { "" }; $script:Window.Title = "$mod$name - $script:APP_NAME"
    } catch {}
}
function script:UpdateStatusImmediate {
    if ($null -eq $script:UI -or $null -eq $script:UI.statusBar) { return }
    if ($script:UI.statusBar.Visibility -ne "Visible") { return }
    try {
        $txt = $script:UI.txtEditor.Text; $len = if ($null -eq $txt) { 0 } else { $txt.Length }
        $car = [Math]::Max(0,[Math]::Min($script:UI.txtEditor.CaretIndex,$len))
        if ($len -eq 0 -or $car -eq 0) { $ln = 1; $col = 1 }
        else { $before = $txt.Substring(0,$car); $ln = ($before.Split("`n")).Count; $nlPos = $before.LastIndexOf("`n"); $col = if ($nlPos -ge 0) { $car - $nlPos } else { $car + 1 } }
        $script:UI.txtPos.Text = "Ln $ln, Col $col"
        if ($len -eq 0) { $wc = 0 } else {
            $wc = 0; $inWord = $false
            for ($i = 0; $i -lt $len; $i++) { $ch = $txt[$i]; if ([char]::IsWhiteSpace($ch)) { $inWord = $false } elseif (-not $inWord) { $wc++; $inWord = $true } }
        }
        $script:UI.txtWords.Text = "Words: $wc"; $script:UI.txtChars.Text = "Chars: $len"
        $lc = if ($len -eq 0) { 1 } else { ($txt.Split("`n")).Count }; $script:UI.txtLines.Text = "Lines: $lc"
        $script:UI.txtEol.Text = EolDisplayLabel $script:State.LineEnding; $script:UI.txtEnc.Text = $script:State.Encoding
        $script:UI.txtZoom.Text = "$($script:State.ZoomLevel)%"
    } catch {}
}
function script:RequestStatusUpdate {
    if (-not $script:StatusUpdatePending) { $script:StatusUpdatePending = $true; $script:StatusUpdateTimer.Stop(); $script:StatusUpdateTimer.Start() }
}
#endregion
#region ==================== DOCUMENT OPS ====================
function script:ConfirmSave {
    if (-not $script:State.IsModified) { return $true }
    $name = if ([string]::IsNullOrEmpty($script:State.FilePath)) { "Untitled" } else { [System.IO.Path]::GetFileName($script:State.FilePath) }
    $r = [System.Windows.MessageBox]::Show("Do you want to save changes to $name`?",$script:APP_NAME,"YesNoCancel","Warning")
    switch ($r) { "Yes" { return (DoSave) } "No" { return $true } "Cancel" { return $false } default { return $false } }
}
function script:DoNew {
    if (-not (ConfirmSave)) { return }
    $script:UI.txtEditor.Clear(); $script:State.FilePath = ""; $script:State.IsModified = $false
    $script:State.LineEnding = "CRLF"; $script:State.Encoding = "UTF-8"; $script:State.ZoomLevel = $script:DEF_ZOOM
    ApplyZoom; UpdateTitle; UpdateStatusImmediate; $null = $script:UI.txtEditor.Focus()
}
function script:DoOpen {
    if (-not (ConfirmSave)) { return }
    $dlg = [System.Windows.Forms.OpenFileDialog]::new(); $dlg.Title = "Open"
    $dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $dlg.CheckFileExists = $true; $dlg.CheckPathExists = $true; $dlg.RestoreDirectory = $true
    try {
        if ($dlg.ShowDialog() -ne "OK") { return }
        $fi = [System.IO.FileInfo]::new($dlg.FileName)
        if ($fi.Length -gt 10MB) { $r = [System.Windows.MessageBox]::Show("File exceeds 10 MB. Loading may be slow. Continue?","Large File","YesNo","Warning"); if ($r -ne "Yes") { return } }
        $det = DetectEncoding $dlg.FileName; $script:State.Encoding = $det.Name
        $content = [System.IO.File]::ReadAllText($dlg.FileName,$det.Encoding)
        $script:State.LineEnding = DetectLineEnding $content
        $script:UI.txtEditor.Text = $content; $script:State.FilePath = $dlg.FileName; $script:State.IsModified = $false
        UpdateTitle; UpdateStatusImmediate; $script:UI.txtEditor.CaretIndex = 0; $script:UI.txtEditor.ScrollToHome(); $null = $script:UI.txtEditor.Focus()
    } catch { $null = [System.Windows.MessageBox]::Show("Cannot open file:`n$($_.Exception.Message)","Error","OK","Error") } finally { $dlg.Dispose() }
}
function script:GetCurrentEncoding {
    $name = $script:State.Encoding
    foreach ($key in $script:ENCODINGS.Keys) { if ($key -eq $name) { return $script:ENCODINGS[$key] } }
    switch -Wildcard ($name) { "*UTF-8*BOM*" { return [System.Text.UTF8Encoding]::new($true) } "*UTF-8*" { return [System.Text.UTF8Encoding]::new($false) } "*UTF-16 LE*" { return [System.Text.UnicodeEncoding]::new($false,$true) } "*UTF-16 BE*" { return [System.Text.UnicodeEncoding]::new($true,$true) } default { return [System.Text.UTF8Encoding]::new($false) } }
}
function script:DoSave {
    if ([string]::IsNullOrEmpty($script:State.FilePath)) { return DoSaveAs }
    try { $text = ConvertLineEndings $script:UI.txtEditor.Text $script:State.LineEnding
        [System.IO.File]::WriteAllText($script:State.FilePath,$text,(GetCurrentEncoding))
        $script:State.IsModified = $false; UpdateTitle; return $true
    } catch { $null = [System.Windows.MessageBox]::Show("Cannot save file:`n$($_.Exception.Message)","Error","OK","Error"); return $false }
}
function script:DoSaveAs {
    $dlg = [System.Windows.Forms.SaveFileDialog]::new(); $dlg.Title = "Save As"
    $dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"; $dlg.DefaultExt = "txt"
    $dlg.AddExtension = $true; $dlg.OverwritePrompt = $true; $dlg.RestoreDirectory = $true
    if (-not [string]::IsNullOrEmpty($script:State.FilePath)) { $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($script:State.FilePath); $dlg.FileName = [System.IO.Path]::GetFileName($script:State.FilePath) } else { $dlg.FileName = "Untitled.txt" }
    try { if ($dlg.ShowDialog() -ne "OK") { return $false }
        $text = ConvertLineEndings $script:UI.txtEditor.Text $script:State.LineEnding
        [System.IO.File]::WriteAllText($dlg.FileName,$text,(GetCurrentEncoding))
        $script:State.FilePath = $dlg.FileName; $script:State.IsModified = $false; UpdateTitle; return $true
    } catch { $null = [System.Windows.MessageBox]::Show("Cannot save file:`n$($_.Exception.Message)","Error","OK","Error"); return $false } finally { $dlg.Dispose() }
}
#endregion
#region ==================== FIND / REPLACE ====================
function script:DoFind([string]$Text,[bool]$Case,[bool]$Msg = $true) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $script:State.FindText = $Text; $script:State.FindCase = $Case
    $body = $script:UI.txtEditor.Text
    if ([string]::IsNullOrEmpty($body)) { if ($Msg) { NotFound $Text }; return $false }
    $cmp = if ($Case) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $start = $script:UI.txtEditor.SelectionStart + $script:UI.txtEditor.SelectionLength
    if ($start -ge $body.Length) { $start = 0 }
    $idx = $body.IndexOf($Text,$start,$cmp)
    if ($idx -lt 0 -and $start -gt 0) { $idx = $body.IndexOf($Text,0,$cmp) }
    if ($idx -ge 0) {
        $null = $script:UI.txtEditor.Focus()
        $script:UI.txtEditor.Select($idx,$Text.Length)
        try { $script:UI.txtEditor.SelectionBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($script:COLOR_FIND_BG)) } catch {}
        $li = $script:UI.txtEditor.GetLineIndexFromCharacterIndex($idx)
        if ($li -ge 0) { $script:UI.txtEditor.ScrollToLine($li) }
        return $true
    }
    if ($Msg) { NotFound $Text }; $false
}
function script:NotFound([string]$Text) { $null = [System.Windows.MessageBox]::Show("Cannot find `"$Text`"",$script:APP_NAME,"OK","Information") }
function script:DoFindNext { if ([string]::IsNullOrWhiteSpace($script:State.FindText)) { ShowFindDlg } else { $null = DoFind $script:State.FindText $script:State.FindCase } }
function script:ShowFindDlg {
    $d = [System.Windows.Window]::new(); $d.Title = "Find"; $d.Width = 460; $d.Height = 150
    $d.WindowStartupLocation = "CenterOwner"; $d.Owner = $script:Window; $d.ResizeMode = "NoResize"
    $d.ShowInTaskbar = $false; $d.WindowStyle = "ToolWindow"
    $d.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($script:COLOR_CHROME)
    ApplyIcon $d
    $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(15)
    $null = $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
    $null = $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
    foreach ($cw in @("Auto","1*","Auto")) { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($cw -eq "1*") { [System.Windows.GridLength]::new(1,"Star") } else { [System.Windows.GridLength]::Auto }; $g.ColumnDefinitions.Add($cd) }
    $lbl = [System.Windows.Controls.Label]::new(); $lbl.Content = "Find what:"; $lbl.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetRow($lbl,0); [System.Windows.Controls.Grid]::SetColumn($lbl,0); $null = $g.Children.Add($lbl)
    $tb = [System.Windows.Controls.TextBox]::new(); $tb.Margin = [System.Windows.Thickness]::new(10,0,10,0); $tb.Height = 26
    $tb.VerticalContentAlignment = "Center"; $tb.Text = $script:State.FindText
    [System.Windows.Controls.Grid]::SetRow($tb,0); [System.Windows.Controls.Grid]::SetColumn($tb,1); $null = $g.Children.Add($tb)
    $bf = [System.Windows.Controls.Button]::new(); $bf.Content = "Find Next"; $bf.Width = 90; $bf.Height = 28; $bf.IsDefault = $true
    [System.Windows.Controls.Grid]::SetRow($bf,0); [System.Windows.Controls.Grid]::SetColumn($bf,2); $null = $g.Children.Add($bf)
    $ck = [System.Windows.Controls.CheckBox]::new(); $ck.Content = "Match case"; $ck.Margin = [System.Windows.Thickness]::new(0,15,0,0); $ck.IsChecked = $script:State.FindCase
    [System.Windows.Controls.Grid]::SetRow($ck,1); [System.Windows.Controls.Grid]::SetColumn($ck,1); $null = $g.Children.Add($ck)
    $bc = [System.Windows.Controls.Button]::new(); $bc.Content = "Cancel"; $bc.Width = 90; $bc.Height = 28; $bc.IsCancel = $true; $bc.Margin = [System.Windows.Thickness]::new(0,15,0,0)
    [System.Windows.Controls.Grid]::SetRow($bc,1); [System.Windows.Controls.Grid]::SetColumn($bc,2); $null = $g.Children.Add($bc)
    $d.Content = $g; $bf.Add_Click({ $null = DoFind $tb.Text $ck.IsChecked }); $bc.Add_Click({ $d.Close() })
    $null = $tb.Focus(); $tb.SelectAll(); $null = $d.ShowDialog()
}
function script:ShowReplaceDlg {
    $d = [System.Windows.Window]::new(); $d.Title = "Replace"; $d.Width = 480; $d.Height = 210
    $d.WindowStartupLocation = "CenterOwner"; $d.Owner = $script:Window; $d.ResizeMode = "NoResize"
    $d.ShowInTaskbar = $false; $d.WindowStyle = "ToolWindow"
    $d.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($script:COLOR_CHROME)
    ApplyIcon $d
    $g = [System.Windows.Controls.Grid]::new(); $g.Margin = [System.Windows.Thickness]::new(15)
    for ($i = 0; $i -lt 4; $i++) { $null = $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) }
    foreach ($cw in @("Auto","1*","Auto")) { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = if ($cw -eq "1*") { [System.Windows.GridLength]::new(1,"Star") } else { [System.Windows.GridLength]::Auto }; $g.ColumnDefinitions.Add($cd) }
    $l1 = [System.Windows.Controls.Label]::new(); $l1.Content = "Find what:"; $l1.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetRow($l1,0); [System.Windows.Controls.Grid]::SetColumn($l1,0); $null = $g.Children.Add($l1)
    $tFind = [System.Windows.Controls.TextBox]::new(); $tFind.Margin = [System.Windows.Thickness]::new(10,5,10,5); $tFind.Height = 26; $tFind.VerticalContentAlignment = "Center"; $tFind.Text = $script:State.FindText
    [System.Windows.Controls.Grid]::SetRow($tFind,0); [System.Windows.Controls.Grid]::SetColumn($tFind,1); $null = $g.Children.Add($tFind)
    $bfn = [System.Windows.Controls.Button]::new(); $bfn.Content = "Find Next"; $bfn.Width = 100; $bfn.Height = 28; $bfn.Margin = [System.Windows.Thickness]::new(0,5,0,5)
    [System.Windows.Controls.Grid]::SetRow($bfn,0); [System.Windows.Controls.Grid]::SetColumn($bfn,2); $null = $g.Children.Add($bfn)
    $l2 = [System.Windows.Controls.Label]::new(); $l2.Content = "Replace with:"; $l2.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetRow($l2,1); [System.Windows.Controls.Grid]::SetColumn($l2,0); $null = $g.Children.Add($l2)
    $tRepl = [System.Windows.Controls.TextBox]::new(); $tRepl.Margin = [System.Windows.Thickness]::new(10,5,10,5); $tRepl.Height = 26; $tRepl.VerticalContentAlignment = "Center"
    [System.Windows.Controls.Grid]::SetRow($tRepl,1); [System.Windows.Controls.Grid]::SetColumn($tRepl,1); $null = $g.Children.Add($tRepl)
    $brp = [System.Windows.Controls.Button]::new(); $brp.Content = "Replace"; $brp.Width = 100; $brp.Height = 28; $brp.Margin = [System.Windows.Thickness]::new(0,5,0,5)
    [System.Windows.Controls.Grid]::SetRow($brp,1); [System.Windows.Controls.Grid]::SetColumn($brp,2); $null = $g.Children.Add($brp)
    $ck = [System.Windows.Controls.CheckBox]::new(); $ck.Content = "Match case"; $ck.Margin = [System.Windows.Thickness]::new(0,10,0,0); $ck.IsChecked = $script:State.FindCase
    [System.Windows.Controls.Grid]::SetRow($ck,2); [System.Windows.Controls.Grid]::SetColumn($ck,1); $null = $g.Children.Add($ck)
    $bra = [System.Windows.Controls.Button]::new(); $bra.Content = "Replace All"; $bra.Width = 100; $bra.Height = 28; $bra.Margin = [System.Windows.Thickness]::new(0,5,0,5)
    [System.Windows.Controls.Grid]::SetRow($bra,2); [System.Windows.Controls.Grid]::SetColumn($bra,2); $null = $g.Children.Add($bra)
    $bcx = [System.Windows.Controls.Button]::new(); $bcx.Content = "Cancel"; $bcx.Width = 100; $bcx.Height = 28; $bcx.IsCancel = $true; $bcx.Margin = [System.Windows.Thickness]::new(0,5,0,5)
    [System.Windows.Controls.Grid]::SetRow($bcx,3); [System.Windows.Controls.Grid]::SetColumn($bcx,2); $null = $g.Children.Add($bcx)
    $d.Content = $g
    $bfn.Add_Click({ $null = DoFind $tFind.Text $ck.IsChecked })
    $brp.Add_Click({ $s = $tFind.Text; $r = $tRepl.Text; $mc = $ck.IsChecked; if ([string]::IsNullOrEmpty($s)) { return }; $sel = $script:UI.txtEditor.SelectedText; if ($sel.Length -gt 0) { $match = if ($mc) { $sel -ceq $s } else { $sel.Equals($s,[System.StringComparison]::OrdinalIgnoreCase) }; if ($match) { $script:UI.txtEditor.SelectedText = $r } }; $null = DoFind $s $mc })
    $bra.Add_Click({ $s = $tFind.Text; $r = $tRepl.Text; $mc = $ck.IsChecked; if ([string]::IsNullOrEmpty($s)) { return }; $body = $script:UI.txtEditor.Text; if ([string]::IsNullOrEmpty($body)) { NotFound $s; return }; $esc = [regex]::Escape($s); $opt = if ($mc) { [System.Text.RegularExpressions.RegexOptions]::None } else { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }; $rx = [regex]::new($esc,$opt); $cnt = $rx.Matches($body).Count; if ($cnt -gt 0) { $script:UI.txtEditor.Text = $rx.Replace($body,$r); UpdateStatusImmediate; $null = [System.Windows.MessageBox]::Show("$cnt occurrence(s) replaced.",$script:APP_NAME,"OK","Information") } else { NotFound $s } })
    $bcx.Add_Click({ $d.Close() }); $null = $tFind.Focus(); $tFind.SelectAll(); $null = $d.ShowDialog()
}
#endregion
#region ==================== FONT DIALOG ====================
function script:ShowFontDlg {
    $dlg = [System.Windows.Forms.FontDialog]::new(); $dlg.ShowColor = $false; $dlg.ShowEffects = $false
    $dlg.MinSize = $script:MIN_FONT; $dlg.MaxSize = $script:MAX_FONT; $dlg.FontMustExist = $true; $dlg.AllowVerticalFonts = $false
    try { $pt = [Math]::Round($script:State.BaseFontSize * 72 / 96); $dlg.Font = [System.Drawing.Font]::new($script:UI.txtEditor.FontFamily.Source,[float]$pt) } catch { $dlg.Font = [System.Drawing.Font]::new($script:DEF_FONT_FAMILY,11) }
    try { if ($dlg.ShowDialog() -eq "OK") { $script:UI.txtEditor.FontFamily = [System.Windows.Media.FontFamily]::new($dlg.Font.FontFamily.Name); $script:State.BaseFontSize = [double]($dlg.Font.Size * 96 / 72); ApplyZoom } } finally { $dlg.Dispose() }
}
#endregion
#region ==================== EDITOR SETTINGS ====================
function script:ShowEditorCfg {
    $d = [System.Windows.Window]::new(); $d.Title = "Editor Settings"; $d.SizeToContent = "WidthAndHeight"
    $d.WindowStartupLocation = "CenterOwner"; $d.Owner = $script:Window; $d.ResizeMode = "NoResize"
    $d.ShowInTaskbar = $false; $d.WindowStyle = "SingleBorderWindow"
    $d.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($script:COLOR_CHROME)
    ApplyIcon $d
    $outerBorder = [System.Windows.Controls.Border]::new(); $outerBorder.Padding = [System.Windows.Thickness]::new(14,12,14,12); $outerBorder.MinWidth = 290
    $stack = [System.Windows.Controls.StackPanel]::new()
    $curMargin = $script:UI.txtEditor.Margin; $curSpacing = [double]$script:State.BaseLineSpacing
    $mgb = [System.Windows.Controls.GroupBox]::new(); $mgb.Header = " Margins (px) "; $mgb.Padding = [System.Windows.Thickness]::new(8,4,8,4); $mgb.Margin = [System.Windows.Thickness]::new(0,0,0,6); $mgb.FontSize = 11
    $mg = [System.Windows.Controls.Grid]::new(); $null = $mg.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()); $null = $mg.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
    $mc0 = [System.Windows.Controls.ColumnDefinition]::new(); $mc0.Width = [System.Windows.GridLength]::new(45); $mc1 = [System.Windows.Controls.ColumnDefinition]::new(); $mc1.Width = [System.Windows.GridLength]::new(1,"Star"); $mg.ColumnDefinitions.Add($mc0); $mg.ColumnDefinitions.Add($mc1)
    $llbl = [System.Windows.Controls.Label]::new(); $llbl.Content = "Left:"; $llbl.VerticalAlignment = "Center"; $llbl.FontSize = 11; $llbl.Padding = [System.Windows.Thickness]::new(0)
    [System.Windows.Controls.Grid]::SetRow($llbl,0); [System.Windows.Controls.Grid]::SetColumn($llbl,0); $null = $mg.Children.Add($llbl)
    $tLeft = [System.Windows.Controls.TextBox]::new(); $tLeft.Width = 60; $tLeft.Height = 20; $tLeft.FontSize = 11; $tLeft.Margin = [System.Windows.Thickness]::new(0,2,0,2); $tLeft.HorizontalAlignment = "Left"; $tLeft.VerticalContentAlignment = "Center"; $tLeft.Padding = [System.Windows.Thickness]::new(3,0,3,0); $tLeft.Text = [string][int]$curMargin.Left
    [System.Windows.Controls.Grid]::SetRow($tLeft,0); [System.Windows.Controls.Grid]::SetColumn($tLeft,1); $null = $mg.Children.Add($tLeft)
    $rlbl = [System.Windows.Controls.Label]::new(); $rlbl.Content = "Right:"; $rlbl.VerticalAlignment = "Center"; $rlbl.FontSize = 11; $rlbl.Padding = [System.Windows.Thickness]::new(0)
    [System.Windows.Controls.Grid]::SetRow($rlbl,1); [System.Windows.Controls.Grid]::SetColumn($rlbl,0); $null = $mg.Children.Add($rlbl)
    $tRight = [System.Windows.Controls.TextBox]::new(); $tRight.Width = 60; $tRight.Height = 20; $tRight.FontSize = 11; $tRight.Margin = [System.Windows.Thickness]::new(0,2,0,2); $tRight.HorizontalAlignment = "Left"; $tRight.VerticalContentAlignment = "Center"; $tRight.Padding = [System.Windows.Thickness]::new(3,0,3,0); $tRight.Text = [string][int]$curMargin.Right
    [System.Windows.Controls.Grid]::SetRow($tRight,1); [System.Windows.Controls.Grid]::SetColumn($tRight,1); $null = $mg.Children.Add($tRight)
    $mgb.Content = $mg; $null = $stack.Children.Add($mgb)
    $sgb = [System.Windows.Controls.GroupBox]::new(); $sgb.Header = " Line Spacing ($script:MIN_SPACING - $script:MAX_SPACING) "; $sgb.Padding = [System.Windows.Thickness]::new(8,4,8,4); $sgb.Margin = [System.Windows.Thickness]::new(0,0,0,6); $sgb.FontSize = 11
    $sg = [System.Windows.Controls.StackPanel]::new(); $sg.Orientation = "Horizontal"
    $slbl = [System.Windows.Controls.Label]::new(); $slbl.Content = "Multiplier:"; $slbl.VerticalAlignment = "Center"; $slbl.FontSize = 11; $slbl.Padding = [System.Windows.Thickness]::new(0); $null = $sg.Children.Add($slbl)
    $tSpace = [System.Windows.Controls.TextBox]::new(); $tSpace.Width = 60; $tSpace.Height = 20; $tSpace.FontSize = 11; $tSpace.Margin = [System.Windows.Thickness]::new(8,0,0,0); $tSpace.VerticalContentAlignment = "Center"; $tSpace.Padding = [System.Windows.Thickness]::new(3,0,3,0); $tSpace.Text = $curSpacing.ToString("F1"); $null = $sg.Children.Add($tSpace)
    $sgb.Content = $sg; $null = $stack.Children.Add($sgb)
    $bp = [System.Windows.Controls.StackPanel]::new(); $bp.Orientation = "Horizontal"; $bp.HorizontalAlignment = "Left"; $bp.Margin = [System.Windows.Thickness]::new(0,6,0,0)
    $bOK = [System.Windows.Controls.Button]::new(); $bOK.Content = "OK"; $bOK.Width = 65; $bOK.Height = 22; $bOK.FontSize = 11; $bOK.IsDefault = $true; $bOK.Margin = [System.Windows.Thickness]::new(0,0,5,0); $null = $bp.Children.Add($bOK)
    $bApply = [System.Windows.Controls.Button]::new(); $bApply.Content = "Apply"; $bApply.Width = 65; $bApply.Height = 22; $bApply.FontSize = 11; $bApply.Margin = [System.Windows.Thickness]::new(0,0,5,0); $null = $bp.Children.Add($bApply)
    $bCancel = [System.Windows.Controls.Button]::new(); $bCancel.Content = "Cancel"; $bCancel.Width = 65; $bCancel.Height = 22; $bCancel.FontSize = 11; $bCancel.IsCancel = $true; $null = $bp.Children.Add($bCancel)
    $null = $stack.Children.Add($bp); $outerBorder.Child = $stack; $d.Content = $outerBorder
    $origMargin = $curMargin; $origSpacing = $curSpacing
    $tryApply = {
        $lv = ToInt $tLeft.Text -1; if ($lv -lt $script:MIN_MARGIN -or $lv -gt $script:MAX_MARGIN) { $null = [System.Windows.MessageBox]::Show("Left margin must be $script:MIN_MARGIN-$script:MAX_MARGIN.","Invalid","OK","Warning"); $null = $tLeft.Focus(); $tLeft.SelectAll(); return $false }
        $rv = ToInt $tRight.Text -1; if ($rv -lt $script:MIN_MARGIN -or $rv -gt $script:MAX_MARGIN) { $null = [System.Windows.MessageBox]::Show("Right margin must be $script:MIN_MARGIN-$script:MAX_MARGIN.","Invalid","OK","Warning"); $null = $tRight.Focus(); $tRight.SelectAll(); return $false }
        $sv = ToDouble $tSpace.Text -1; if ($sv -lt $script:MIN_SPACING -or $sv -gt $script:MAX_SPACING) { $null = [System.Windows.MessageBox]::Show("Line spacing must be $script:MIN_SPACING-$script:MAX_SPACING.","Invalid","OK","Warning"); $null = $tSpace.Focus(); $tSpace.SelectAll(); return $false }
        $script:UI.txtEditor.Margin = [System.Windows.Thickness]::new($lv,0,$rv,0)
        $script:State.BaseLineSpacing = [double]$sv; ApplyLineSpacingToEditor
        $script:Settings.Editor.MarginLeft = [string]$lv; $script:Settings.Editor.MarginRight = [string]$rv; $script:Settings.Editor.LineSpacing = $sv.ToString("F1"); return $true
    }
    $bApply.Add_Click({ $null = & $tryApply })
    $bOK.Add_Click({ if (& $tryApply) { $null = WriteIni $script:State.SettingsFile $script:Settings; $d.DialogResult = $true; $d.Close() } })
    $restoreOriginal = { $script:UI.txtEditor.Margin = $origMargin; $script:State.BaseLineSpacing = [double]$origSpacing; ApplyLineSpacingToEditor }
    $bCancel.Add_Click({ & $restoreOriginal; $d.Close() })
    $d.Add_Closing({ param($s,$e); if ($d.DialogResult -ne $true) { & $restoreOriginal } })
    $null = $tLeft.Focus(); $tLeft.SelectAll(); $null = $d.ShowDialog()
}
#endregion
#region ==================== ENCODING / EOL ====================
function script:SetEncoding([string]$Name) { $script:State.Encoding = $Name; $script:State.IsModified = $true; try { $script:UI.txtEnc.Text = $Name } catch {}; UpdateTitle }
function script:SetLineEndingType([string]$Type) { $script:State.LineEnding = $Type; $script:State.IsModified = $true; try { $script:UI.txtEol.Text = EolDisplayLabel $Type } catch {}; UpdateTitle }
#endregion
#region ==================== VIEW ====================
function script:SetWordWrap([bool]$On) { if ($On) { $script:UI.txtEditor.TextWrapping = "Wrap"; $script:UI.txtEditor.HorizontalScrollBarVisibility = "Disabled" } else { $script:UI.txtEditor.TextWrapping = "NoWrap"; $script:UI.txtEditor.HorizontalScrollBarVisibility = "Auto" } }
function script:SetStatusBar([bool]$On) { $vis = if ($On) { "Visible" } else { "Collapsed" }; $script:UI.statusBar.Visibility = $vis; $script:UI.statusBorder.Visibility = $vis; if ($On) { UpdateStatusImmediate } }
#endregion
#region ==================== WIRE EVENTS ====================
$script:UI.mnuNew.Add_Click({ DoNew }); $script:UI.mnuOpen.Add_Click({ DoOpen }); $script:UI.mnuSave.Add_Click({ $null = DoSave }); $script:UI.mnuSaveAs.Add_Click({ $null = DoSaveAs }); $script:UI.mnuExit.Add_Click({ $script:Window.Close() })
$script:UI.mnuUndo.Add_Click({ if ($script:UI.txtEditor.CanUndo) { $script:UI.txtEditor.Undo() } }); $script:UI.mnuRedo.Add_Click({ if ($script:UI.txtEditor.CanRedo) { $script:UI.txtEditor.Redo() } })
$script:UI.mnuCut.Add_Click({ $script:UI.txtEditor.Cut() }); $script:UI.mnuCopy.Add_Click({ $script:UI.txtEditor.Copy() }); $script:UI.mnuPaste.Add_Click({ $script:UI.txtEditor.Paste() })
$script:UI.mnuDelete.Add_Click({ if ($script:UI.txtEditor.SelectionLength -gt 0) { $script:UI.txtEditor.SelectedText = "" } })
$script:UI.mnuFind.Add_Click({ ShowFindDlg }); $script:UI.mnuFindNext.Add_Click({ DoFindNext }); $script:UI.mnuReplace.Add_Click({ ShowReplaceDlg })
$script:UI.mnuSelAll.Add_Click({ $script:UI.txtEditor.SelectAll() }); $script:UI.mnuDate.Add_Click({ $script:UI.txtEditor.SelectedText = (Get-Date).ToString("h:mm tt M/d/yyyy") })
$script:UI.mnuFont.Add_Click({ ShowFontDlg }); $script:UI.mnuEditorCfg.Add_Click({ ShowEditorCfg })
$script:UI.mnuWordWrap.Add_Checked({ SetWordWrap $true }); $script:UI.mnuWordWrap.Add_Unchecked({ SetWordWrap $false })
$script:UI.mnuZoomIn.Add_Click({ ZoomIn }); $script:UI.mnuZoomOut.Add_Click({ ZoomOut }); $script:UI.mnuZoomReset.Add_Click({ ZoomReset })
$script:UI.mnuEolCRLF.Add_Click({ SetLineEndingType "CRLF" }); $script:UI.mnuEolLF.Add_Click({ SetLineEndingType "LF" }); $script:UI.mnuEolCR.Add_Click({ SetLineEndingType "CR" })
$script:UI.mnuEncUtf8.Add_Click({ SetEncoding "UTF-8 (no BOM)" }); $script:UI.mnuEncUtf8Bom.Add_Click({ SetEncoding "UTF-8 (BOM)" })
$script:UI.mnuEncUtf16LE.Add_Click({ SetEncoding "UTF-16 LE (BOM)" }); $script:UI.mnuEncUtf16BE.Add_Click({ SetEncoding "UTF-16 BE (BOM)" })
$script:UI.mnuStatusBar.Add_Checked({ SetStatusBar $true }); $script:UI.mnuStatusBar.Add_Unchecked({ SetStatusBar $false })
$script:Window.Add_PreviewKeyDown({
    param($sender,$e)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band "Control") -ne 0
    $shift = ([System.Windows.Input.Keyboard]::Modifiers -band "Shift") -ne 0
    if ($ctrl -and -not $shift) {
        switch ($e.Key) { "N" { DoNew; $e.Handled = $true } "O" { DoOpen; $e.Handled = $true } "S" { $null = DoSave; $e.Handled = $true } "F" { ShowFindDlg; $e.Handled = $true } "H" { ShowReplaceDlg; $e.Handled = $true } "D0" { ZoomReset; $e.Handled = $true } "NumPad0" { ZoomReset; $e.Handled = $true } }
        if ($e.Key -eq "OemPlus" -or $e.Key -eq "Add") { ZoomIn; $e.Handled = $true }
        if ($e.Key -eq "OemMinus" -or $e.Key -eq "Subtract") { ZoomOut; $e.Handled = $true }
    } elseif ($ctrl -and $shift) {
        if ($e.Key -eq "S") { $null = DoSaveAs; $e.Handled = $true }
        if ($e.Key -eq "OemPlus" -or $e.Key -eq "Add") { ZoomIn; $e.Handled = $true }
    } else { switch ($e.Key) { "F3" { DoFindNext; $e.Handled = $true } "F5" { $script:UI.txtEditor.SelectedText = (Get-Date).ToString("h:mm tt M/d/yyyy"); $e.Handled = $true } } }
})
$script:UI.txtEditor.Add_PreviewMouseWheel({ param($sender,$e); if (([System.Windows.Input.Keyboard]::Modifiers -band "Control") -ne 0) { if ($e.Delta -gt 0) { ZoomIn } else { ZoomOut }; $e.Handled = $true } })
$script:UI.txtEditor.Add_TextChanged({ $script:State.IsModified = $true; UpdateTitle; RequestStatusUpdate })
$script:UI.txtEditor.Add_SelectionChanged({ RequestStatusUpdate })
$script:Window.Add_Loaded({ if ($script:UI.mnuWordWrap.IsChecked) { SetWordWrap $true }; SetStatusBar $script:UI.mnuStatusBar.IsChecked; UpdateTitle; UpdateStatusImmediate; UpdateZoomDisplay; UpdateZoomMenuState; $null = $script:UI.txtEditor.Focus() })
$script:Window.Add_Closing({ param($sender,$e); if (-not (ConfirmSave)) { $e.Cancel = $true; return }; try { $script:StatusUpdateTimer.Stop() } catch {}; SaveSettings })
#endregion
#region ==================== RUN ====================
$null = $script:Window.ShowDialog()
try { $script:StatusUpdateTimer.Stop() } catch {}; $script:StatusUpdateTimer = $null
$script:State = $null; $script:UI = $null; $script:Settings = $null; $script:Window = $null; $script:AppIcon = $null
#endregion
