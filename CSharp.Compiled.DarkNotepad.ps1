#Requires -Version 5.1
Set-StrictMode -Version Latest
 $ErrorActionPreference = "Stop"

# ==================== LOAD ASSEMBLIES ====================
 $requiredAssemblies = @(
    "PresentationFramework",
    "PresentationCore",
    "WindowsBase",
    "System.Xaml",
    "System.Windows.Forms",
    "System.Drawing"
)

Write-Host "[PS Debug] Loading required assemblies..." -ForegroundColor Cyan
foreach ($asm in $requiredAssemblies) { 
    try { 
        Add-Type -AssemblyName $asm -ErrorAction Stop 
        Write-Host "[PS Debug]   Loaded: $asm" -ForegroundColor DarkGray
    } catch { 
        Write-Host "[PS Debug]   Failed to load assembly: $asm" -ForegroundColor Yellow
    }
}

# ==================== OUTPUT EXE PATH ====================
 $exePath = "$env:USERPROFILE\Desktop\DarkNotepad.exe"

# ==================== C# SOURCE CODE ====================
 $code = @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace DarkNotepad
{
    public class App
    {
        #region Constants
        const string APP_NAME = "Notepad";
        const string APP_VERSION = "5.0.14";
        const string SETTINGS_FOLDER = "Notepad";
        const string SETTINGS_FILE = "settings.ini";
        const int MIN_WINDOW_W = 400, MIN_WINDOW_H = 300;
        const int MAX_WINDOW_W = 3840, MAX_WINDOW_H = 2160;
        const int DEF_WINDOW_W = 900, DEF_WINDOW_H = 650;
        const int MIN_FONT = 8, MAX_FONT = 72;
        const int DEF_FONT_SIZE = 14;
        const string DEF_FONT_FAMILY = "Consolas";
        const int MIN_MARGIN = 0, MAX_MARGIN = 200, DEF_MARGIN = 0;
        const double MIN_SPACING = 1.0, MAX_SPACING = 3.0, DEF_SPACING = 1.2;
        const int MIN_ZOOM = 10, MAX_ZOOM = 500, DEF_ZOOM = 100, ZOOM_STEP = 10;
        const double ZOOM_FONT_MIN = 4.0, ZOOM_FONT_MAX = 200.0;
        const double WHEEL_DELTA = 120.0;
        const double SCROLL_LINES_PER_DELTA = 5.0;
        const string COLOR_CHROME = "#2D2D30";
        const string COLOR_EDITOR_BG = "#1E1E1E";
        const string COLOR_EDITOR_FG = "#D4D4D4";
        const string COLOR_FIND_BG = "#005A9E";
        const string COLOR_BORDER = "#3F3F46";
        const string COLOR_BORDER_LIT = "#555555";
        const string COLOR_BTN_BG = "#3F3F46";
        #endregion

        #region Win32
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SHDefExtractIcon(string pszIconFile, int iIndex, uint uFlags, out IntPtr phiconLarge, out IntPtr phiconSmall, uint nIconSize);
        [DllImport("user32.dll")]
        static extern bool DestroyIcon(IntPtr hIcon);
        [DllImport("user32.dll")]
        static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
        [DllImport("user32.dll")]
        static extern bool GetMonitorInfo(IntPtr hMonitor, IntPtr lpmi);

        static IntPtr ExtractSizedIcon(string path, int index, int largeSize, int smallSize)
        {
            IntPtr hLarge, hSmall;
            uint packed = (uint)((smallSize << 16) | (largeSize & 0xFFFF));
            int hr = SHDefExtractIcon(path, index, 0, out hLarge, out hSmall, packed);
            if (hSmall != IntPtr.Zero) DestroyIcon(hSmall);
            if (hr == 0 && hLarge != IntPtr.Zero) return hLarge;
            return IntPtr.Zero;
        }

        static ImageSource ExtractNotepadIcon()
        {
            Console.WriteLine("[C# Debug] Attempting to extract Notepad icon...");
            string sysRoot = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string[] paths = {
                sysRoot + "\\\\System32\\\\notepad.exe",
                sysRoot + "\\\\notepad.exe",
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) + "\\\\Windows NT\\\\Accessories\\\\notepad.exe"
            };
            foreach (int size in new int[] { 48, 64, 256, 32 })
            {
                foreach (string p in paths)
                {
                    if (!File.Exists(p)) continue;
                    try
                    {
                        IntPtr hIcon = ExtractSizedIcon(p, 0, size, 16);
                        if (hIcon != IntPtr.Zero)
                        {
                            var bmp = Imaging.CreateBitmapSourceFromHIcon(hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                            DestroyIcon(hIcon);
                            bmp.Freeze();
                            Console.WriteLine("[C# Debug]   Icon extracted successfully from " + p);
                            return bmp;
                        }
                    }
                    catch (Exception ex) { Console.WriteLine("[C# Debug]   Exception during icon extraction: " + ex.Message); }
                }
            }
            Console.WriteLine("[C# Debug]   No icon found.");
            return null;
        }
        #endregion

        #region State
        static string FilePath = "";
        static bool IsModified = false;
        static string FindText = "";
        static bool FindCase = false;
        static string LineEnding = "CRLF";
        static string EncodingName = "UTF-8";
        static int ZoomLevel = DEF_ZOOM;
        static double BaseFontSize = DEF_FONT_SIZE;
        static double BaseLineSpacing = DEF_SPACING;
        static string SettingsDir;
        static string SettingsFilePath;
        static Window Window;
        static TextBox txtEditor;
        static TextBlock txtWindowTitle, txtPos, txtWords, txtChars, txtLines, txtEnc, txtEol, txtZoom;
        static StatusBar statusBar;
        static Border statusBorder;
        static MenuItem mnuNew, mnuOpen, mnuSave, mnuSaveAs, mnuExit;
        static MenuItem mnuUndo, mnuRedo, mnuCut, mnuCopy, mnuPaste, mnuDelete;
        static MenuItem mnuFind, mnuFindNext, mnuReplace, mnuSelAll, mnuDate;
        static MenuItem mnuWordWrap, mnuFont, mnuEditorCfg, mnuStatusBar;
        static MenuItem mnuZoomIn, mnuZoomOut, mnuZoomReset;
        static MenuItem mnuEolCRLF, mnuEolLF, mnuEolCR;
        static MenuItem mnuEncUtf8, mnuEncUtf8Bom, mnuEncUtf16LE, mnuEncUtf16BE;
        static Button btnMin, btnMax, btnClose;
        static MenuItem ctxCut, ctxCopy, ctxPaste, ctxSelAll;
        static DispatcherTimer LightStatusTimer, HeavyStatusTimer;
        static ScrollViewer EditorScrollViewer;
        static ImageSource AppIcon;
        static IntPtr MinMaxInfoPtr;
        static Dictionary<string, Brush> BrushCache = new Dictionary<string, Brush>();
        static Style DarkButtonStyleVal;
        static Dictionary<string, Dictionary<string, string>> Settings;
        #endregion

        #region Utility
        static double ClampD(double v, double lo, double hi)
        {
            if (double.IsNaN(v) || double.IsInfinity(v)) return lo;
            return Math.Max(lo, Math.Min(hi, v));
        }
        static double ToDoubleVal(string s, double d)
        {
            if (string.IsNullOrWhiteSpace(s)) return d;
            double r;
            if (double.TryParse(s.Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out r)) return r;
            return d;
        }
        static int ToIntVal(string s, int d)
        {
            if (string.IsNullOrWhiteSpace(s)) return d;
            int r;
            if (int.TryParse(s.Trim(), out r)) return r;
            return d;
        }
        static bool ToBoolVal(string s, bool d)
        {
            if (string.IsNullOrWhiteSpace(s)) return d;
            switch (s.Trim().ToLowerInvariant())
            {
                case "true": case "1": return true;
                case "false": case "0": return false;
                default: return d;
            }
        }
        static bool TestFont(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return false;
            try { foreach (var f in Fonts.SystemFontFamilies) if (f.Source == name) return true; } catch { }
            return false;
        }
        static Brush GetBrush(string hex)
        {
            if (!BrushCache.ContainsKey(hex))
            {
                try { var b = (Brush)new BrushConverter().ConvertFrom(hex); b.Freeze(); BrushCache[hex] = b; }
                catch { BrushCache[hex] = null; }
            }
            return BrushCache[hex];
        }
        static string EolDisplayLabel(string eol)
        {
            switch (eol)
            {
                case "CRLF": return "Windows (CRLF)";
                case "LF": return "Unix (LF)";
                case "CR": return "Macintosh (CR)";
                default: return "Windows (CRLF)";
            }
        }
        static ScrollViewer FindScrollViewer(DependencyObject d)
        {
            if (d == null) return null;
            ScrollViewer sv = d as ScrollViewer;
            if (sv != null) return sv;
            int count = VisualTreeHelper.GetChildrenCount(d);
            for (int i = 0; i < count; i++)
            {
                var r = FindScrollViewer(VisualTreeHelper.GetChild(d, i));
                if (r != null) return r;
            }
            return null;
        }
        static Style GetDarkButtonStyle()
        {
            if (DarkButtonStyleVal != null) return DarkButtonStyleVal;
            string xaml = @"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='Button'>
<Setter Property='Background' Value='#3F3F46'/><Setter Property='Foreground' Value='#D4D4D4'/><Setter Property='BorderBrush' Value='#555555'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Padding' Value='6,0'/>
<Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border x:Name='bd' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' TextBlock.Foreground='{TemplateBinding Foreground}' Margin='{TemplateBinding Padding}'/></Border>
<ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='bd' Property='Background' Value='#505057'/><Setter TargetName='bd' Property='BorderBrush' Value='#6A6A72'/></Trigger><Trigger Property='IsPressed' Value='True'><Setter TargetName='bd' Property='Background' Value='#2D2D30'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.4'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>";
            DarkButtonStyleVal = (Style)XamlReader.Parse(xaml);
            return DarkButtonStyleVal;
        }
        static void ApplyDarkControlTheme(Control c)
        {
            c.Background = GetBrush(COLOR_EDITOR_BG);
            c.Foreground = GetBrush(COLOR_EDITOR_FG);
            c.BorderBrush = GetBrush(COLOR_BORDER_LIT);
            TextBox tb = c as TextBox;
            if (tb != null) tb.CaretBrush = GetBrush(COLOR_EDITOR_FG);
        }
        static TextBox NewDarkTextBox()
        {
            var tb = new TextBox();
            tb.Height = 26;
            tb.VerticalContentAlignment = VerticalAlignment.Center;
            ApplyDarkControlTheme(tb);
            return tb;
        }
        static Button NewDarkButton(string text, double w, double h)
        {
            var b = new Button();
            b.Content = text; b.Width = w; b.Height = h;
            b.Background = GetBrush(COLOR_BTN_BG);
            b.Foreground = GetBrush(COLOR_EDITOR_FG);
            b.BorderBrush = GetBrush(COLOR_BORDER_LIT);
            b.Style = GetDarkButtonStyle();
            return b;
        }
        static void ApplyIconVal(Window w)
        {
            if (AppIcon != null && w != null) { try { w.Icon = AppIcon; } catch { } }
        }
        static void BuildDarkDialog(System.Windows.Window d, FrameworkElement content)
        {
            d.WindowStyle = WindowStyle.None;
            d.ResizeMode = ResizeMode.NoResize;
            d.ShowInTaskbar = false;
            ApplyIconVal(d);
            var chrome = new WindowChrome();
            chrome.CaptionHeight = 32; chrome.CornerRadius = new CornerRadius(0);
            chrome.GlassFrameThickness = new Thickness(0); chrome.UseAeroCaptionButtons = false;
            WindowChrome.SetWindowChrome(d, chrome);
            var mainBorder = new Border();
            mainBorder.BorderBrush = GetBrush(COLOR_BORDER);
            mainBorder.BorderThickness = new Thickness(1);
            mainBorder.Background = GetBrush(COLOR_CHROME);
            var root = new Grid();
            var r0 = new RowDefinition(); r0.Height = new GridLength(32);
            var r1 = new RowDefinition(); r1.Height = new GridLength(1, GridUnitType.Star);
            root.RowDefinitions.Add(r0); root.RowDefinitions.Add(r1);
            var tbGrid = new Grid(); tbGrid.Background = GetBrush(COLOR_EDITOR_BG);
            Grid.SetRow(tbGrid, 0);
            var lbl = new TextBlock();
            lbl.Text = d.Title; lbl.Foreground = GetBrush(COLOR_EDITOR_FG);
            lbl.VerticalAlignment = VerticalAlignment.Center; lbl.Margin = new Thickness(10, 0, 0, 0);
            tbGrid.Children.Add(lbl);
            var btnClose = new Button();
            btnClose.Content = "\u2715"; btnClose.Width = 46;
            btnClose.FontFamily = new FontFamily("Segoe UI");
            btnClose.HorizontalAlignment = HorizontalAlignment.Right;
            btnClose.Style = (Style)Window.FindResource("TitleBarCloseButton");
            WindowChrome.SetIsHitTestVisibleInChrome(btnClose, true);
            btnClose.Click += delegate(object s, System.Windows.RoutedEventArgs e) { d.Close(); };
            tbGrid.Children.Add(btnClose);
            root.Children.Add(tbGrid);
            Grid.SetRow(content, 1);
            root.Children.Add(content);
            mainBorder.Child = root;
            d.Content = mainBorder;
        }
        #endregion

        #region Encoding Detection
        class EncDet
        {
            public Encoding Encoding; public string Name; public bool BOM;
            public EncDet(Encoding enc, string name, bool bom) { Encoding = enc; Name = name; BOM = bom; }
        }
        static EncDet DetectEncoding(string filePath)
        {
            var fallback = new EncDet(new UTF8Encoding(false), "UTF-8", false);
            int maxBytes = 8192;
            byte[] bytes = new byte[maxBytes];
            int len = 0;
            FileStream fs = null;
            try { fs = File.OpenRead(filePath); len = fs.Read(bytes, 0, maxBytes); }
            catch { return fallback; }
            finally { if (fs != null) fs.Dispose(); }
            if (len >= 4 && bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE && bytes[3] == 0xFF)
                return new EncDet(new UTF32Encoding(true, true), "UTF-32 BE (BOM)", true);
            if (len >= 4 && bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0x00 && bytes[3] == 0x00)
                return new EncDet(new UTF32Encoding(false, true), "UTF-32 LE (BOM)", true);
            if (len >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
                return new EncDet(new UTF8Encoding(true), "UTF-8 (BOM)", true);
            if (len >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
                return new EncDet(new UnicodeEncoding(true, true), "UTF-16 BE (BOM)", true);
            if (len >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
                return new EncDet(new UnicodeEncoding(false, true), "UTF-16 LE (BOM)", true);
            if (len >= 2)
            {
                int nullOdd = 0, nullEven = 0;
                int check = Math.Min(len, 4096);
                for (int i = 0; i < check; i++) { if (bytes[i] == 0x00) { if ((i % 2) == 0) nullEven++; else nullOdd++; } }
                double halfCheck = check / 4.0;
                if (nullOdd > halfCheck && nullEven < (halfCheck / 4))
                    return new EncDet(new UnicodeEncoding(false, false), "UTF-16 LE (no BOM)", false);
                if (nullEven > halfCheck && nullOdd < (halfCheck / 4))
                    return new EncDet(new UnicodeEncoding(true, false), "UTF-16 BE (no BOM)", false);
            }
            return new EncDet(new UTF8Encoding(false), "UTF-8", false);
        }
        static string DetectLineEnding(string text)
        {
            if (string.IsNullOrEmpty(text)) return "CRLF";
            int crlf = (text.Length - text.Replace("\r\n", "").Length) / 2;
            int lf = (text.Length - text.Replace("\n", "").Length) - crlf;
            int cr = (text.Length - text.Replace("\r", "").Length) - crlf;
            if (crlf >= lf && crlf >= cr) return "CRLF";
            if (lf > crlf && lf >= cr) return "LF";
            if (cr > 0) return "CR";
            return "CRLF";
        }
        static string ConvertLineEndings(string text, string target)
        {
            if (string.IsNullOrEmpty(text)) return text;
            string norm = text.Replace("\r\n", "\n").Replace("\r", "\n");
            switch (target)
            {
                case "CRLF": return norm.Replace("\n", "\r\n");
                case "LF": return norm;
                case "CR": return norm.Replace("\n", "\r");
                default: return norm.Replace("\n", "\r\n");
            }
        }
        static Encoding GetCurrentEncoding()
        {
            switch (EncodingName)
            {
                case "UTF-8 (no BOM)": return new UTF8Encoding(false);
                case "UTF-8 (BOM)": return new UTF8Encoding(true);
                case "UTF-16 LE (BOM)": return new UnicodeEncoding(false, true);
                case "UTF-16 BE (BOM)": return new UnicodeEncoding(true, true);
                case "UTF-16 LE (no BOM)": return new UnicodeEncoding(false, false);
                case "UTF-16 BE (no BOM)": return new UnicodeEncoding(true, false);
                case "UTF-32 LE (BOM)": return new UTF32Encoding(false, true);
                case "UTF-32 BE (BOM)": return new UTF32Encoding(true, true);
                default: return new UTF8Encoding(false);
            }
        }
        #endregion

        #region Settings
        static Dictionary<string, Dictionary<string, string>> DefaultSettings()
        {
            var result = new Dictionary<string, Dictionary<string, string>>();
            result["Window"] = new Dictionary<string, string>();
            result["Window"]["Width"] = DEF_WINDOW_W.ToString();
            result["Window"]["Height"] = DEF_WINDOW_H.ToString();
            result["Font"] = new Dictionary<string, string>();
            result["Font"]["Family"] = DEF_FONT_FAMILY;
            result["Font"]["Size"] = DEF_FONT_SIZE.ToString();
            result["View"] = new Dictionary<string, string>();
            result["View"]["WordWrap"] = "False";
            result["View"]["StatusBar"] = "True";
            result["Editor"] = new Dictionary<string, string>();
            result["Editor"]["MarginLeft"] = DEF_MARGIN.ToString();
            result["Editor"]["MarginRight"] = DEF_MARGIN.ToString();
            result["Editor"]["LineSpacing"] = DEF_SPACING.ToString("F1", CultureInfo.InvariantCulture);
            return result;
        }
        static bool EnsureSettingsDir()
        {
            try { if (!Directory.Exists(SettingsDir)) Directory.CreateDirectory(SettingsDir); return true; }
            catch { return false; }
        }
        static Dictionary<string, Dictionary<string, string>> ReadIni(string path, Dictionary<string, Dictionary<string, string>> defaults)
        {
            var output = new Dictionary<string, Dictionary<string, string>>();
            foreach (var s in defaults.Keys)
            {
                output[s] = new Dictionary<string, string>();
                foreach (var k in defaults[s].Keys) output[s][k] = defaults[s][k];
            }
            try
            {
                if (!File.Exists(path)) return output;
                string sec = "";
                foreach (string raw in File.ReadAllLines(path, Encoding.UTF8))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;
                    if (line[0] == '[' && line[line.Length - 1] == ']')
                    {
                        sec = line.Substring(1, line.Length - 2).Trim();
                        if (!output.ContainsKey(sec)) output[sec] = new Dictionary<string, string>();
                        continue;
                    }
                    int eq = line.IndexOf('=');
                    if (eq > 0 && sec.Length > 0)
                    {
                        string k = line.Substring(0, eq).Trim();
                        string v = line.Substring(eq + 1).Trim();
                        if (output.ContainsKey(sec) && k.Length > 0) output[sec][k] = v;
                    }
                }
            }
            catch { }
            return output;
        }
        static bool WriteIni(string path, Dictionary<string, Dictionary<string, string>> data)
        {
            if (!EnsureSettingsDir()) return false;
            try
            {
                var sb = new StringBuilder(512);
                sb.AppendLine("# " + APP_NAME + " Settings v" + APP_VERSION);
                sb.AppendLine("# " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                sb.AppendLine();
                foreach (var sec in data.Keys)
                {
                    sb.AppendLine("[" + sec + "]");
                    var sortedKeys = data[sec].Keys.OrderBy(k => k);
                    foreach (var k in sortedKeys) sb.AppendLine(k + "=" + data[sec][k]);
                    sb.AppendLine();
                }
                File.WriteAllText(path, sb.ToString().TrimEnd(), Encoding.UTF8);
                return true;
            }
            catch { return false; }
        }
        static void LoadSettings() { Settings = ReadIni(SettingsFilePath, DefaultSettings()); }
        static void SaveSettings()
        {
            try
            {
                var rb = Window.RestoreBounds;
                int w = (int)rb.Width; int h = (int)rb.Height;
                if (w <= 0) w = (int)Window.ActualWidth;
                if (h <= 0) h = (int)Window.ActualHeight;
                Settings["Window"]["Width"] = w.ToString();
                Settings["Window"]["Height"] = h.ToString();
                Settings["Font"]["Family"] = txtEditor.FontFamily.Source;
                Settings["Font"]["Size"] = ((int)BaseFontSize).ToString();
                Settings["View"]["WordWrap"] = mnuWordWrap.IsChecked.ToString();
                Settings["View"]["StatusBar"] = mnuStatusBar.IsChecked.ToString();
                Settings["Editor"]["MarginLeft"] = ((int)txtEditor.Margin.Left).ToString();
                Settings["Editor"]["MarginRight"] = ((int)txtEditor.Margin.Right).ToString();
                Settings["Editor"]["LineSpacing"] = BaseLineSpacing.ToString("F1", CultureInfo.InvariantCulture);
                WriteIni(SettingsFilePath, Settings);
            }
            catch { }
        }
        #endregion

        #region Zoom & Line Spacing
        static void ApplyLineSpacingToEditor()
        {
            try
            {
                double sp = ClampD(BaseLineSpacing, MIN_SPACING, MAX_SPACING);
                double cfs = txtEditor.FontSize;
                if (cfs <= 0) return;
                double lh = Math.Max(1.0, cfs * sp);
                txtEditor.SetValue(TextBlock.LineHeightProperty, lh);
                txtEditor.SetValue(TextBlock.LineStackingStrategyProperty, LineStackingStrategy.BlockLineHeight);
            }
            catch { }
        }
        static void UpdateZoomMenuState() { try { mnuZoomReset.IsEnabled = (ZoomLevel != DEF_ZOOM); } catch { } }
        static void ApplyZoom()
        {
            double factor = (double)ZoomLevel / 100.0;
            txtEditor.FontSize = ClampD(BaseFontSize * factor, ZOOM_FONT_MIN, ZOOM_FONT_MAX);
            ApplyLineSpacingToEditor();
            try { txtZoom.Text = ZoomLevel + "%"; } catch { }
            UpdateZoomMenuState();
        }
        static void ZoomIn() { ZoomLevel = Math.Min(MAX_ZOOM, ZoomLevel + ZOOM_STEP); ApplyZoom(); }
        static void ZoomOut() { ZoomLevel = Math.Max(MIN_ZOOM, ZoomLevel - ZOOM_STEP); ApplyZoom(); }
        static void ZoomReset() { if (ZoomLevel == DEF_ZOOM) return; ZoomLevel = DEF_ZOOM; ApplyZoom(); }
        #endregion

        #region Document Ops
        static void UpdateTitle()
        {
            try
            {
                string n = string.IsNullOrEmpty(FilePath) ? "Untitled" : Path.GetFileName(FilePath);
                string m = IsModified ? "*" : "";
                string t = m + n + " - " + APP_NAME;
                Window.Title = t;
                if (txtWindowTitle != null) txtWindowTitle.Text = t;
            }
            catch { }
        }
        static void RequestStatusUpdate()
        {
            if (!LightStatusTimer.IsEnabled) { LightStatusTimer.Stop(); LightStatusTimer.Start(); }
            HeavyStatusTimer.Stop(); HeavyStatusTimer.Start();
        }
        static bool ConfirmSave()
        {
            if (!IsModified) return true;
            string n = string.IsNullOrEmpty(FilePath) ? "Untitled" : Path.GetFileName(FilePath);
            var result = MessageBox.Show("Do you want to save changes to " + n + "?", APP_NAME, MessageBoxButton.YesNoCancel, MessageBoxImage.Warning);
            switch (result)
            {
                case MessageBoxResult.Yes: return DoSave();
                case MessageBoxResult.No: return true;
                default: return false;
            }
        }
        static void DoNew()
        {
            if (!ConfirmSave()) return;
            txtEditor.Clear(); FilePath = ""; IsModified = false;
            LineEnding = "CRLF"; EncodingName = "UTF-8";
            ZoomLevel = DEF_ZOOM; ApplyZoom(); UpdateTitle(); RequestStatusUpdate();
            txtEditor.Focus();
        }
        static void DoOpen()
        {
            if (!ConfirmSave()) return;
            var dlg = new OpenFileDialog();
            dlg.Title = "Open"; dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*";
            dlg.CheckFileExists = true; dlg.RestoreDirectory = true;
            try
            {
                if (dlg.ShowDialog() != true) return;
                var fi = new FileInfo(dlg.FileName);
                if (fi.Length > 10 * 1024 * 1024)
                {
                    if (MessageBox.Show("File exceeds 10 MB. Loading may be slow. Continue?", "Large File", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
                }
                var det = DetectEncoding(dlg.FileName);
                EncodingName = det.Name;
                string content = File.ReadAllText(dlg.FileName, det.Encoding);
                LineEnding = DetectLineEnding(content);
                txtEditor.Text = content; FilePath = dlg.FileName; IsModified = false;
                UpdateTitle(); RequestStatusUpdate();
                txtEditor.CaretIndex = 0; txtEditor.ScrollToHome(); txtEditor.Focus();
            }
            catch (Exception ex) { MessageBox.Show("Cannot open file:\n" + ex.Message, "Error", MessageBoxButton.OK, MessageBoxImage.Error); }
        }
        static bool DoSave()
        {
            if (string.IsNullOrEmpty(FilePath)) return DoSaveAs();
            try
            {
                File.WriteAllText(FilePath, ConvertLineEndings(txtEditor.Text, LineEnding), GetCurrentEncoding());
                IsModified = false; UpdateTitle(); return true;
            }
            catch (Exception ex) { MessageBox.Show("Cannot save file:\n" + ex.Message, "Error", MessageBoxButton.OK, MessageBoxImage.Error); return false; }
        }
        static bool DoSaveAs()
        {
            var dlg = new SaveFileDialog();
            dlg.Title = "Save As"; dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*";
            dlg.DefaultExt = "txt"; dlg.AddExtension = true; dlg.OverwritePrompt = true; dlg.RestoreDirectory = true;
            if (!string.IsNullOrEmpty(FilePath)) { dlg.InitialDirectory = Path.GetDirectoryName(FilePath); dlg.FileName = Path.GetFileName(FilePath); }
            else dlg.FileName = "Untitled.txt";
            try
            {
                if (dlg.ShowDialog() != true) return false;
                File.WriteAllText(dlg.FileName, ConvertLineEndings(txtEditor.Text, LineEnding), GetCurrentEncoding());
                FilePath = dlg.FileName; IsModified = false; UpdateTitle(); return true;
            }
            catch (Exception ex) { MessageBox.Show("Cannot save file:\n" + ex.Message, "Error", MessageBoxButton.OK, MessageBoxImage.Error); return false; }
        }
        #endregion

        #region Find/Replace
        static bool DoFind(string t, bool c, bool m)
        {
            if (string.IsNullOrWhiteSpace(t)) return false;
            FindText = t; FindCase = c;
            string b = txtEditor.Text;
            if (string.IsNullOrEmpty(b)) { if (m) MessageBox.Show("Cannot find \"" + t + "\"", APP_NAME, MessageBoxButton.OK, MessageBoxImage.Information); return false; }
            var cmp = c ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
            int s = txtEditor.SelectionStart + txtEditor.SelectionLength;
            if (s >= b.Length) s = 0;
            int i = b.IndexOf(t, s, cmp);
            if (i < 0 && s > 0) i = b.IndexOf(t, 0, cmp);
            if (i >= 0)
            {
                txtEditor.Focus(); txtEditor.Select(i, t.Length);
                try { txtEditor.SelectionBrush = GetBrush(COLOR_FIND_BG); } catch { }
                int li = txtEditor.GetLineIndexFromCharacterIndex(i);
                if (li >= 0) txtEditor.ScrollToLine(li);
                return true;
            }
            if (m) MessageBox.Show("Cannot find \"" + t + "\"", APP_NAME, MessageBoxButton.OK, MessageBoxImage.Information);
            return false;
        }
        static void DoFindNext()
        {
            if (string.IsNullOrWhiteSpace(FindText)) ShowFindDlg();
            else DoFind(FindText, FindCase, true);
        }
        static void ShowFindDlg()
        {
            var d = new System.Windows.Window();
            d.Title = "Find"; d.Width = 460; d.Height = 150;
            d.WindowStartupLocation = WindowStartupLocation.CenterOwner; d.Owner = Window;
            var g = new Grid(); g.Margin = new Thickness(15);
            g.RowDefinitions.Add(new RowDefinition()); g.RowDefinitions.Add(new RowDefinition());
            foreach (string cw in new string[] { "Auto", "1*", "Auto" })
            {
                var cd = new ColumnDefinition();
                cd.Width = cw == "1*" ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
                g.ColumnDefinitions.Add(cd);
            }
            var lbl = new Label(); lbl.Content = "Find what:"; lbl.VerticalAlignment = VerticalAlignment.Center; lbl.Foreground = GetBrush(COLOR_EDITOR_FG);
            Grid.SetRow(lbl, 0); Grid.SetColumn(lbl, 0); g.Children.Add(lbl);
            var tb = NewDarkTextBox(); tb.Margin = new Thickness(10, 0, 10, 0); tb.Text = FindText;
            Grid.SetRow(tb, 0); Grid.SetColumn(tb, 1); g.Children.Add(tb);
            var bf = NewDarkButton("Find Next", 90, 28); bf.IsDefault = true;
            Grid.SetRow(bf, 0); Grid.SetColumn(bf, 2); g.Children.Add(bf);
            var ck = new CheckBox(); ck.Content = "Match case"; ck.Margin = new Thickness(0, 15, 0, 0); ck.IsChecked = FindCase; ck.Foreground = GetBrush(COLOR_EDITOR_FG);
            Grid.SetRow(ck, 1); Grid.SetColumn(ck, 1); g.Children.Add(ck);
            var bc = NewDarkButton("Cancel", 90, 28); bc.IsCancel = true; bc.Margin = new Thickness(0, 15, 0, 0);
            Grid.SetRow(bc, 1); Grid.SetColumn(bc, 2); g.Children.Add(bc);
            BuildDarkDialog(d, g);
            bf.Click += delegate(object s, System.Windows.RoutedEventArgs e) { DoFind(tb.Text, ck.IsChecked ?? false, true); };
            bc.Click += delegate(object s, System.Windows.RoutedEventArgs e) { d.Close(); };
            tb.Focus(); tb.SelectAll();
            d.ShowDialog();
        }
        static void ShowReplaceDlg()
        {
            var d = new System.Windows.Window();
            d.Title = "Replace"; d.Width = 480; d.Height = 210;
            d.WindowStartupLocation = WindowStartupLocation.CenterOwner; d.Owner = Window;
            var g = new Grid(); g.Margin = new Thickness(15);
            for (int i = 0; i < 4; i++) g.RowDefinitions.Add(new RowDefinition());
            foreach (string cw in new string[] { "Auto", "1*", "Auto" })
            {
                var cd = new ColumnDefinition();
                cd.Width = cw == "1*" ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
                g.ColumnDefinitions.Add(cd);
            }
            var l1 = new Label(); l1.Content = "Find what:"; l1.VerticalAlignment = VerticalAlignment.Center; l1.Foreground = GetBrush(COLOR_EDITOR_FG);
            Grid.SetRow(l1, 0); Grid.SetColumn(l1, 0); g.Children.Add(l1);
            var tFind = NewDarkTextBox(); tFind.Margin = new Thickness(10, 5, 10, 5); tFind.Text = FindText;
            Grid.SetRow(tFind, 0); Grid.SetColumn(tFind, 1); g.Children.Add(tFind);
            var bfn = NewDarkButton("Find Next", 100, 28); bfn.Margin = new Thickness(0, 5, 0, 5);
            Grid.SetRow(bfn, 0); Grid.SetColumn(bfn, 2); g.Children.Add(bfn);
            var l2 = new Label(); l2.Content = "Replace with:"; l2.VerticalAlignment = VerticalAlignment.Center; l2.Foreground = GetBrush(COLOR_EDITOR_FG);
            Grid.SetRow(l2, 1); Grid.SetColumn(l2, 0); g.Children.Add(l2);
            var tRepl = NewDarkTextBox(); tRepl.Margin = new Thickness(10, 5, 10, 5);
            Grid.SetRow(tRepl, 1); Grid.SetColumn(tRepl, 1); g.Children.Add(tRepl);
            var brp = NewDarkButton("Replace", 100, 28); brp.Margin = new Thickness(0, 5, 0, 5);
            Grid.SetRow(brp, 1); Grid.SetColumn(brp, 2); g.Children.Add(brp);
            var ck = new CheckBox(); ck.Content = "Match case"; ck.Margin = new Thickness(0, 10, 0, 0); ck.IsChecked = FindCase; ck.Foreground = GetBrush(COLOR_EDITOR_FG);
            Grid.SetRow(ck, 2); Grid.SetColumn(ck, 1); g.Children.Add(ck);
            var bra = NewDarkButton("Replace All", 100, 28); bra.Margin = new Thickness(0, 5, 0, 5);
            Grid.SetRow(bra, 2); Grid.SetColumn(bra, 2); g.Children.Add(bra);
            var bcx = NewDarkButton("Cancel", 100, 28); bcx.IsCancel = true; bcx.Margin = new Thickness(0, 5, 0, 5);
            Grid.SetRow(bcx, 3); Grid.SetColumn(bcx, 2); g.Children.Add(bcx);
            BuildDarkDialog(d, g);
            bfn.Click += delegate(object s, System.Windows.RoutedEventArgs e) { DoFind(tFind.Text, ck.IsChecked ?? false, true); };
            brp.Click += delegate(object s, System.Windows.RoutedEventArgs e) {
                string sf = tFind.Text, r = tRepl.Text; bool mc = ck.IsChecked ?? false;
                if (string.IsNullOrEmpty(sf)) return;
                string sel = txtEditor.SelectedText;
                if (sel.Length > 0) { bool match = mc ? sel == sf : sel.Equals(sf, StringComparison.OrdinalIgnoreCase); if (match) txtEditor.SelectedText = r; }
                DoFind(sf, mc, true);
            };
            bra.Click += delegate(object s, System.Windows.RoutedEventArgs e) {
                string sf = tFind.Text, r = tRepl.Text; bool mc = ck.IsChecked ?? false;
                if (string.IsNullOrEmpty(sf)) return;
                string b = txtEditor.Text;
                if (string.IsNullOrEmpty(b)) return;
                var rx = new Regex(Regex.Escape(sf), mc ? RegexOptions.None : RegexOptions.IgnoreCase);
                int c = rx.Matches(b).Count;
                if (c > 0) { txtEditor.Text = rx.Replace(b, r); RequestStatusUpdate(); MessageBox.Show(c + " occurrence(s) replaced.", APP_NAME, MessageBoxButton.OK, MessageBoxImage.Information); }
            };
            bcx.Click += delegate(object s, System.Windows.RoutedEventArgs e) { d.Close(); };
            tFind.Focus(); tFind.SelectAll();
            d.ShowDialog();
        }
        #endregion

        #region Font Dialog
        static void ShowFontDlg()
        {
            try
            {
                var dlg = new Forms.FontDialog();
                dlg.ShowColor = false; dlg.ShowEffects = false;
                dlg.MinSize = MIN_FONT; dlg.MaxSize = MAX_FONT;
                dlg.FontMustExist = true; dlg.AllowVerticalFonts = false;
                try { dlg.Font = new System.Drawing.Font(txtEditor.FontFamily.Source, (float)Math.Round(BaseFontSize * 72 / 96)); }
                catch { dlg.Font = new System.Drawing.Font(DEF_FONT_FAMILY, 11); }
                try { if (dlg.ShowDialog() == Forms.DialogResult.OK) { txtEditor.FontFamily = new FontFamily(dlg.Font.FontFamily.Name); BaseFontSize = dlg.Font.Size * 96.0 / 72.0; ApplyZoom(); } }
                finally { dlg.Dispose(); }
            }
            catch { }
        }
        #endregion

        #region Editor Settings
        static void ShowEditorCfg()
        {
            var d = new System.Windows.Window();
            d.Title = "Editor Settings"; d.SizeToContent = SizeToContent.WidthAndHeight;
            d.WindowStartupLocation = WindowStartupLocation.CenterOwner; d.Owner = Window;
            var brFg = GetBrush(COLOR_EDITOR_FG); var brBdr = GetBrush(COLOR_BORDER_LIT);
            var ob = new Border(); ob.Padding = new Thickness(14, 12, 14, 12); ob.MinWidth = 290;
            var st = new StackPanel();
            var cm = txtEditor.Margin; double cs = BaseLineSpacing;
            var mgb = new GroupBox(); mgb.Header = " Margins (px) "; mgb.Padding = new Thickness(8, 4, 8, 4); mgb.Margin = new Thickness(0, 0, 0, 6); mgb.FontSize = 11; mgb.Foreground = brFg; mgb.BorderThickness = new Thickness(1); mgb.BorderBrush = brBdr;
            var mg = new Grid(); mg.RowDefinitions.Add(new RowDefinition()); mg.RowDefinitions.Add(new RowDefinition());
            var c0 = new ColumnDefinition(); c0.Width = new GridLength(45);
            var c1 = new ColumnDefinition(); c1.Width = new GridLength(1, GridUnitType.Star);
            mg.ColumnDefinitions.Add(c0); mg.ColumnDefinitions.Add(c1);
            var ll = new Label(); ll.Content = "Left:"; ll.VerticalAlignment = VerticalAlignment.Center; ll.FontSize = 11; ll.Padding = new Thickness(0); ll.Foreground = brFg;
            Grid.SetRow(ll, 0); Grid.SetColumn(ll, 0); mg.Children.Add(ll);
            var tL = NewDarkTextBox(); tL.Width = 60; tL.Height = 20; tL.FontSize = 11; tL.Margin = new Thickness(0, 2, 0, 2); tL.HorizontalAlignment = HorizontalAlignment.Left; tL.Padding = new Thickness(3, 0, 3, 0); tL.Text = ((int)cm.Left).ToString();
            Grid.SetRow(tL, 0); Grid.SetColumn(tL, 1); mg.Children.Add(tL);
            var rl = new Label(); rl.Content = "Right:"; rl.VerticalAlignment = VerticalAlignment.Center; rl.FontSize = 11; rl.Padding = new Thickness(0); rl.Foreground = brFg;
            Grid.SetRow(rl, 1); Grid.SetColumn(rl, 0); mg.Children.Add(rl);
            var tR = NewDarkTextBox(); tR.Width = 60; tR.Height = 20; tR.FontSize = 11; tR.Margin = new Thickness(0, 2, 0, 2); tR.HorizontalAlignment = HorizontalAlignment.Left; tR.Padding = new Thickness(3, 0, 3, 0); tR.Text = ((int)cm.Right).ToString();
            Grid.SetRow(tR, 1); Grid.SetColumn(tR, 1); mg.Children.Add(tR);
            mgb.Content = mg; st.Children.Add(mgb);
            var sgb = new GroupBox(); sgb.Header = " Line Spacing (" + MIN_SPACING + " - " + MAX_SPACING + ") "; sgb.Padding = new Thickness(8, 4, 8, 4); sgb.Margin = new Thickness(0, 0, 0, 6); sgb.FontSize = 11; sgb.Foreground = brFg; sgb.BorderThickness = new Thickness(1); sgb.BorderBrush = brBdr;
            var sg = new StackPanel(); sg.Orientation = Orientation.Horizontal;
            var sl = new Label(); sl.Content = "Multiplier:"; sl.VerticalAlignment = VerticalAlignment.Center; sl.FontSize = 11; sl.Padding = new Thickness(0); sl.Foreground = brFg;
            sg.Children.Add(sl);
            var tS = NewDarkTextBox(); tS.Width = 60; tS.Height = 20; tS.FontSize = 11; tS.Margin = new Thickness(8, 0, 0, 0); tS.Padding = new Thickness(3, 0, 3, 0); tS.Text = cs.ToString("F1", CultureInfo.InvariantCulture);
            sg.Children.Add(tS); sgb.Content = sg; st.Children.Add(sgb);
            var bp = new StackPanel(); bp.Orientation = Orientation.Horizontal; bp.HorizontalAlignment = HorizontalAlignment.Left; bp.Margin = new Thickness(0, 6, 0, 0);
            var bOK = NewDarkButton("OK", 65, 22); bOK.FontSize = 11; bOK.IsDefault = true; bOK.Margin = new Thickness(0, 0, 5, 0); bp.Children.Add(bOK);
            var bAp = NewDarkButton("Apply", 65, 22); bAp.FontSize = 11; bAp.Margin = new Thickness(0, 0, 5, 0); bp.Children.Add(bAp);
            var bCa = NewDarkButton("Cancel", 65, 22); bCa.FontSize = 11; bCa.IsCancel = true; bp.Children.Add(bCa);
            st.Children.Add(bp); ob.Child = st; BuildDarkDialog(d, ob);
            var om = cm; double os = cs;
            System.Func<bool> tryApply = delegate()
            {
                int lv = ToIntVal(tL.Text, -1);
                if (lv < MIN_MARGIN || lv > MAX_MARGIN) { MessageBox.Show("Left margin must be " + MIN_MARGIN + "-" + MAX_MARGIN + ".", "Invalid", MessageBoxButton.OK, MessageBoxImage.Warning); tL.Focus(); tL.SelectAll(); return false; }
                int rv = ToIntVal(tR.Text, -1);
                if (rv < MIN_MARGIN || rv > MAX_MARGIN) { MessageBox.Show("Right margin must be " + MIN_MARGIN + "-" + MAX_MARGIN + ".", "Invalid", MessageBoxButton.OK, MessageBoxImage.Warning); tR.Focus(); tR.SelectAll(); return false; }
                double sv = ToDoubleVal(tS.Text, -1);
                if (sv < MIN_SPACING || sv > MAX_SPACING) { MessageBox.Show("Line spacing must be " + MIN_SPACING + "-" + MAX_SPACING + ".", "Invalid", MessageBoxButton.OK, MessageBoxImage.Warning); tS.Focus(); tS.SelectAll(); return false; }
                txtEditor.Margin = new Thickness(lv, 0, rv, 0);
                BaseLineSpacing = sv; ApplyLineSpacingToEditor();
                Settings["Editor"]["MarginLeft"] = lv.ToString();
                Settings["Editor"]["MarginRight"] = rv.ToString();
                Settings["Editor"]["LineSpacing"] = sv.ToString("F1", CultureInfo.InvariantCulture);
                return true;
            };
            System.Action restore = delegate() { txtEditor.Margin = om; BaseLineSpacing = os; ApplyLineSpacingToEditor(); };
            bAp.Click += delegate(object s, System.Windows.RoutedEventArgs e) { tryApply(); };
            bOK.Click += delegate(object s, System.Windows.RoutedEventArgs e) { if (tryApply()) { WriteIni(SettingsFilePath, Settings); d.DialogResult = true; d.Close(); } };
            bCa.Click += delegate(object s, System.Windows.RoutedEventArgs e) { restore(); d.Close(); };
            d.Closing += delegate(object s, System.ComponentModel.CancelEventArgs e) { if (d.DialogResult != true) restore(); };
            tL.Focus(); tL.SelectAll();
            d.ShowDialog();
        }
        #endregion

        #region View
        static void SetWordWrap(bool on)
        {
            if (on) { txtEditor.TextWrapping = TextWrapping.Wrap; txtEditor.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled; }
            else { txtEditor.TextWrapping = TextWrapping.NoWrap; txtEditor.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto; }
        }
        static void SetStatusBar(bool on)
        {
            var v = on ? Visibility.Visible : Visibility.Collapsed;
            statusBar.Visibility = v; statusBorder.Visibility = v;
        }
        #endregion

        #region XAML
        const string MainXaml = @"<Window x:Name='mainWindow' xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' Title='Untitled - Notepad' WindowStartupLocation='CenterScreen' MinWidth='400' MinHeight='300' Background='#2D2D30'>
<WindowChrome.WindowChrome><WindowChrome CaptionHeight='32' ResizeBorderThickness='6' CornerRadius='0' GlassFrameThickness='0' UseAeroCaptionButtons='False'/></WindowChrome.WindowChrome>
<Window.Resources>
<Style TargetType='ScrollViewer'><Setter Property='Background' Value='#1E1E1E'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollViewer'><Grid Background='{TemplateBinding Background}'><Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition Height='*'/><RowDefinition Height='Auto'/></Grid.RowDefinitions><ScrollContentPresenter x:Name='PART_ScrollContentPresenter' Grid.Column='0' Grid.Row='0' Content='{TemplateBinding Content}' ContentTemplate='{TemplateBinding ContentTemplate}' CanContentScroll='{TemplateBinding CanContentScroll}' Margin='{TemplateBinding Padding}'/><ScrollBar x:Name='PART_VerticalScrollBar' Grid.Column='1' Grid.Row='0' Value='{TemplateBinding VerticalOffset}' Maximum='{TemplateBinding ScrollableHeight}' ViewportSize='{TemplateBinding ViewportHeight}' Visibility='{TemplateBinding ComputedVerticalScrollBarVisibility}'/><ScrollBar x:Name='PART_HorizontalScrollBar' Grid.Column='0' Grid.Row='1' Orientation='Horizontal' Value='{TemplateBinding HorizontalOffset}' Maximum='{TemplateBinding ScrollableWidth}' ViewportSize='{TemplateBinding ViewportWidth}' Visibility='{TemplateBinding ComputedHorizontalScrollBarVisibility}'/><Rectangle Grid.Column='1' Grid.Row='1' Fill='#1E1E1E'/></Grid></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='ScrollBarThumb' TargetType='Thumb'><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Thumb'><Border Background='#4D4D4D' BorderBrush='#1E1E1E' BorderThickness='1'/></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='ScrollBarButton' TargetType='RepeatButton'><Setter Property='Background' Value='#1E1E1E'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='RepeatButton'><Border Background='{TemplateBinding Background}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='ScrollBarPageButton' TargetType='RepeatButton'><Setter Property='Background' Value='Transparent'/><Setter Property='BorderThickness' Value='0'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='RepeatButton'><Border Background='Transparent'/></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='ScrollBar'><Setter Property='Background' Value='#1E1E1E'/><Setter Property='Width' Value='17'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'><Grid Background='{TemplateBinding Background}'><Grid.RowDefinitions><RowDefinition Height='17'/><RowDefinition Height='0.00001*'/><RowDefinition Height='17'/></Grid.RowDefinitions><RepeatButton Grid.Row='0' Style='{StaticResource ScrollBarButton}' Command='ScrollBar.LineUpCommand'><Path Data='M 2,5 L 5,2 L 8,5' Stroke='#999999' StrokeThickness='1.5'/></RepeatButton><Track x:Name='PART_Track' Grid.Row='1' IsDirectionReversed='true'><Track.DecreaseRepeatButton><RepeatButton Command='ScrollBar.PageUpCommand' Style='{StaticResource ScrollBarPageButton}'/></Track.DecreaseRepeatButton><Track.IncreaseRepeatButton><RepeatButton Command='ScrollBar.PageDownCommand' Style='{StaticResource ScrollBarPageButton}'/></Track.IncreaseRepeatButton><Track.Thumb><Thumb Style='{StaticResource ScrollBarThumb}'/></Track.Thumb></Track><RepeatButton Grid.Row='2' Style='{StaticResource ScrollBarButton}' Command='ScrollBar.LineDownCommand'><Path Data='M 2,2 L 5,5 L 8,2' Stroke='#999999' StrokeThickness='1.5'/></RepeatButton></Grid></ControlTemplate></Setter.Value></Setter><Style.Triggers><Trigger Property='Orientation' Value='Horizontal'><Setter Property='Width' Value='Auto'/><Setter Property='Height' Value='17'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'><Grid Background='{TemplateBinding Background}'><Grid.ColumnDefinitions><ColumnDefinition Width='17'/><ColumnDefinition Width='0.00001*'/><ColumnDefinition Width='17'/></Grid.ColumnDefinitions><RepeatButton Grid.Column='0' Style='{StaticResource ScrollBarButton}' Command='ScrollBar.LineLeftCommand'><Path Data='M 5,2 L 2,5 L 5,8' Stroke='#999999' StrokeThickness='1.5'/></RepeatButton><Track x:Name='PART_Track' Grid.Column='1' IsDirectionReversed='False'><Track.DecreaseRepeatButton><RepeatButton Command='ScrollBar.PageLeftCommand' Style='{StaticResource ScrollBarPageButton}'/></Track.DecreaseRepeatButton><Track.IncreaseRepeatButton><RepeatButton Command='ScrollBar.PageRightCommand' Style='{StaticResource ScrollBarPageButton}'/></Track.IncreaseRepeatButton><Track.Thumb><Thumb Style='{StaticResource ScrollBarThumb}'/></Track.Thumb></Track><RepeatButton Grid.Column='2' Style='{StaticResource ScrollBarButton}' Command='ScrollBar.LineRightCommand'><Path Data='M 2,2 L 5,5 L 2,8' Stroke='#999999' StrokeThickness='1.5'/></RepeatButton></Grid></ControlTemplate></Setter.Value></Setter></Trigger></Style.Triggers></Style>
<Style TargetType='Menu'><Setter Property='Background' Value='#2D2D30'/><Setter Property='Foreground' Value='#D4D4D4'/></Style>
<Style TargetType='ContextMenu'><Setter Property='SnapsToDevicePixels' Value='True'/><Setter Property='OverridesDefaultStyle' Value='True'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ContextMenu'><Border Background='#2D2D30' BorderBrush='#3F3F46' BorderThickness='1' Padding='0,2'><ItemsPresenter Grid.IsSharedSizeScope='True' KeyboardNavigation.DirectionalNavigation='Cycle'/></Border></ControlTemplate></Setter.Value></Setter></Style>
<Style TargetType='Separator'><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Separator'><Rectangle Height='1' Fill='#3F3F46' Margin='25,3,5,3'/></ControlTemplate></Setter.Value></Setter></Style>
<ControlTemplate x:Key='TopLevelHeaderTemplate' TargetType='MenuItem'><Border x:Name='Border' Background='Transparent' SnapsToDevicePixels='True'><Grid><ContentPresenter Margin='{TemplateBinding Padding}' RecognizesAccessKey='True' ContentSource='Header' VerticalAlignment='Center'/><Popup x:Name='Popup' Placement='Bottom' IsOpen='{TemplateBinding IsSubmenuOpen}' AllowsTransparency='True' Focusable='False'><Border Background='#2D2D30' BorderBrush='#3F3F46' BorderThickness='1'><ItemsPresenter Grid.IsSharedSizeScope='True' KeyboardNavigation.DirectionalNavigation='Cycle' Margin='0,2'/></Border></Popup></Grid></Border><ControlTemplate.Triggers><Trigger Property='IsSubmenuOpen' Value='True'><Setter Property='Background' TargetName='Border' Value='#3E3E42'/><Setter Property='Foreground' Value='#FFFFFF'/></Trigger><Trigger Property='IsHighlighted' Value='True'><Setter Property='Background' TargetName='Border' Value='#3E3E42'/><Setter Property='Foreground' Value='#FFFFFF'/></Trigger></ControlTemplate.Triggers></ControlTemplate>
<ControlTemplate x:Key='SubmenuItemTemplate' TargetType='MenuItem'><Border x:Name='Border' Background='{TemplateBinding Background}' SnapsToDevicePixels='True'><Grid><Grid.ColumnDefinitions><ColumnDefinition x:Name='Col0' MinWidth='25' Width='Auto' SharedSizeGroup='MenuItemIconColumnGroup'/><ColumnDefinition Width='Auto' SharedSizeGroup='MenuTextColumnGroup'/><ColumnDefinition Width='Auto' SharedSizeGroup='MenuItemIGTColumnGroup'/><ColumnDefinition x:Name='Col3' Width='15'/></Grid.ColumnDefinitions><ContentPresenter Grid.Column='0' x:Name='Icon' Margin='5,0' VerticalAlignment='Center' ContentSource='Icon'/><Path x:Name='CheckMark' Visibility='Hidden' Grid.Column='0' Margin='5,0' VerticalAlignment='Center' HorizontalAlignment='Center' Data='M 0,4 L 3,7 L 8,0' Stroke='#D4D4D4' StrokeThickness='2'/><ContentPresenter Grid.Column='1' x:Name='HeaderHost' Margin='{TemplateBinding Padding}' RecognizesAccessKey='True' ContentSource='Header' VerticalAlignment='Center'/><TextBlock Grid.Column='2' x:Name='InputGestureText' Margin='20,0,10,0' Text='{TemplateBinding InputGestureText}' VerticalAlignment='Center' Foreground='#888888'/><Path Grid.Column='3' x:Name='RightArrow' Visibility='Hidden' Margin='0,0,5,0' VerticalAlignment='Center' HorizontalAlignment='Right' Data='M 0,0 L 4,3 L 0,6 Z' Fill='#D4D4D4'/><Popup x:Name='Popup' Placement='Right' HorizontalOffset='0' VerticalOffset='-2' IsOpen='{TemplateBinding IsSubmenuOpen}' AllowsTransparency='True' Focusable='False'><Border x:Name='SubmenuBorder' Background='#2D2D30' BorderBrush='#3F3F46' BorderThickness='1'><ItemsPresenter Grid.IsSharedSizeScope='True' KeyboardNavigation.DirectionalNavigation='Cycle' Margin='0,2'/></Border></Popup></Grid></Border><ControlTemplate.Triggers><Trigger Property='Role' Value='SubmenuHeader'><Setter TargetName='RightArrow' Property='Visibility' Value='Visible'/></Trigger><Trigger Property='IsChecked' Value='True'><Setter TargetName='CheckMark' Property='Visibility' Value='Visible'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Foreground' Value='#666666'/></Trigger><MultiTrigger><MultiTrigger.Conditions><Condition Property='IsHighlighted' Value='True'/><Condition Property='IsEnabled' Value='True'/></MultiTrigger.Conditions><Setter Property='Background' TargetName='Border' Value='#3E3E42'/><Setter Property='Foreground' Value='#FFFFFF'/></MultiTrigger></ControlTemplate.Triggers></ControlTemplate>
<Style TargetType='MenuItem'><Setter Property='Background' Value='#2D2D30'/><Setter Property='Foreground' Value='#D4D4D4'/><Setter Property='Padding' Value='5,3'/><Setter Property='Template' Value='{StaticResource SubmenuItemTemplate}'/><Style.Triggers><Trigger Property='Role' Value='TopLevelHeader'><Setter Property='Template' Value='{StaticResource TopLevelHeaderTemplate}'/><Setter Property='Padding' Value='8,4'/></Trigger><Trigger Property='Role' Value='TopLevelItem'><Setter Property='Template' Value='{StaticResource TopLevelHeaderTemplate}'/><Setter Property='Padding' Value='8,4'/></Trigger></Style.Triggers></Style>
<Style x:Key='TitleBarButton' TargetType='Button'><Setter Property='Background' Value='#1E1E1E'/><Setter Property='Foreground' Value='#D4D4D4'/><Setter Property='Width' Value='46'/><Setter Property='BorderThickness' Value='0'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border Background='{TemplateBinding Background}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter Property='Background' Value='#3E3E42'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='TitleBarCloseButton' TargetType='Button' BasedOn='{StaticResource TitleBarButton}'><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'><Border Background='{TemplateBinding Background}'><ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter Property='Background' Value='#E81123'/><Setter Property='Foreground' Value='White'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
<Style x:Key='SBText' TargetType='TextBlock'><Setter Property='FontSize' Value='11'/><Setter Property='Foreground' Value='#999999'/><Setter Property='VerticalAlignment' Value='Center'/></Style>
<Style x:Key='SBSep' TargetType='Rectangle'><Setter Property='Width' Value='1'/><Setter Property='Height' Value='14'/><Setter Property='Fill' Value='#555555'/><Setter Property='VerticalAlignment' Value='Center'/></Style>
</Window.Resources>
<Grid x:Name='RootGrid'><Grid.Style><Style TargetType='Grid'><Style.Triggers><DataTrigger Binding='{Binding WindowState, RelativeSource={RelativeSource AncestorType=Window}}' Value='Maximized'><Setter Property='Margin' Value='6'/></DataTrigger></Style.Triggers></Style></Grid.Style>
<Grid.RowDefinitions><RowDefinition Height='32'/><RowDefinition Height='Auto'/><RowDefinition Height='*'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
<Grid Grid.Row='0' Background='#1E1E1E'><Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
<Viewbox Grid.Column='0' Width='14' Height='14' Margin='10,0,5,0' VerticalAlignment='Center'><Canvas Width='16' Height='16'><Path Data='M2,0 L10,0 L14,4 L14,16 L2,16 Z' Stroke='#D4D4D4' StrokeThickness='1.5' Fill='Transparent'/><Path Data='M10,0 L10,4 L14,4' Stroke='#D4D4D4' StrokeThickness='1.5' Fill='Transparent'/><Path Data='M4,7 L10,7 M4,10 L12,10 M4,13 L9,13' Stroke='#D4D4D4' StrokeThickness='1.5' StrokeStartLineCap='Round' StrokeEndLineCap='Round'/></Canvas></Viewbox>
<TextBlock Name='txtWindowTitle' Grid.Column='1' Text='Untitled - Notepad' Foreground='#D4D4D4' VerticalAlignment='Center' Margin='5,0,0,0' FontSize='12'/>
<StackPanel Grid.Column='2' Orientation='Horizontal' WindowChrome.IsHitTestVisibleInChrome='True'>
<Button Name='btnMin' Style='{StaticResource TitleBarButton}'><Path Data='M 0.5,5.5 L 9.5,5.5' Stroke='{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}' StrokeThickness='1' SnapsToDevicePixels='True'/></Button>
<Button Name='btnMax' Style='{StaticResource TitleBarButton}'><Grid Width='12' Height='12'><Path Data='M 0.5,0.5 L 9.5,0.5 L 9.5,9.5 L 0.5,9.5 Z' Stroke='{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}' StrokeThickness='1' Fill='Transparent' SnapsToDevicePixels='True'><Path.Style><Style TargetType='Path'><Setter Property='Visibility' Value='Visible'/><Style.Triggers><DataTrigger Binding='{Binding WindowState, RelativeSource={RelativeSource AncestorType=Window}}' Value='Maximized'><Setter Property='Visibility' Value='Collapsed'/></DataTrigger></Style.Triggers></Style></Path.Style></Path><Grid><Grid.Style><Style TargetType='Grid'><Setter Property='Visibility' Value='Collapsed'/><Style.Triggers><DataTrigger Binding='{Binding WindowState, RelativeSource={RelativeSource AncestorType=Window}}' Value='Maximized'><Setter Property='Visibility' Value='Visible'/></DataTrigger></Style.Triggers></Style></Grid.Style><Path Data='M 0.5,0.5 L 7.5,0.5 L 7.5,7.5 L 0.5,7.5 Z' Stroke='{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}' StrokeThickness='1' Fill='Transparent' SnapsToDevicePixels='True' Margin='3,0,0,3'/><Path Data='M 0.5,0.5 L 7.5,0.5 L 7.5,7.5 L 0.5,7.5 Z' Stroke='{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}' StrokeThickness='1' Fill='{Binding Background, RelativeSource={RelativeSource AncestorType=Button}}' SnapsToDevicePixels='True' Margin='0,3,3,0'/></Grid></Grid></Button>
<Button Name='btnClose' Style='{StaticResource TitleBarCloseButton}'><Path Data='M 0.5,0.5 L 9.5,9.5 M 0.5,9.5 L 9.5,0.5' Stroke='{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}' StrokeThickness='1.2' SnapsToDevicePixels='True'/></Button>
</StackPanel></Grid>
<Border Grid.Row='1' BorderBrush='#3F3F46' BorderThickness='0,0,0,1'><Menu Name='menuBar' Padding='4,0,0,0'>
<MenuItem Header='_File'><MenuItem Header='_New' Name='mnuNew' InputGestureText='Ctrl+N'/><MenuItem Header='_Open...' Name='mnuOpen' InputGestureText='Ctrl+O'/><MenuItem Header='_Save' Name='mnuSave' InputGestureText='Ctrl+S'/><MenuItem Header='Save _As...' Name='mnuSaveAs' InputGestureText='Ctrl+Shift+S'/><Separator/><MenuItem Header='E_xit' Name='mnuExit' InputGestureText='Alt+F4'/></MenuItem>
<MenuItem Header='_Edit'><MenuItem Header='_Undo' Name='mnuUndo' InputGestureText='Ctrl+Z'/><MenuItem Header='_Redo' Name='mnuRedo' InputGestureText='Ctrl+Y'/><Separator/><MenuItem Header='Cu_t' Name='mnuCut' InputGestureText='Ctrl+X'/><MenuItem Header='_Copy' Name='mnuCopy' InputGestureText='Ctrl+C'/><MenuItem Header='_Paste' Name='mnuPaste' InputGestureText='Ctrl+V'/><MenuItem Header='De_lete' Name='mnuDelete' InputGestureText='Del'/><Separator/><MenuItem Header='_Find...' Name='mnuFind' InputGestureText='Ctrl+F'/><MenuItem Header='Find _Next' Name='mnuFindNext' InputGestureText='F3'/><MenuItem Header='_Replace...' Name='mnuReplace' InputGestureText='Ctrl+H'/><Separator/><MenuItem Header='Select _All' Name='mnuSelAll' InputGestureText='Ctrl+A'/><MenuItem Header='Time/_Date' Name='mnuDate' InputGestureText='F5'/></MenuItem>
<MenuItem Header='F_ormat'><MenuItem Header='_Word Wrap' Name='mnuWordWrap' IsCheckable='True'/><MenuItem Header='_Font...' Name='mnuFont'/><Separator/><MenuItem Header='_Zoom'><MenuItem Header='Zoom _In' Name='mnuZoomIn' InputGestureText='Ctrl++'/><MenuItem Header='Zoom _Out' Name='mnuZoomOut' InputGestureText='Ctrl+-'/><MenuItem Header='_Reset (100%)' Name='mnuZoomReset' InputGestureText='Ctrl+0'/></MenuItem><Separator/><MenuItem Header='_Line Endings' Name='mnuLineEndings'><MenuItem Header='Windows (CRLF)' Name='mnuEolCRLF' ToolTip='Carriage Return + Line Feed.'/><MenuItem Header='Unix (LF)' Name='mnuEolLF' ToolTip='Line Feed only.'/><MenuItem Header='Macintosh (CR)' Name='mnuEolCR' ToolTip='Carriage Return only.'/></MenuItem><MenuItem Header='_Encoding' Name='mnuEncoding'><MenuItem Header='UTF-8 (no BOM)' Name='mnuEncUtf8'/><MenuItem Header='UTF-8 (BOM)' Name='mnuEncUtf8Bom'/><Separator/><MenuItem Header='UTF-16 LE (BOM)' Name='mnuEncUtf16LE'/><MenuItem Header='UTF-16 BE (BOM)' Name='mnuEncUtf16BE'/></MenuItem><Separator/><MenuItem Header='_Editor Settings...' Name='mnuEditorCfg'/></MenuItem>
<MenuItem Header='_View'><MenuItem Header='_Status Bar' Name='mnuStatusBar' IsCheckable='True' IsChecked='True'/></MenuItem>
</Menu></Border>
<Border Grid.Row='2' Background='#2D2D30'><TextBox Name='txtEditor' AcceptsReturn='True' AcceptsTab='True' VerticalScrollBarVisibility='Auto' HorizontalScrollBarVisibility='Auto' BorderThickness='0' Background='#1E1E1E' Foreground='#D4D4D4' Padding='12,10' UndoLimit='100' IsUndoEnabled='True' CaretBrush='#D4D4D4' ScrollViewer.CanContentScroll='False'><TextBox.ContextMenu><ContextMenu FontFamily='Segoe UI' FontSize='12'><MenuItem Name='ctxCut' Header='Cu_t' InputGestureText='Ctrl+X'/><MenuItem Name='ctxCopy' Header='_Copy' InputGestureText='Ctrl+C'/><MenuItem Name='ctxPaste' Header='_Paste' InputGestureText='Ctrl+V'/><Separator/><MenuItem Name='ctxSelAll' Header='Select _All' InputGestureText='Ctrl+A'/></ContextMenu></TextBox.ContextMenu></TextBox></Border>
<Border Grid.Row='3' Name='statusBorder' BorderBrush='#3F3F46' BorderThickness='0,1,0,0'><Border BorderBrush='#1E1E1E' BorderThickness='0,1,0,0'><StatusBar Name='statusBar' Background='#2D2D30' Foreground='#D4D4D4' Padding='6,1' Height='22'>
<StatusBar.ItemsPanel><ItemsPanelTemplate><DockPanel LastChildFill='False'/></ItemsPanelTemplate></StatusBar.ItemsPanel>
<StatusBarItem DockPanel.Dock='Right' Padding='8,0'><TextBlock Name='txtEnc' Text='UTF-8' Style='{StaticResource SBText}'/></StatusBarItem><StatusBarItem DockPanel.Dock='Right' Padding='0'><Rectangle Style='{StaticResource SBSep}'/></StatusBarItem>
<StatusBarItem DockPanel.Dock='Right' Padding='8,0'><TextBlock Name='txtEol' Text='Windows (CRLF)' Style='{StaticResource SBText}'/></StatusBarItem><StatusBarItem DockPanel.Dock='Right' Padding='0'><Rectangle Style='{StaticResource SBSep}'/></StatusBarItem>
<StatusBarItem DockPanel.Dock='Right' Padding='8,0'><TextBlock Name='txtZoom' Text='100%' Style='{StaticResource SBText}'/></StatusBarItem><StatusBarItem DockPanel.Dock='Right' Padding='0'><Rectangle Style='{StaticResource SBSep}'/></StatusBarItem>
<StatusBarItem DockPanel.Dock='Right' Padding='8,0'><TextBlock Name='txtLines' Text='Lines: 1' Style='{StaticResource SBText}'/></StatusBarItem><StatusBarItem DockPanel.Dock='Right' Padding='0'><Rectangle Style='{StaticResource SBSep}'/></StatusBarItem>
<StatusBarItem DockPanel.Dock='Right' Padding='8,0'><TextBlock Name='txtChars' Text='Chars: 0' Style='{StaticResource SBText}'/></StatusBarItem><StatusBarItem DockPanel.Dock='Right' Padding='0'><Rectangle Style='{StaticResource SBSep}'/></StatusBarItem>
<StatusBarItem DockPanel.Dock='Right' Padding='8,0'><TextBlock Name='txtWords' Text='Words: 0' Style='{StaticResource SBText}'/></StatusBarItem><StatusBarItem DockPanel.Dock='Right' Padding='0'><Rectangle Style='{StaticResource SBSep}'/></StatusBarItem>
<StatusBarItem DockPanel.Dock='Right' Padding='8,0,10,0'><TextBlock Name='txtPos' Text='Ln 1, Col 1' Style='{StaticResource SBText}'/></StatusBarItem>
</StatusBar></Border></Border></Grid></Window>";
        #endregion

        #region Entry Point
        [STAThread]
        public static void Main()
        {
            Run();
        }

        public static void Run()
        {
            Console.WriteLine("[C# Debug] App.Run() started.");
            try {
                SettingsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), SETTINGS_FOLDER);
                SettingsFilePath = Path.Combine(SettingsDir, SETTINGS_FILE);
                Console.WriteLine("[C# Debug] Settings path: " + SettingsFilePath);
                
                MinMaxInfoPtr = Marshal.AllocHGlobal(40);
                for (int i = 0; i < 40; i++) Marshal.WriteByte(MinMaxInfoPtr, i, 0);
                Marshal.WriteInt32(MinMaxInfoPtr, 0, 40);
                
                Console.WriteLine("[C# Debug] Ensuring settings directory exists...");
                EnsureSettingsDir();
                
                Console.WriteLine("[C# Debug] Loading settings...");
                LoadSettings();
                
                Console.WriteLine("[C# Debug] Extracting notepad icon...");
                AppIcon = ExtractNotepadIcon();
                
                Console.WriteLine("[C# Debug] Parsing main window XAML...");
                try { Window = (Window)XamlReader.Parse(MainXaml); }
                catch (Exception ex) { 
                    Console.WriteLine("[C# Debug] XAML parsing failed: " + ex.Message);
                    MessageBox.Show("Failed to load UI: " + ex.Message, "Fatal Error", MessageBoxButton.OK, MessageBoxImage.Error); 
                    return; 
                }
                Console.WriteLine("[C# Debug] XAML parsed successfully.");
                
                ApplyIconVal(Window);
                
                Console.WriteLine("[C# Debug] Binding controls by name...");
                txtEditor = (TextBox)Window.FindName("txtEditor");
                txtWindowTitle = (TextBlock)Window.FindName("txtWindowTitle");
                txtPos = (TextBlock)Window.FindName("txtPos");
                txtWords = (TextBlock)Window.FindName("txtWords");
                txtChars = (TextBlock)Window.FindName("txtChars");
                txtLines = (TextBlock)Window.FindName("txtLines");
                txtEnc = (TextBlock)Window.FindName("txtEnc");
                txtEol = (TextBlock)Window.FindName("txtEol");
                txtZoom = (TextBlock)Window.FindName("txtZoom");
                statusBar = (StatusBar)Window.FindName("statusBar");
                statusBorder = (Border)Window.FindName("statusBorder");
                mnuNew = (MenuItem)Window.FindName("mnuNew");
                mnuOpen = (MenuItem)Window.FindName("mnuOpen");
                mnuSave = (MenuItem)Window.FindName("mnuSave");
                mnuSaveAs = (MenuItem)Window.FindName("mnuSaveAs");
                mnuExit = (MenuItem)Window.FindName("mnuExit");
                mnuUndo = (MenuItem)Window.FindName("mnuUndo");
                mnuRedo = (MenuItem)Window.FindName("mnuRedo");
                mnuCut = (MenuItem)Window.FindName("mnuCut");
                mnuCopy = (MenuItem)Window.FindName("mnuCopy");
                mnuPaste = (MenuItem)Window.FindName("mnuPaste");
                mnuDelete = (MenuItem)Window.FindName("mnuDelete");
                mnuFind = (MenuItem)Window.FindName("mnuFind");
                mnuFindNext = (MenuItem)Window.FindName("mnuFindNext");
                mnuReplace = (MenuItem)Window.FindName("mnuReplace");
                mnuSelAll = (MenuItem)Window.FindName("mnuSelAll");
                mnuDate = (MenuItem)Window.FindName("mnuDate");
                mnuWordWrap = (MenuItem)Window.FindName("mnuWordWrap");
                mnuFont = (MenuItem)Window.FindName("mnuFont");
                mnuEditorCfg = (MenuItem)Window.FindName("mnuEditorCfg");
                mnuStatusBar = (MenuItem)Window.FindName("mnuStatusBar");
                mnuZoomIn = (MenuItem)Window.FindName("mnuZoomIn");
                mnuZoomOut = (MenuItem)Window.FindName("mnuZoomOut");
                mnuZoomReset = (MenuItem)Window.FindName("mnuZoomReset");
                mnuEolCRLF = (MenuItem)Window.FindName("mnuEolCRLF");
                mnuEolLF = (MenuItem)Window.FindName("mnuEolLF");
                mnuEolCR = (MenuItem)Window.FindName("mnuEolCR");
                mnuEncUtf8 = (MenuItem)Window.FindName("mnuEncUtf8");
                mnuEncUtf8Bom = (MenuItem)Window.FindName("mnuEncUtf8Bom");
                mnuEncUtf16LE = (MenuItem)Window.FindName("mnuEncUtf16LE");
                mnuEncUtf16BE = (MenuItem)Window.FindName("mnuEncUtf16BE");
                btnMin = (Button)Window.FindName("btnMin");
                btnMax = (Button)Window.FindName("btnMax");
                btnClose = (Button)Window.FindName("btnClose");
                ctxCut = (MenuItem)Window.FindName("ctxCut");
                ctxCopy = (MenuItem)Window.FindName("ctxCopy");
                ctxPaste = (MenuItem)Window.FindName("ctxPaste");
                ctxSelAll = (MenuItem)Window.FindName("ctxSelAll");
                Console.WriteLine("[C# Debug] Controls bound.");

                try
                {
                    Console.WriteLine("[C# Debug] Applying settings to UI...");
                    Window.Width = ClampD(ToDoubleVal(Settings["Window"]["Width"], DEF_WINDOW_W), MIN_WINDOW_W, MAX_WINDOW_W);
                    Window.Height = ClampD(ToDoubleVal(Settings["Window"]["Height"], DEF_WINDOW_H), MIN_WINDOW_H, MAX_WINDOW_H);
                    string fam = TestFont(Settings["Font"]["Family"]) ? Settings["Font"]["Family"] : DEF_FONT_FAMILY;
                    txtEditor.FontFamily = new FontFamily(fam);
                    double fsize = ClampD(ToDoubleVal(Settings["Font"]["Size"], DEF_FONT_SIZE), MIN_FONT, MAX_FONT);
                    BaseFontSize = fsize; txtEditor.FontSize = fsize;
                    txtEditor.Margin = new Thickness(ClampD(ToDoubleVal(Settings["Editor"]["MarginLeft"], DEF_MARGIN), MIN_MARGIN, MAX_MARGIN), 0, ClampD(ToDoubleVal(Settings["Editor"]["MarginRight"], DEF_MARGIN), MIN_MARGIN, MAX_MARGIN), 0);
                    BaseLineSpacing = ClampD(ToDoubleVal(Settings["Editor"]["LineSpacing"], DEF_SPACING), MIN_SPACING, MAX_SPACING);
                    ApplyLineSpacingToEditor();
                    mnuWordWrap.IsChecked = ToBoolVal(Settings["View"]["WordWrap"], false);
                    mnuStatusBar.IsChecked = ToBoolVal(Settings["View"]["StatusBar"], true);
                    Console.WriteLine("[C# Debug] UI settings applied.");
                }
                catch (Exception ex)
                {
                    Console.WriteLine("[C# Debug] Failed to apply settings: " + ex.Message);
                }

                Console.WriteLine("[C# Debug] Initializing timers...");
                LightStatusTimer = new DispatcherTimer();
                LightStatusTimer.Interval = TimeSpan.FromMilliseconds(50);
                LightStatusTimer.Tick += delegate(object s, EventArgs e) {
                    LightStatusTimer.Stop();
                    try
                    {
                        string txt = txtEditor.Text;
                        int car = Math.Max(0, Math.Min(txtEditor.CaretIndex, txt.Length));
                        int ln, col;
                        if (car == 0) { ln = 1; col = 1; }
                        else
                        {
                            string before = txt.Substring(0, car);
                            ln = (before.Length - before.Replace("\n", "").Length) + 1;
                            int nlPos = before.LastIndexOf('\n');
                            col = nlPos >= 0 ? car - nlPos : car + 1;
                        }
                        txtPos.Text = "Ln " + ln + ", Col " + col;
                    }
                    catch { }
                };

                HeavyStatusTimer = new DispatcherTimer();
                HeavyStatusTimer.Interval = TimeSpan.FromMilliseconds(500);
                HeavyStatusTimer.Tick += delegate(object s, EventArgs e) {
                    HeavyStatusTimer.Stop();
                    try
                    {
                        string txt = txtEditor.Text;
                        int len = txt != null ? txt.Length : 0;
                        int wc, lc;
                        if (len == 0) { wc = 0; lc = 1; }
                        else { lc = (txt.Length - txt.Replace("\n", "").Length) + 1; wc = Regex.Matches(txt, @"\S+").Count; }
                        txtWords.Text = "Words: " + wc;
                        txtChars.Text = "Chars: " + len;
                        txtLines.Text = "Lines: " + lc;
                        txtEol.Text = EolDisplayLabel(LineEnding);
                        txtEnc.Text = EncodingName;
                    }
                    catch { }
                };

                Console.WriteLine("[C# Debug] Wiring up events...");
                WireEvents();
                
                Console.WriteLine("[C# Debug] Showing dialog...");
                Window.ShowDialog();
                
                Console.WriteLine("[C# Debug] Window closed. Cleaning up...");
                try { LightStatusTimer.Stop(); HeavyStatusTimer.Stop(); } catch { }
                Marshal.FreeHGlobal(MinMaxInfoPtr);
                GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
                Console.WriteLine("[C# Debug] Cleanup complete. Exiting.");
            }
            catch (Exception ex) {
                Console.WriteLine("[C# Debug] FATAL UNHANDLED EXCEPTION in Run(): " + ex.ToString());
                MessageBox.Show("Fatal error: " + ex.Message, "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        static void WireEvents()
        {
            Window.SourceInitialized += delegate(object s, EventArgs e) {
                try
                {
                    var src = PresentationSource.FromVisual(Window) as HwndSource;
                    if (src == null) return;
                    src.AddHook(new HwndSourceHook(WndProc));
                }
                catch { }
            };
            btnMin.Click += delegate(object s, System.Windows.RoutedEventArgs e) { Window.WindowState = WindowState.Minimized; };
            btnMax.Click += delegate(object s, System.Windows.RoutedEventArgs e) { Window.WindowState = Window.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; };
            btnClose.Click += delegate(object s, System.Windows.RoutedEventArgs e) { Window.Close(); };
            mnuNew.Click += delegate(object s, System.Windows.RoutedEventArgs e) { DoNew(); };
            mnuOpen.Click += delegate(object s, System.Windows.RoutedEventArgs e) { DoOpen(); };
            mnuSave.Click += delegate(object s, System.Windows.RoutedEventArgs e) { DoSave(); };
            mnuSaveAs.Click += delegate(object s, System.Windows.RoutedEventArgs e) { DoSaveAs(); };
            mnuExit.Click += delegate(object s, System.Windows.RoutedEventArgs e) { Window.Close(); };
            mnuUndo.Click += delegate(object s, System.Windows.RoutedEventArgs e) { if (txtEditor.CanUndo) txtEditor.Undo(); };
            mnuRedo.Click += delegate(object s, System.Windows.RoutedEventArgs e) { if (txtEditor.CanRedo) txtEditor.Redo(); };
            mnuCut.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.Cut(); };
            mnuCopy.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.Copy(); };
            mnuPaste.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.Paste(); };
            mnuDelete.Click += delegate(object s, System.Windows.RoutedEventArgs e) { if (txtEditor.SelectionLength > 0) txtEditor.SelectedText = ""; };
            mnuFind.Click += delegate(object s, System.Windows.RoutedEventArgs e) { ShowFindDlg(); };
            mnuFindNext.Click += delegate(object s, System.Windows.RoutedEventArgs e) { DoFindNext(); };
            mnuReplace.Click += delegate(object s, System.Windows.RoutedEventArgs e) { ShowReplaceDlg(); };
            mnuSelAll.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.SelectAll(); };
            mnuDate.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.SelectedText = DateTime.Now.ToString("h:mm tt M/d/yyyy"); };
            ctxCut.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.Cut(); };
            ctxCopy.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.Copy(); };
            ctxPaste.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.Paste(); };
            ctxSelAll.Click += delegate(object s, System.Windows.RoutedEventArgs e) { txtEditor.SelectAll(); };
            mnuFont.Click += delegate(object s, System.Windows.RoutedEventArgs e) { ShowFontDlg(); };
            mnuEditorCfg.Click += delegate(object s, System.Windows.RoutedEventArgs e) { ShowEditorCfg(); };
            mnuWordWrap.Checked += delegate(object s, System.Windows.RoutedEventArgs e) { SetWordWrap(true); };
            mnuWordWrap.Unchecked += delegate(object s, System.Windows.RoutedEventArgs e) { SetWordWrap(false); };
            mnuZoomIn.Click += delegate(object s, System.Windows.RoutedEventArgs e) { ZoomIn(); };
            mnuZoomOut.Click += delegate(object s, System.Windows.RoutedEventArgs e) { ZoomOut(); };
            mnuZoomReset.Click += delegate(object s, System.Windows.RoutedEventArgs e) { ZoomReset(); };
            mnuEolCRLF.Click += delegate(object s, System.Windows.RoutedEventArgs e) { LineEnding = "CRLF"; IsModified = true; txtEol.Text = EolDisplayLabel("CRLF"); UpdateTitle(); };
            mnuEolLF.Click += delegate(object s, System.Windows.RoutedEventArgs e) { LineEnding = "LF"; IsModified = true; txtEol.Text = EolDisplayLabel("LF"); UpdateTitle(); };
            mnuEolCR.Click += delegate(object s, System.Windows.RoutedEventArgs e) { LineEnding = "CR"; IsModified = true; txtEol.Text = EolDisplayLabel("CR"); UpdateTitle(); };
            mnuEncUtf8.Click += delegate(object s, System.Windows.RoutedEventArgs e) { EncodingName = "UTF-8 (no BOM)"; IsModified = true; txtEnc.Text = "UTF-8 (no BOM)"; UpdateTitle(); };
            mnuEncUtf8Bom.Click += delegate(object s, System.Windows.RoutedEventArgs e) { EncodingName = "UTF-8 (BOM)"; IsModified = true; txtEnc.Text = "UTF-8 (BOM)"; UpdateTitle(); };
            mnuEncUtf16LE.Click += delegate(object s, System.Windows.RoutedEventArgs e) { EncodingName = "UTF-16 LE (BOM)"; IsModified = true; txtEnc.Text = "UTF-16 LE (BOM)"; UpdateTitle(); };
            mnuEncUtf16BE.Click += delegate(object s, System.Windows.RoutedEventArgs e) { EncodingName = "UTF-16 BE (BOM)"; IsModified = true; txtEnc.Text = "UTF-16 BE (BOM)"; UpdateTitle(); };
            mnuStatusBar.Checked += delegate(object s, System.Windows.RoutedEventArgs e) { SetStatusBar(true); };
            mnuStatusBar.Unchecked += delegate(object s, System.Windows.RoutedEventArgs e) { SetStatusBar(false); };

            Window.PreviewKeyDown += delegate(object s, System.Windows.Input.KeyEventArgs e) {
                var mods = Keyboard.Modifiers;
                bool ctrl = (mods & ModifierKeys.Control) != 0;
                bool shift = (mods & ModifierKeys.Shift) != 0;
                if (ctrl && !shift)
                {
                    switch (e.Key)
                    {
                        case Key.N: DoNew(); e.Handled = true; break;
                        case Key.O: DoOpen(); e.Handled = true; break;
                        case Key.S: DoSave(); e.Handled = true; break;
                        case Key.F: ShowFindDlg(); e.Handled = true; break;
                        case Key.H: ShowReplaceDlg(); e.Handled = true; break;
                        case Key.D0: case Key.NumPad0: ZoomReset(); e.Handled = true; break;
                    }
                    if (e.Key == Key.OemPlus || e.Key == Key.Add) { ZoomIn(); e.Handled = true; }
                    if (e.Key == Key.OemMinus || e.Key == Key.Subtract) { ZoomOut(); e.Handled = true; }
                }
                else if (ctrl && shift)
                {
                    if (e.Key == Key.S) { DoSaveAs(); e.Handled = true; }
                    if (e.Key == Key.OemPlus || e.Key == Key.Add) { ZoomIn(); e.Handled = true; }
                }
                else
                {
                    switch (e.Key)
                    {
                        case Key.F3: DoFindNext(); e.Handled = true; break;
                        case Key.F5: txtEditor.SelectedText = DateTime.Now.ToString("h:mm tt M/d/yyyy"); e.Handled = true; break;
                    }
                }
            };

            txtEditor.PreviewMouseWheel += delegate(object s, MouseWheelEventArgs e) {
                if ((Keyboard.Modifiers & ModifierKeys.Control) != 0)
                {
                    if (e.Delta > 0) ZoomIn(); else ZoomOut();
                    e.Handled = true; return;
                }
                if (EditorScrollViewer == null) return;
                e.Handled = true;
                double lh = (double)txtEditor.GetValue(TextBlock.LineHeightProperty);
                if (lh <= 0) lh = txtEditor.FontSize * 1.2;
                double nO = EditorScrollViewer.VerticalOffset - (e.Delta * (SCROLL_LINES_PER_DELTA / WHEEL_DELTA) * lh);
                if (nO < 0) nO = 0;
                if (nO > EditorScrollViewer.ScrollableHeight) nO = EditorScrollViewer.ScrollableHeight;
                EditorScrollViewer.ScrollToVerticalOffset(nO);
            };

            txtEditor.TextChanged += delegate(object s, TextChangedEventArgs e) { IsModified = true; UpdateTitle(); RequestStatusUpdate(); };
            txtEditor.SelectionChanged += delegate(object s, RoutedEventArgs e) { RequestStatusUpdate(); };

            Window.Loaded += delegate(object s, RoutedEventArgs e) {
                if (mnuWordWrap.IsChecked) SetWordWrap(true);
                SetStatusBar(mnuStatusBar.IsChecked);
                UpdateTitle(); RequestStatusUpdate();
                EditorScrollViewer = FindScrollViewer(txtEditor);
                txtEditor.Focus();
            };

            Window.Closing += delegate(object s, System.ComponentModel.CancelEventArgs e) {
                if (!ConfirmSave()) { e.Cancel = true; return; }
                try { LightStatusTimer.Stop(); HeavyStatusTimer.Stop(); } catch { }
                SaveSettings();
            };
        }

        static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == 0x0024)
            {
                try
                {
                    IntPtr hMon = MonitorFromWindow(hwnd, 2);
                    if (hMon != IntPtr.Zero && GetMonitorInfo(hMon, MinMaxInfoPtr))
                    {
                        int wL = Marshal.ReadInt32(MinMaxInfoPtr, 20);
                        int wT = Marshal.ReadInt32(MinMaxInfoPtr, 24);
                        int wR = Marshal.ReadInt32(MinMaxInfoPtr, 28);
                        int wB = Marshal.ReadInt32(MinMaxInfoPtr, 32);
                        double scale = PresentationSource.FromVisual(Window).CompositionTarget.TransformToDevice.M11;
                        double bp = 6 * scale;
                        int mW = (int)((wR - wL) + (bp * 2));
                        int mH = (int)((wB - wT) + (bp * 2));
                        int mX = (int)(wL - bp);
                        int mY = (int)(wT - bp);
                        Marshal.WriteInt32(lParam, 8, mW);
                        Marshal.WriteInt32(lParam, 12, mH);
                        Marshal.WriteInt32(lParam, 16, mX);
                        Marshal.WriteInt32(lParam, 20, mY);
                        handled = true;
                    }
                }
                catch { }
            }
            return IntPtr.Zero;
        }
        #endregion
    }
}
"@

# ==================== COMPILE TO EXE ====================
if (-not (Test-Path $exePath)) {
    Write-Host "[PS Debug] Compiling C# code into executable..." -ForegroundColor Cyan
    Write-Host "[PS Debug] Output Path: $exePath" -ForegroundColor DarkGray
    
    # Resolve exact file paths for required assemblies from the AppDomain
    $refPaths = @()
    foreach ($asmName in $requiredAssemblies) {
        $loaded = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -match "^$asmName," } | Select-Object -First 1
        if ($loaded -and $loaded.Location) { 
            $refPaths += $loaded.Location 
        } else {
            $refPaths += $asmName
        }
    }
    
    # Add System and System.Core explicitly
    foreach ($sysAsm in @("System", "System.Core")) {
        $loaded = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -match "^$sysAsm," } | Select-Object -First 1
        if ($loaded -and $loaded.Location -and ($refPaths -notcontains $loaded.Location)) { 
            $refPaths += $loaded.Location 
        }
    }

    Write-Host "[PS Debug] Referenced assemblies:" -ForegroundColor DarkGray
    $refPaths | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    try {
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateInMemory = $false
        $cp.GenerateExecutable = $true
        $cp.OutputAssembly = $exePath
        $cp.MainClass = "DarkNotepad.App"
        $cp.ReferencedAssemblies.AddRange($refPaths)
        $cp.CompilerOptions = "/platform:anycpu /target:winexe" # winexe prevents a console box from flashing when double-clicking
        
        $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
        $results = $provider.CompileAssemblyFromSource($cp, $code)

        if ($results.Errors.HasErrors) {
            Write-Host "[PS Debug] Fatal: C# compilation failed:" -ForegroundColor Red
            foreach ($err in $results.Errors) {
                if ($err.IsWarning) { continue }
                Write-Host "[PS Debug]   Line $($err.Line): $($err.ErrorText)" -ForegroundColor Yellow
            }
            exit 1
        } else {
            Write-Host "[PS Debug] Compilation successful! EXE created." -ForegroundColor Green
        }
    } catch {
        Write-Host "[PS Debug] Fatal: Compilation engine failed:" -ForegroundColor Red
        Write-Host "[PS Debug] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[PS Debug] EXE already exists at $exePath. Skipping compilation." -ForegroundColor DarkGray
    Write-Host "[PS Debug] (Delete the EXE to force recompilation)" -ForegroundColor DarkGray
}

# ==================== LAUNCH ====================
Write-Host "[PS Debug] Launching DarkNotepad.exe..." -ForegroundColor Cyan
Start-Process -FilePath $exePath
Write-Host "[PS Debug] Application launched." -ForegroundColor Cyan
