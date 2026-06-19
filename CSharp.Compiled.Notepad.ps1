#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OutputExe = Join-Path $PWD "Notepad.CS.exe"

$CSharpCode = @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;

namespace CSharpNotepad
{
    internal static class Constants
    {
        public const double WindowMinWidth     = 400;
        public const double WindowMaxWidth     = 3840;
        public const double WindowMinHeight    = 300;
        public const double WindowMaxHeight    = 2160;

        public const double FontSizeMin        = 8;
        public const double FontSizeMax        = 72;
        public const double FontSizeDefault    = 14;

        public const int    ZoomMin            = 10;
        public const int    ZoomMax            = 500;
        public const int    ZoomDefault        = 100;
        public const int    ZoomStep           = 10;

        public const double MarginMin          = 0;
        public const double MarginMax          = 200;
        public const double LineSpacingMin     = 1.0;
        public const double LineSpacingMax     = 3.0;
        public const double LineSpacingDefault = 1.2;

        public const double RenderFontMin      = 4.0;
        public const double RenderFontMax      = 200.0;

        public const int    StatusDebounceMs   = 150;
        public const int    IdleFlushSec       = 5;

        public const string AppName            = "Notepad";
        public const string SettingsDirName    = "Notepad";
        public const string SettingsFileName   = "settings.ini";

        public const string EncUtf8NoBom       = "UTF-8 (no BOM)";
        public const string EncUtf8Bom         = "UTF-8 (BOM)";
        public const string EncUtf16LE         = "UTF-16 LE (BOM)";
        public const string EncUtf16BE         = "UTF-16 BE (BOM)";
        public const string EncUtf32LE         = "UTF-32 LE (BOM)";
        public const string EncUtf32BE         = "UTF-32 BE (BOM)";

        public const string EolCRLF            = "CRLF";
        public const string EolLF              = "LF";
        public const string EolCR              = "CR";
    }

    internal static class NativeMethods
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHDefExtractIcon(
            string pszIconFile, int iIndex, uint uFlags,
            out IntPtr phiconLarge, out IntPtr phiconSmall, uint nIconSize);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        public static IntPtr ExtractIcon(string path, int index, int largeSize, int smallSize)
        {
            uint   packed = (uint)((smallSize << 16) | (largeSize & 0xFFFF));
            IntPtr hLarge;
            IntPtr hSmall;
            int    hr = SHDefExtractIcon(path, index, 0, out hLarge, out hSmall, packed);
            if (hSmall != IntPtr.Zero) DestroyIcon(hSmall);
            if (hr == 0 && hLarge != IntPtr.Zero) return hLarge;
            return IntPtr.Zero;
        }
    }

    internal sealed class AppState
    {
        public string FilePath      { get; set; }
        public bool   IsModified    { get; set; }
        public string FindText      { get; set; }
        public bool   FindMatchCase { get; set; }
        public string LineEnding    { get; set; }
        public string EncodingName  { get; set; }
        public int    ZoomLevel     { get; set; }
        public double BaseFontSize  { get; set; }
        public double LineSpacing   { get; set; }
        public double MarginLeft    { get; set; }
        public double MarginRight   { get; set; }

        public AppState()
        {
            FilePath      = "";
            IsModified    = false;
            FindText      = "";
            FindMatchCase = false;
            LineEnding    = Constants.EolCRLF;
            EncodingName  = Constants.EncUtf8NoBom;
            ZoomLevel     = Constants.ZoomDefault;
            BaseFontSize  = Constants.FontSizeDefault;
            LineSpacing   = Constants.LineSpacingDefault;
            MarginLeft    = 0;
            MarginRight   = 0;
        }
    }

    internal static class EncodingHelper
    {
        public static string DetectEncoding(string filePath)
        {
            byte[] bom  = new byte[4];
            int    read = 0;

            using (FileStream fs = new FileStream(filePath, FileMode.Open,
                                                  FileAccess.Read, FileShare.ReadWrite))
            {
                int b;
                while (read < 4 && (b = fs.ReadByte()) != -1)
                    bom[read++] = (byte)b;
            }

            if (read >= 4)
            {
                if (bom[0] == 0xFF && bom[1] == 0xFE && bom[2] == 0x00 && bom[3] == 0x00)
                    return Constants.EncUtf32LE;
                if (bom[0] == 0x00 && bom[1] == 0x00 && bom[2] == 0xFE && bom[3] == 0xFF)
                    return Constants.EncUtf32BE;
            }

            if (read >= 3 && bom[0] == 0xEF && bom[1] == 0xBB && bom[2] == 0xBF)
                return Constants.EncUtf8Bom;

            if (read >= 2)
            {
                if (bom[0] == 0xFF && bom[1] == 0xFE) return Constants.EncUtf16LE;
                if (bom[0] == 0xFE && bom[1] == 0xFF) return Constants.EncUtf16BE;
            }

            return Constants.EncUtf8NoBom;
        }

        public static Encoding GetEncoding(string name)
        {
            switch (name)
            {
                case Constants.EncUtf8Bom:  return new UTF8Encoding(true);
                case Constants.EncUtf16LE:  return new UnicodeEncoding(false, true);
                case Constants.EncUtf16BE:  return new UnicodeEncoding(true,  true);
                case Constants.EncUtf32LE:  return new UTF32Encoding(false, true);
                case Constants.EncUtf32BE:  return new UTF32Encoding(true,  true);
                default:                    return new UTF8Encoding(false);
            }
        }
    }

    internal static class LineEndingHelper
    {
        public static string Detect(string text)
        {
            if (text.Contains("\r\n")) return Constants.EolCRLF;
            if (text.Contains("\n"))   return Constants.EolLF;
            if (text.Contains("\r"))   return Constants.EolCR;
            return Constants.EolCRLF;
        }

        public static string Normalise(string text)
        {
            return text.Replace("\r\n", "\n").Replace("\r", "\n");
        }

        public static string Apply(string normalised, string lineEnding)
        {
            switch (lineEnding)
            {
                case Constants.EolCRLF: return normalised.Replace("\n", "\r\n");
                case Constants.EolCR:   return normalised.Replace("\n", "\r");
                default:                return normalised;
            }
        }

        public static string DisplayName(string lineEnding)
        {
            switch (lineEnding)
            {
                case Constants.EolCRLF: return "Windows (CRLF)";
                case Constants.EolLF:   return "Unix (LF)";
                case Constants.EolCR:   return "Macintosh (CR)";
                default:                return lineEnding;
            }
        }
    }

    internal static class SettingsManager
    {
        private static readonly string SettingsDir =
            Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.ApplicationData), Constants.SettingsDirName);

        private static readonly string SettingsFile =
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                Constants.SettingsDirName,
                Constants.SettingsFileName);

        public static void Load(AppState state, Window window,
                                MenuItem mnuWordWrap, MenuItem mnuStatusBar,
                                TextBox editor)
        {
            if (!File.Exists(SettingsFile)) return;
            try
            {
                string[] lines   = File.ReadAllLines(SettingsFile);
                string   section = "";

                foreach (string raw in lines)
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;

                    if (line[0] == '[' && line[line.Length - 1] == ']')
                    {
                        section = line.Substring(1, line.Length - 2);
                        continue;
                    }

                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;

                    string key = line.Substring(0, eq).Trim();
                    string val = line.Substring(eq + 1).Trim();

                    double d;
                    bool   b;

                    switch (section)
                    {
                        case "Window":
                            if (key == "Width"  && TryParseDouble(val, out d))
                                window.Width  = Clamp(d, Constants.WindowMinWidth,  Constants.WindowMaxWidth);
                            if (key == "Height" && TryParseDouble(val, out d))
                                window.Height = Clamp(d, Constants.WindowMinHeight, Constants.WindowMaxHeight);
                            break;

                        case "Font":
                            if (key == "Family")
                                editor.FontFamily = new FontFamily(val);
                            if (key == "Size" && TryParseDouble(val, out d))
                                state.BaseFontSize = Clamp(d, Constants.FontSizeMin, Constants.FontSizeMax);
                            break;

                        case "View":
                            if (key == "WordWrap"  && bool.TryParse(val, out b)) mnuWordWrap.IsChecked  = b;
                            if (key == "StatusBar" && bool.TryParse(val, out b)) mnuStatusBar.IsChecked = b;
                            break;

                        case "Editor":
                            if (key == "MarginLeft"  && TryParseDouble(val, out d))
                                state.MarginLeft  = Clamp(d, Constants.MarginMin, Constants.MarginMax);
                            if (key == "MarginRight" && TryParseDouble(val, out d))
                                state.MarginRight = Clamp(d, Constants.MarginMin, Constants.MarginMax);
                            if (key == "LineSpacing" && TryParseDouble(val, out d))
                                state.LineSpacing = Clamp(d, Constants.LineSpacingMin, Constants.LineSpacingMax);
                            break;
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Settings load error: " + ex.Message);
            }
        }

        public static void Save(AppState state, Window window,
                                MenuItem mnuWordWrap, MenuItem mnuStatusBar,
                                TextBox editor)
        {
            try
            {
                if (!Directory.Exists(SettingsDir))
                    Directory.CreateDirectory(SettingsDir);

                StringBuilder sb = new StringBuilder();
                sb.AppendLine("[Window]");
                sb.AppendLine("Width="  + window.ActualWidth .ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("Height=" + window.ActualHeight.ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("[Font]");
                sb.AppendLine("Family=" + editor.FontFamily.Source);
                sb.AppendLine("Size="   + state.BaseFontSize.ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("[View]");
                sb.AppendLine("WordWrap="  + mnuWordWrap .IsChecked.ToString());
                sb.AppendLine("StatusBar=" + mnuStatusBar.IsChecked.ToString());
                sb.AppendLine("[Editor]");
                sb.AppendLine("MarginLeft="  + state.MarginLeft .ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("MarginRight=" + state.MarginRight.ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("LineSpacing=" + state.LineSpacing .ToString("F1", CultureInfo.InvariantCulture));

                File.WriteAllText(SettingsFile, sb.ToString(), Encoding.UTF8);
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Settings save error: " + ex.Message);
            }
        }

        private static bool TryParseDouble(string s, out double result)
        {
            return double.TryParse(s, NumberStyles.Float,
                                   CultureInfo.InvariantCulture, out result);
        }

        private static double Clamp(double v, double min, double max)
        {
            return v < min ? min : v > max ? max : v;
        }
    }

    internal struct StatusInfo
    {
        public int Line;
        public int Column;
        public int TotalLines;
        public int WordCount;
        public int CharCount;
    }

    internal static class StatusCalculator
    {
        public static StatusInfo Calculate(string text, int caretIndex)
        {
            int  len    = text.Length;
            int  car    = caretIndex < 0 ? 0 : caretIndex > len ? len : caretIndex;
            int  ln     = 1, col = 1, totalLines = 1, wc = 0;
            bool inWord = false;

            for (int i = 0; i < len; i++)
            {
                char c = text[i];

                if (i < car)
                {
                    if      (c == '\n') { ln++; col = 1; }
                    else if (c != '\r')   col++;
                }

                if (c == '\n') totalLines++;

                if (char.IsWhiteSpace(c)) { inWord = false; }
                else if (!inWord)         { wc++;  inWord = true; }
            }

            StatusInfo info;
            info.Line       = ln;
            info.Column     = col;
            info.TotalLines = totalLines;
            info.WordCount  = wc;
            info.CharCount  = len;
            return info;
        }
    }

    public class Program
    {
        static readonly AppState State = new AppState();

        static Window    MainWindow;
        static TextBox   txtEditor;
        static TextBlock txtPos, txtWords, txtChars, txtLines, txtEnc, txtEol, txtZoom;
        static StatusBar statusBar;
        static Border    statusBorder;
        static MenuItem  mnuWordWrap, mnuStatusBar, mnuZoomReset;

        static DispatcherTimer _statusTimer;
        static DispatcherTimer _idleTimer;
        static bool            _statusPending;

        [STAThread]
        public static void Main()
        {
            Application app = new Application();
            MainWindow = (Window)XamlReader.Parse(Xaml.Main);
            SetWindowIcon();
            WireControls();
            WireEvents();

            _statusTimer = new DispatcherTimer();
            _statusTimer.Interval = TimeSpan.FromMilliseconds(Constants.StatusDebounceMs);
            _statusTimer.Tick += OnStatusTimerTick;

            _idleTimer = new DispatcherTimer();
            _idleTimer.Interval = TimeSpan.FromSeconds(Constants.IdleFlushSec);
            _idleTimer.Tick += OnIdleTimerTick;
            _idleTimer.Start();

            app.Run(MainWindow);
        }

        static void OnStatusTimerTick(object sender, EventArgs e)
        {
            _statusTimer.Stop();
            _statusPending = false;
            UpdateStatusBar();
        }

        static void OnIdleTimerTick(object sender, EventArgs e)
        {
            _idleTimer.Stop();
            TrimWorkingSet();
        }

        static void SetWindowIcon()
        {
            try
            {
                string notepadExe = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "notepad.exe");

                if (!File.Exists(notepadExe)) return;

                IntPtr hIcon = NativeMethods.ExtractIcon(notepadExe, 0, 48, 16);
                if (hIcon == IntPtr.Zero) return;

                try
                {
                    BitmapSource bmp = Imaging.CreateBitmapSourceFromHIcon(
                        hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    bmp.Freeze();
                    MainWindow.Icon = bmp;
                }
                finally
                {
                    NativeMethods.DestroyIcon(hIcon);
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine("Icon load error: " + ex.Message);
            }
        }

        static T FindControl<T>(string name) where T : class
        {
            T ctrl = MainWindow.FindName(name) as T;
            if (ctrl == null)
                throw new InvalidOperationException(
                    string.Format("Control '{0}' ({1}) not found in XAML.",
                                  name, typeof(T).Name));
            return ctrl;
        }

        static T FindIn<T>(Window w, string name) where T : class
        {
            T ctrl = w.FindName(name) as T;
            if (ctrl == null)
                throw new InvalidOperationException(
                    string.Format("Control '{0}' not found in dialog.", name));
            return ctrl;
        }

        static void WireControls()
        {
            txtEditor    = FindControl<TextBox>("txtEditor");
            txtPos       = FindControl<TextBlock>("txtPos");
            txtWords     = FindControl<TextBlock>("txtWords");
            txtChars     = FindControl<TextBlock>("txtChars");
            txtLines     = FindControl<TextBlock>("txtLines");
            txtEnc       = FindControl<TextBlock>("txtEnc");
            txtEol       = FindControl<TextBlock>("txtEol");
            txtZoom      = FindControl<TextBlock>("txtZoom");
            statusBar    = FindControl<StatusBar>("statusBar");
            statusBorder = FindControl<Border>("statusBorder");
            mnuWordWrap  = FindControl<MenuItem>("mnuWordWrap");
            mnuStatusBar = FindControl<MenuItem>("mnuStatusBar");
            mnuZoomReset = FindControl<MenuItem>("mnuZoomReset");
        }

        static void WireEvents()
        {
            FindControl<MenuItem>("mnuNew")   .Click += delegate { CmdNew(); };
            FindControl<MenuItem>("mnuOpen")  .Click += delegate { CmdOpen(); };
            FindControl<MenuItem>("mnuSave")  .Click += delegate { CmdSave(); };
            FindControl<MenuItem>("mnuSaveAs").Click += delegate { CmdSaveAs(); };
            FindControl<MenuItem>("mnuExit")  .Click += delegate { MainWindow.Close(); };

            FindControl<MenuItem>("mnuUndo")  .Click += delegate { if (txtEditor.CanUndo) txtEditor.Undo(); };
            FindControl<MenuItem>("mnuRedo")  .Click += delegate { if (txtEditor.CanRedo) txtEditor.Redo(); };
            FindControl<MenuItem>("mnuCut")   .Click += delegate { txtEditor.Cut(); };
            FindControl<MenuItem>("mnuCopy")  .Click += delegate { txtEditor.Copy(); };
            FindControl<MenuItem>("mnuPaste") .Click += delegate { txtEditor.Paste(); };
            FindControl<MenuItem>("mnuDelete").Click += delegate
                { if (txtEditor.SelectionLength > 0) txtEditor.SelectedText = ""; };
            FindControl<MenuItem>("mnuSelAll").Click += delegate { txtEditor.SelectAll(); };
            FindControl<MenuItem>("mnuDate")  .Click += delegate
                { txtEditor.SelectedText = DateTime.Now.ToString("h:mm tt M/d/yyyy"); };

            FindControl<MenuItem>("mnuFind")    .Click += delegate { ShowFindDlg(); };
            FindControl<MenuItem>("mnuFindNext").Click += delegate { CmdFindNext(); };
            FindControl<MenuItem>("mnuReplace") .Click += delegate { ShowReplaceDlg(); };

            FindControl<MenuItem>("mnuFont")     .Click += delegate { ShowFontDlg(); };
            FindControl<MenuItem>("mnuEditorCfg").Click += delegate { ShowEditorCfgDlg(); };
            FindControl<MenuItem>("mnuZoomIn")   .Click += delegate { Zoom(+Constants.ZoomStep); };
            FindControl<MenuItem>("mnuZoomOut")  .Click += delegate { Zoom(-Constants.ZoomStep); };
            mnuZoomReset.Click += delegate { ResetZoom(); };

            FindControl<MenuItem>("mnuEolCRLF").Click += delegate { CmdSetLineEnding(Constants.EolCRLF); };
            FindControl<MenuItem>("mnuEolLF")  .Click += delegate { CmdSetLineEnding(Constants.EolLF); };
            FindControl<MenuItem>("mnuEolCR")  .Click += delegate { CmdSetLineEnding(Constants.EolCR); };

            FindControl<MenuItem>("mnuEncUtf8")   .Click += delegate { CmdSetEncoding(Constants.EncUtf8NoBom); };
            FindControl<MenuItem>("mnuEncUtf8Bom").Click += delegate { CmdSetEncoding(Constants.EncUtf8Bom); };
            FindControl<MenuItem>("mnuEncUtf16LE").Click += delegate { CmdSetEncoding(Constants.EncUtf16LE); };
            FindControl<MenuItem>("mnuEncUtf16BE").Click += delegate { CmdSetEncoding(Constants.EncUtf16BE); };

            mnuWordWrap .Checked   += delegate { ApplyWordWrap(true); };
            mnuWordWrap .Unchecked += delegate { ApplyWordWrap(false); };
            mnuStatusBar.Checked   += delegate { ApplyStatusBarVisibility(true); };
            mnuStatusBar.Unchecked += delegate { ApplyStatusBarVisibility(false); };

            txtEditor.TextChanged      += OnTextChanged;
            txtEditor.SelectionChanged += delegate { RequestStatusUpdate(); };
            txtEditor.PreviewMouseWheel += OnMouseWheel;

            MainWindow.Loaded         += OnLoaded;
            MainWindow.Closing        += OnClosing;
            MainWindow.StateChanged   += OnStateChanged;
            MainWindow.PreviewKeyDown += OnPreviewKeyDown;
        }

        static void OnLoaded(object sender, RoutedEventArgs e)
        {
            SettingsManager.Load(State, MainWindow, mnuWordWrap, mnuStatusBar, txtEditor);
            UpdateTitle();
            ApplyWordWrap(mnuWordWrap.IsChecked);
            ApplyStatusBarVisibility(mnuStatusBar.IsChecked);
            ApplyMargins();
            ApplyZoom();
            txtEditor.Focus();
        }

        static void OnClosing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            if (!ConfirmSave()) { e.Cancel = true; return; }
            SettingsManager.Save(State, MainWindow, mnuWordWrap, mnuStatusBar, txtEditor);
        }

        static void OnStateChanged(object sender, EventArgs e)
        {
            if (MainWindow.WindowState == WindowState.Minimized)
                TrimWorkingSet();
        }

        static void OnTextChanged(object sender, TextChangedEventArgs e)
        {
            State.IsModified = true;
            UpdateTitle();
            RequestStatusUpdate();
            ResetIdleTimer();
        }

        static void OnMouseWheel(object sender, MouseWheelEventArgs e)
        {
            if ((Keyboard.Modifiers & ModifierKeys.Control) != 0)
            {
                Zoom(e.Delta > 0 ? Constants.ZoomStep : -Constants.ZoomStep);
                e.Handled = true;
            }
        }

        static void OnPreviewKeyDown(object sender, KeyEventArgs e)
        {
            ResetIdleTimer();

            bool ctrl  = (Keyboard.Modifiers & ModifierKeys.Control) != 0;
            bool shift = (Keyboard.Modifiers & ModifierKeys.Shift)   != 0;

            if (ctrl && !shift)
            {
                switch (e.Key)
                {
                    case Key.N:                             CmdNew();                   e.Handled = true; break;
                    case Key.O:                             CmdOpen();                  e.Handled = true; break;
                    case Key.S:                             CmdSave();                  e.Handled = true; break;
                    case Key.F:                             ShowFindDlg();              e.Handled = true; break;
                    case Key.H:                             ShowReplaceDlg();           e.Handled = true; break;
                    case Key.D0:       case Key.NumPad0:    ResetZoom();                e.Handled = true; break;
                    case Key.OemPlus:  case Key.Add:        Zoom(+Constants.ZoomStep);  e.Handled = true; break;
                    case Key.OemMinus: case Key.Subtract:   Zoom(-Constants.ZoomStep);  e.Handled = true; break;
                }
            }
            else if (ctrl && shift)
            {
                if (e.Key == Key.S) { CmdSaveAs(); e.Handled = true; }
            }
            else
            {
                if (e.Key == Key.F3) { CmdFindNext(); e.Handled = true; }
                if (e.Key == Key.F5)
                {
                    txtEditor.SelectedText = DateTime.Now.ToString("h:mm tt M/d/yyyy");
                    e.Handled = true;
                }
            }
        }

        static void UpdateTitle()
        {
            string name = string.IsNullOrEmpty(State.FilePath)
                ? "Untitled"
                : Path.GetFileName(State.FilePath);
            MainWindow.Title = (State.IsModified ? "*" : "") + name + " - " + Constants.AppName;
        }

        static void ApplyMargins()
        {
            txtEditor.Margin = new Thickness(State.MarginLeft, 0, State.MarginRight, 0);
        }

        static void ApplyLineSpacing()
        {
            double lh = Math.Max(1.0, txtEditor.FontSize * State.LineSpacing);
            txtEditor.SetValue(TextBlock.LineHeightProperty, lh);
            txtEditor.SetValue(TextBlock.LineStackingStrategyProperty,
                               LineStackingStrategy.BlockLineHeight);
        }

        static void ApplyZoom()
        {
            double factor = State.ZoomLevel / 100.0;
            txtEditor.FontSize = Clamp(State.BaseFontSize * factor,
                                       Constants.RenderFontMin, Constants.RenderFontMax);
            ApplyLineSpacing();
            if (txtZoom      != null) txtZoom.Text           = State.ZoomLevel + "%";
            if (mnuZoomReset != null) mnuZoomReset.IsEnabled = State.ZoomLevel != Constants.ZoomDefault;
        }

        static void ApplyWordWrap(bool on)
        {
            txtEditor.TextWrapping = on ? TextWrapping.Wrap : TextWrapping.NoWrap;
            txtEditor.HorizontalScrollBarVisibility =
                on ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
        }

        static void ApplyStatusBarVisibility(bool on)
        {
            Visibility v = on ? Visibility.Visible : Visibility.Collapsed;
            statusBar   .Visibility = v;
            statusBorder.Visibility = v;
            if (on) UpdateStatusBar();
        }

        static void UpdateStatusBar()
        {
            if (statusBar.Visibility != Visibility.Visible) return;

            StatusInfo info = StatusCalculator.Calculate(txtEditor.Text, txtEditor.CaretIndex);

            txtPos  .Text = string.Format("Ln {0}, Col {1}", info.Line,   info.Column);
            txtWords.Text = string.Format("Words: {0}",      info.WordCount);
            txtChars.Text = string.Format("Chars: {0}",      info.CharCount);
            txtLines.Text = string.Format("Lines: {0}",      info.TotalLines);
            txtEnc  .Text = State.EncodingName;
            txtEol  .Text = LineEndingHelper.DisplayName(State.LineEnding);
            txtZoom .Text = State.ZoomLevel + "%";
        }

        static void RequestStatusUpdate()
        {
            if (!_statusPending)
            {
                _statusPending = true;
                _statusTimer.Stop();
                _statusTimer.Start();
            }
        }

        static void ResetIdleTimer()
        {
            if (_idleTimer != null)
            {
                _idleTimer.Stop();
                _idleTimer.Start();
            }
        }

        static void Zoom(int step)
        {
            State.ZoomLevel = (int)Clamp(State.ZoomLevel + step,
                                         Constants.ZoomMin, Constants.ZoomMax);
            ApplyZoom();
        }

        static void ResetZoom()
        {
            State.ZoomLevel = Constants.ZoomDefault;
            ApplyZoom();
        }

        static void TrimWorkingSet()
        {
            GC.Collect(0, GCCollectionMode.Optimized);
        }

        static double Clamp(double v, double min, double max)
        {
            return v < min ? min : v > max ? max : v;
        }

        static bool ConfirmSave()
        {
            if (!State.IsModified) return true;

            string name = string.IsNullOrEmpty(State.FilePath)
                ? "Untitled"
                : Path.GetFileName(State.FilePath);

            MessageBoxResult result = MessageBox.Show(
                string.Format("Do you want to save changes to {0}?", name),
                Constants.AppName,
                MessageBoxButton.YesNoCancel,
                MessageBoxImage.Warning);

            if (result == MessageBoxResult.Yes)  return CmdSave();
            if (result == MessageBoxResult.No)   return true;
            return false;
        }

        static void CmdNew()
        {
            if (!ConfirmSave()) return;
            txtEditor.Clear();
            State.FilePath     = "";
            State.IsModified   = false;
            State.LineEnding   = Constants.EolCRLF;
            State.EncodingName = Constants.EncUtf8NoBom;
            UpdateTitle();
            UpdateStatusBar();
            txtEditor.Focus();
        }

        static void CmdOpen()
        {
            if (!ConfirmSave()) return;

            using (WinForms.OpenFileDialog dlg = new WinForms.OpenFileDialog())
            {
                dlg.Title            = "Open";
                dlg.Filter           = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*";
                dlg.RestoreDirectory = true;

                if (dlg.ShowDialog() != WinForms.DialogResult.OK) return;

                try
                {
                    string   path    = dlg.FileName;
                    string   encName = EncodingHelper.DetectEncoding(path);
                    Encoding enc     = EncodingHelper.GetEncoding(encName);
                    string   content = File.ReadAllText(path, enc);
                    string   eol     = LineEndingHelper.Detect(content);

                    State.FilePath     = path;
                    State.EncodingName = encName;
                    State.LineEnding   = eol;
                    State.IsModified   = false;

                    txtEditor.Text       = content;
                    txtEditor.CaretIndex = 0;

                    UpdateTitle();
                    UpdateStatusBar();
                    txtEditor.Focus();
                }
                catch (Exception ex)
                {
                    MessageBox.Show("Could not open file:\n" + ex.Message,
                        Constants.AppName, MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
        }

        static bool CmdSave()
        {
            if (string.IsNullOrEmpty(State.FilePath)) return CmdSaveAs();

            try
            {
                string normalised = LineEndingHelper.Normalise(txtEditor.Text);
                string final      = LineEndingHelper.Apply(normalised, State.LineEnding);
                File.WriteAllText(State.FilePath, final,
                                  EncodingHelper.GetEncoding(State.EncodingName));
                State.IsModified = false;
                UpdateTitle();
                return true;
            }
            catch (Exception ex)
            {
                MessageBox.Show("Could not save file:\n" + ex.Message,
                    Constants.AppName, MessageBoxButton.OK, MessageBoxImage.Error);
                return false;
            }
        }

        static bool CmdSaveAs()
        {
            using (WinForms.SaveFileDialog dlg = new WinForms.SaveFileDialog())
            {
                dlg.Title            = "Save As";
                dlg.Filter           = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*";
                dlg.DefaultExt       = "txt";
                dlg.RestoreDirectory = true;

                if (!string.IsNullOrEmpty(State.FilePath))
                {
                    dlg.InitialDirectory = Path.GetDirectoryName(State.FilePath);
                    dlg.FileName         = Path.GetFileName(State.FilePath);
                }

                if (dlg.ShowDialog() != WinForms.DialogResult.OK) return false;
                State.FilePath = dlg.FileName;
                return CmdSave();
            }
        }

        static void CmdSetLineEnding(string eol)
        {
            State.LineEnding = eol;
            State.IsModified = true;
            UpdateTitle();
            UpdateStatusBar();
        }

        static void CmdSetEncoding(string enc)
        {
            State.EncodingName = enc;
            State.IsModified   = true;
            UpdateTitle();
            UpdateStatusBar();
        }

        static bool DoFind(string text, bool matchCase, bool showNotFound)
        {
            if (string.IsNullOrEmpty(text)) return false;

            State.FindText      = text;
            State.FindMatchCase = matchCase;

            string body = txtEditor.Text;
            if (body.Length == 0)
            {
                if (showNotFound)
                    MessageBox.Show(string.Format("Cannot find \"{0}\"", text),
                        Constants.AppName);
                return false;
            }

            StringComparison cmp = matchCase
                ? StringComparison.Ordinal
                : StringComparison.OrdinalIgnoreCase;

            int searchFrom = txtEditor.SelectionStart + txtEditor.SelectionLength;
            if (searchFrom >= body.Length) searchFrom = 0;

            int  idx     = body.IndexOf(text, searchFrom, cmp);
            bool wrapped = false;

            if (idx < 0 && searchFrom > 0)
            {
                idx     = body.IndexOf(text, 0, cmp);
                wrapped = idx >= 0;
            }

            if (idx >= 0)
            {
                txtEditor.Focus();
                txtEditor.Select(idx, text.Length);

                int lineIdx = txtEditor.GetLineIndexFromCharacterIndex(idx);
                if (lineIdx >= 0) txtEditor.ScrollToLine(lineIdx);

                if (wrapped)
                    MessageBox.Show(
                        "The search wrapped to the beginning of the document.",
                        Constants.AppName,
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                return true;
            }

            if (showNotFound)
                MessageBox.Show(string.Format("Cannot find \"{0}\"", text),
                    Constants.AppName);
            return false;
        }

        static void CmdFindNext()
        {
            if (string.IsNullOrWhiteSpace(State.FindText))
                ShowFindDlg();
            else
                DoFind(State.FindText, State.FindMatchCase, true);
        }

        static void ShowFindDlg()
        {
            Window d = new Window();
            d.Title                 = "Find";
            d.Width                 = 420;
            d.Height                = 150;
            d.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            d.Owner                 = MainWindow;
            d.ResizeMode            = ResizeMode.NoResize;
            d.WindowStyle           = WindowStyle.ToolWindow;
            d.ShowInTaskbar         = false;

            Grid g = new Grid();
            g.Margin = new Thickness(10);
            g.RowDefinitions.Add(new RowDefinition());
            g.RowDefinitions.Add(new RowDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            Label lbl = new Label();
            lbl.Content             = "Find what:";
            lbl.VerticalAlignment   = VerticalAlignment.Center;

            TextBox txt = new TextBox();
            txt.Margin                   = new Thickness(8, 0, 8, 0);
            txt.Height                   = 26;
            txt.VerticalContentAlignment = VerticalAlignment.Center;
            txt.Text                     = State.FindText;

            Button btn = new Button();
            btn.Content   = "Find Next";
            btn.Width     = 84;
            btn.Height    = 28;
            btn.IsDefault = true;

            CheckBox chk = new CheckBox();
            chk.Content   = "Match case";
            chk.Margin    = new Thickness(0, 8, 0, 0);
            chk.IsChecked = State.FindMatchCase;

            PlaceInGrid(g, lbl, 0, 0);
            PlaceInGrid(g, txt, 0, 1);
            PlaceInGrid(g, btn, 0, 2);
            PlaceInGrid(g, chk, 1, 1);

            btn.Click += delegate { DoFind(txt.Text, chk.IsChecked == true, true); };

            d.Content = g;
            txt.Focus();
            txt.SelectAll();
            d.ShowDialog();
        }

        static void ShowReplaceDlg()
        {
            Window d = new Window();
            d.Title                 = "Replace";
            d.Width                 = 420;
            d.Height                = 190;
            d.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            d.Owner                 = MainWindow;
            d.ResizeMode            = ResizeMode.NoResize;
            d.WindowStyle           = WindowStyle.ToolWindow;
            d.ShowInTaskbar         = false;

            Grid g = new Grid();
            g.Margin = new Thickness(10);
            for (int i = 0; i < 4; i++)
                g.RowDefinitions.Add(new RowDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            Label lFind = new Label();
            lFind.Content           = "Find:";
            lFind.VerticalAlignment = VerticalAlignment.Center;

            TextBox tFind = new TextBox();
            tFind.Margin = new Thickness(8, 2, 8, 2);
            tFind.Height = 24;
            tFind.Text   = State.FindText;

            Button bFind = new Button();
            bFind.Content = "Find Next";
            bFind.Width   = 84;
            bFind.Height  = 24;
            bFind.Margin  = new Thickness(0, 2, 0, 2);

            Label lReplace = new Label();
            lReplace.Content           = "Replace:";
            lReplace.VerticalAlignment = VerticalAlignment.Center;

            TextBox tReplace = new TextBox();
            tReplace.Margin = new Thickness(8, 2, 8, 2);
            tReplace.Height = 24;

            Button bReplace = new Button();
            bReplace.Content = "Replace";
            bReplace.Width   = 84;
            bReplace.Height  = 24;
            bReplace.Margin  = new Thickness(0, 2, 0, 2);

            CheckBox chkCase = new CheckBox();
            chkCase.Content   = "Match case";
            chkCase.Margin    = new Thickness(0, 6, 0, 0);
            chkCase.IsChecked = State.FindMatchCase;

            Button bAll = new Button();
            bAll.Content = "Replace All";
            bAll.Width   = 84;
            bAll.Height  = 24;
            bAll.Margin  = new Thickness(0, 2, 0, 2);

            PlaceInGrid(g, lFind,    0, 0);
            PlaceInGrid(g, tFind,    0, 1);
            PlaceInGrid(g, bFind,    0, 2);
            PlaceInGrid(g, lReplace, 1, 0);
            PlaceInGrid(g, tReplace, 1, 1);
            PlaceInGrid(g, bReplace, 1, 2);
            PlaceInGrid(g, chkCase,  2, 1);
            PlaceInGrid(g, bAll,     2, 2);

            bFind.Click += delegate
            {
                DoFind(tFind.Text, chkCase.IsChecked == true, true);
            };

            bReplace.Click += delegate
            {
                if (string.IsNullOrEmpty(tFind.Text)) return;
                bool   mc    = chkCase.IsChecked == true;
                string sel   = txtEditor.SelectedText;
                bool   match = mc
                    ? sel == tFind.Text
                    : sel.Equals(tFind.Text, StringComparison.OrdinalIgnoreCase);
                if (match) txtEditor.SelectedText = tReplace.Text;
                DoFind(tFind.Text, mc, true);
            };

            bAll.Click += delegate
            {
                if (string.IsNullOrEmpty(tFind.Text) || txtEditor.Text.Length == 0) return;

                RegexOptions opts = chkCase.IsChecked == true
                    ? RegexOptions.None
                    : RegexOptions.IgnoreCase;

                Regex           rx      = new Regex(Regex.Escape(tFind.Text), opts);
                MatchCollection matches = rx.Matches(txtEditor.Text);
                int             count   = matches.Count;

                if (count > 0)
                {
                    txtEditor.Text = rx.Replace(txtEditor.Text, tReplace.Text);
                    MessageBox.Show(
                        string.Format("{0} occurrence(s) replaced.", count),
                        Constants.AppName,
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }
                else
                {
                    MessageBox.Show(
                        string.Format("Cannot find \"{0}\"", tFind.Text),
                        Constants.AppName,
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }
            };

            d.Content = g;
            tFind.Focus();
            tFind.SelectAll();
            d.ShowDialog();
        }

        static void ShowFontDlg()
        {
            using (WinForms.FontDialog dlg = new WinForms.FontDialog())
            {
                dlg.ShowColor     = false;
                dlg.ShowEffects   = false;
                dlg.FontMustExist = true;

                try
                {
                    dlg.Font = new System.Drawing.Font(
                        txtEditor.FontFamily.Source,
                        (float)(State.BaseFontSize * 72.0 / 96.0));
                }
                catch (Exception ex)
                {
                    Debug.WriteLine("FontDialog init: " + ex.Message);
                }

                if (dlg.ShowDialog() != WinForms.DialogResult.OK) return;

                txtEditor.FontFamily = new FontFamily(dlg.Font.FontFamily.Name);
                State.BaseFontSize   = dlg.Font.Size * 96.0 / 72.0;
                ApplyZoom();
            }
        }

        static void ShowEditorCfgDlg()
        {
            Window d = (Window)XamlReader.Parse(Xaml.EditorSettings);
            d.Owner = MainWindow;

            TextBox tLeft   = FindIn<TextBox>(d, "tLeft");
            TextBox tRight  = FindIn<TextBox>(d, "tRight");
            TextBox tSpace  = FindIn<TextBox>(d, "tSpace");
            Button  bOK     = FindIn<Button>(d,  "bOK");
            Button  bApply  = FindIn<Button>(d,  "bApply");
            Button  bCancel = FindIn<Button>(d,  "bCancel");

            tLeft .Text = State.MarginLeft .ToString(CultureInfo.InvariantCulture);
            tRight.Text = State.MarginRight.ToString(CultureInfo.InvariantCulture);
            tSpace.Text = State.LineSpacing.ToString("F1", CultureInfo.InvariantCulture);

            double origLeft  = State.MarginLeft;
            double origRight = State.MarginRight;
            double origSpace = State.LineSpacing;

            bApply.Click += delegate
            {
                TryApplyEditorCfg(tLeft, tRight, tSpace);
            };

            bOK.Click += delegate
            {
                if (TryApplyEditorCfg(tLeft, tRight, tSpace))
                {
                    SettingsManager.Save(State, MainWindow, mnuWordWrap, mnuStatusBar, txtEditor);
                    d.DialogResult = true;
                }
            };

            bCancel.Click += delegate
            {
                State.MarginLeft  = origLeft;
                State.MarginRight = origRight;
                State.LineSpacing = origSpace;
                ApplyMargins();
                ApplyLineSpacing();
                d.Close();
            };

            d.Closing += delegate(object s, System.ComponentModel.CancelEventArgs ce)
            {
                if (d.DialogResult != true)
                {
                    State.MarginLeft  = origLeft;
                    State.MarginRight = origRight;
                    State.LineSpacing = origSpace;
                    ApplyMargins();
                    ApplyLineSpacing();
                }
            };

            tLeft.Focus();
            tLeft.SelectAll();
            d.ShowDialog();
        }

        static bool TryApplyEditorCfg(TextBox tLeft, TextBox tRight, TextBox tSpace)
        {
            double l = 0, r = 0, s = 0;

            bool parsed =
                TryParseInvariant(tLeft.Text,  out l) &
                TryParseInvariant(tRight.Text, out r) &
                TryParseInvariant(tSpace.Text, out s);

            bool valid = parsed
                && l >= Constants.MarginMin      && l <= Constants.MarginMax
                && r >= Constants.MarginMin      && r <= Constants.MarginMax
                && s >= Constants.LineSpacingMin && s <= Constants.LineSpacingMax;

            if (!valid)
            {
                MessageBox.Show(
                    string.Format(
                        "Invalid values.\nMargins: {0}-{1} px\nSpacing: {2}-{3}",
                        Constants.MarginMin,      Constants.MarginMax,
                        Constants.LineSpacingMin, Constants.LineSpacingMax),
                    "Invalid Input",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return false;
            }

            State.MarginLeft  = l;
            State.MarginRight = r;
            State.LineSpacing = s;
            ApplyMargins();
            ApplyLineSpacing();
            return true;
        }

        static void PlaceInGrid(Grid g, UIElement el, int row, int col)
        {
            Grid.SetRow(el, row);
            Grid.SetColumn(el, col);
            g.Children.Add(el);
        }

        static bool TryParseInvariant(string s, out double result)
        {
            return double.TryParse(s, NumberStyles.Float,
                                   CultureInfo.InvariantCulture, out result);
        }
    }

    internal static class Xaml
    {
        public static readonly string EditorSettings =
            "<Window xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"" +
            "        Title=\"Editor Settings\"" +
            "        SizeToContent=\"WidthAndHeight\"" +
            "        WindowStartupLocation=\"CenterOwner\"" +
            "        ResizeMode=\"NoResize\"" +
            "        WindowStyle=\"SingleBorderWindow\"" +
            "        Background=\"#F0F0F0\">" +
            "  <Border Padding=\"14,12,14,12\" MinWidth=\"290\">" +
            "    <StackPanel>" +
            "      <GroupBox Header=\" Margins (px) \" Padding=\"8,4,8,4\" Margin=\"0,0,0,6\">" +
            "        <Grid>" +
            "          <Grid.RowDefinitions>" +
            "            <RowDefinition Height=\"Auto\"/>" +
            "            <RowDefinition Height=\"Auto\"/>" +
            "          </Grid.RowDefinitions>" +
            "          <Grid.ColumnDefinitions>" +
            "            <ColumnDefinition Width=\"50\"/>" +
            "            <ColumnDefinition Width=\"*\"/>" +
            "          </Grid.ColumnDefinitions>" +
            "          <Label  Content=\"Left:\"  Grid.Row=\"0\" Grid.Column=\"0\" VerticalAlignment=\"Center\" Padding=\"0\"/>" +
            "          <TextBox Name=\"tLeft\"    Grid.Row=\"0\" Grid.Column=\"1\" Width=\"64\" Height=\"22\" HorizontalAlignment=\"Left\" VerticalContentAlignment=\"Center\" Padding=\"3,0\"/>" +
            "          <Label  Content=\"Right:\" Grid.Row=\"1\" Grid.Column=\"0\" VerticalAlignment=\"Center\" Padding=\"0\"/>" +
            "          <TextBox Name=\"tRight\"   Grid.Row=\"1\" Grid.Column=\"1\" Width=\"64\" Height=\"22\" HorizontalAlignment=\"Left\" VerticalContentAlignment=\"Center\" Padding=\"3,0\"/>" +
            "        </Grid>" +
            "      </GroupBox>" +
            "      <GroupBox Header=\" Line Spacing (1.0-3.0) \" Padding=\"8,4,8,4\" Margin=\"0,0,0,6\">" +
            "        <StackPanel Orientation=\"Horizontal\">" +
            "          <Label Content=\"Multiplier:\" VerticalAlignment=\"Center\" Padding=\"0\"/>" +
            "          <TextBox Name=\"tSpace\" Width=\"64\" Height=\"22\" Margin=\"8,0,0,0\" VerticalContentAlignment=\"Center\" Padding=\"3,0\"/>" +
            "        </StackPanel>" +
            "      </GroupBox>" +
            "      <StackPanel Orientation=\"Horizontal\" HorizontalAlignment=\"Right\" Margin=\"0,8,0,0\">" +
            "        <Button Name=\"bOK\"     Content=\"OK\"     Width=\"68\" Height=\"24\" IsDefault=\"True\" Margin=\"0,0,5,0\"/>" +
            "        <Button Name=\"bApply\"  Content=\"Apply\"  Width=\"68\" Height=\"24\" Margin=\"0,0,5,0\"/>" +
            "        <Button Name=\"bCancel\" Content=\"Cancel\" Width=\"68\" Height=\"24\" IsCancel=\"True\"/>" +
            "      </StackPanel>" +
            "    </StackPanel>" +
            "  </Border>" +
            "</Window>";

        public static readonly string Main =
            "<Window xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"" +
            "        xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\"" +
            "        Title=\"Untitled - Notepad\"" +
            "        WindowStartupLocation=\"CenterScreen\"" +
            "        Width=\"900\" Height=\"650\"" +
            "        MinWidth=\"400\" MinHeight=\"300\"" +
            "        Background=\"#F0F0F0\">" +
            "  <Window.Resources>" +
            "    <Style TargetType=\"MenuItem\">" +
            "      <Setter Property=\"Padding\" Value=\"4,2\"/>" +
            "      <Setter Property=\"FontSize\" Value=\"12\"/>" +
            "    </Style>" +
            "    <Style x:Key=\"SBText\" TargetType=\"TextBlock\">" +
            "      <Setter Property=\"FontSize\" Value=\"11\"/>" +
            "      <Setter Property=\"Foreground\" Value=\"#444444\"/>" +
            "      <Setter Property=\"VerticalAlignment\" Value=\"Center\"/>" +
            "    </Style>" +
            "    <Style x:Key=\"SBSep\" TargetType=\"Rectangle\">" +
            "      <Setter Property=\"Width\" Value=\"1\"/>" +
            "      <Setter Property=\"Height\" Value=\"14\"/>" +
            "      <Setter Property=\"Fill\" Value=\"#AAAAAA\"/>" +
            "      <Setter Property=\"VerticalAlignment\" Value=\"Center\"/>" +
            "    </Style>" +
            "  </Window.Resources>" +
            "  <DockPanel>" +
            "    <Border DockPanel.Dock=\"Top\" BorderBrush=\"#B0B0B0\" BorderThickness=\"0,0,0,1\">" +
            "      <Border BorderBrush=\"#E8E8E8\" BorderThickness=\"0,0,0,1\">" +
            "        <Menu Name=\"menuBar\" Background=\"#FFFFFF\" Padding=\"1,0\">" +
            "          <MenuItem Header=\"_File\">" +
            "            <MenuItem Header=\"_New\"        Name=\"mnuNew\"    InputGestureText=\"Ctrl+N\"/>" +
            "            <MenuItem Header=\"_Open...\"    Name=\"mnuOpen\"   InputGestureText=\"Ctrl+O\"/>" +
            "            <MenuItem Header=\"_Save\"       Name=\"mnuSave\"   InputGestureText=\"Ctrl+S\"/>" +
            "            <MenuItem Header=\"Save _As...\" Name=\"mnuSaveAs\" InputGestureText=\"Ctrl+Shift+S\"/>" +
            "            <Separator/>" +
            "            <MenuItem Header=\"E_xit\" Name=\"mnuExit\" InputGestureText=\"Alt+F4\"/>" +
            "          </MenuItem>" +
            "          <MenuItem Header=\"_Edit\">" +
            "            <MenuItem Header=\"_Undo\"  Name=\"mnuUndo\" InputGestureText=\"Ctrl+Z\"/>" +
            "            <MenuItem Header=\"_Redo\"  Name=\"mnuRedo\" InputGestureText=\"Ctrl+Y\"/>" +
            "            <Separator/>" +
            "            <MenuItem Header=\"Cu_t\"    Name=\"mnuCut\"    InputGestureText=\"Ctrl+X\"/>" +
            "            <MenuItem Header=\"_Copy\"   Name=\"mnuCopy\"   InputGestureText=\"Ctrl+C\"/>" +
            "            <MenuItem Header=\"_Paste\"  Name=\"mnuPaste\"  InputGestureText=\"Ctrl+V\"/>" +
            "            <MenuItem Header=\"De_lete\" Name=\"mnuDelete\" InputGestureText=\"Del\"/>" +
            "            <Separator/>" +
            "            <MenuItem Header=\"_Find...\"    Name=\"mnuFind\"     InputGestureText=\"Ctrl+F\"/>" +
            "            <MenuItem Header=\"Find _Next\"  Name=\"mnuFindNext\" InputGestureText=\"F3\"/>" +
            "            <MenuItem Header=\"_Replace...\" Name=\"mnuReplace\"  InputGestureText=\"Ctrl+H\"/>" +
            "            <Separator/>" +
            "            <MenuItem Header=\"Select _All\" Name=\"mnuSelAll\" InputGestureText=\"Ctrl+A\"/>" +
            "            <MenuItem Header=\"Time/_Date\"  Name=\"mnuDate\"   InputGestureText=\"F5\"/>" +
            "          </MenuItem>" +
            "          <MenuItem Header=\"F_ormat\">" +
            "            <MenuItem Header=\"_Word Wrap\" Name=\"mnuWordWrap\" IsCheckable=\"True\"/>" +
            "            <MenuItem Header=\"_Font...\"   Name=\"mnuFont\"/>" +
            "            <Separator/>" +
            "            <MenuItem Header=\"_Zoom\">" +
            "              <MenuItem Header=\"Zoom _In\"      Name=\"mnuZoomIn\"    InputGestureText=\"Ctrl++\"/>" +
            "              <MenuItem Header=\"Zoom _Out\"     Name=\"mnuZoomOut\"   InputGestureText=\"Ctrl+-\"/>" +
            "              <MenuItem Header=\"_Reset (100%)\" Name=\"mnuZoomReset\" InputGestureText=\"Ctrl+0\"/>" +
            "            </MenuItem>" +
            "            <Separator/>" +
            "            <MenuItem Header=\"_Line Endings\">" +
            "              <MenuItem Header=\"Windows (CRLF)\" Name=\"mnuEolCRLF\">" +
            "                <MenuItem.ToolTip><TextBlock>Carriage Return + Line Feed (0D 0A). Standard on Windows.</TextBlock></MenuItem.ToolTip>" +
            "              </MenuItem>" +
            "              <MenuItem Header=\"Unix (LF)\" Name=\"mnuEolLF\">" +
            "                <MenuItem.ToolTip><TextBlock>Line Feed only (0A). Standard on Linux and macOS.</TextBlock></MenuItem.ToolTip>" +
            "              </MenuItem>" +
            "              <MenuItem Header=\"Macintosh (CR)\" Name=\"mnuEolCR\">" +
            "                <MenuItem.ToolTip><TextBlock>Carriage Return only (0D). Classic Mac OS 9 and earlier.</TextBlock></MenuItem.ToolTip>" +
            "              </MenuItem>" +
            "            </MenuItem>" +
            "            <MenuItem Header=\"_Encoding\">" +
            "              <MenuItem Header=\"UTF-8 (no BOM)\" Name=\"mnuEncUtf8\">" +
            "                <MenuItem.ToolTip><TextBlock>Unicode without byte-order mark. Recommended default.</TextBlock></MenuItem.ToolTip>" +
            "              </MenuItem>" +
            "              <MenuItem Header=\"UTF-8 (BOM)\" Name=\"mnuEncUtf8Bom\">" +
            "                <MenuItem.ToolTip><TextBlock>Unicode with 3-byte BOM (EF BB BF).</TextBlock></MenuItem.ToolTip>" +
            "              </MenuItem>" +
            "              <Separator/>" +
            "              <MenuItem Header=\"UTF-16 LE (BOM)\" Name=\"mnuEncUtf16LE\">" +
            "                <MenuItem.ToolTip><TextBlock>Little-endian UTF-16 (FF FE). Native Windows Unicode encoding.</TextBlock></MenuItem.ToolTip>" +
            "              </MenuItem>" +
            "              <MenuItem Header=\"UTF-16 BE (BOM)\" Name=\"mnuEncUtf16BE\">" +
            "                <MenuItem.ToolTip><TextBlock>Big-endian UTF-16 (FE FF).</TextBlock></MenuItem.ToolTip>" +
            "              </MenuItem>" +
            "            </MenuItem>" +
            "            <Separator/>" +
            "            <MenuItem Header=\"_Editor Settings...\" Name=\"mnuEditorCfg\"/>" +
            "          </MenuItem>" +
            "          <MenuItem Header=\"_View\">" +
            "            <MenuItem Header=\"_Status Bar\" Name=\"mnuStatusBar\" IsCheckable=\"True\" IsChecked=\"True\"/>" +
            "          </MenuItem>" +
            "        </Menu>" +
            "      </Border>" +
            "    </Border>" +
            "    <Border DockPanel.Dock=\"Bottom\" Name=\"statusBorder\" BorderBrush=\"#808080\" BorderThickness=\"0,1,0,0\">" +
            "      <Border BorderBrush=\"#DFDFDF\" BorderThickness=\"0,1,0,0\">" +
            "        <StatusBar Name=\"statusBar\" Background=\"#E8E8E8\" Padding=\"6,1\" Height=\"22\">" +
            "          <StatusBar.ItemsPanel>" +
            "            <ItemsPanelTemplate><DockPanel LastChildFill=\"False\"/></ItemsPanelTemplate>" +
            "          </StatusBar.ItemsPanel>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"8,0\"><TextBlock Name=\"txtEnc\"   Text=\"UTF-8\"          Style=\"{StaticResource SBText}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"0\"><Rectangle Style=\"{StaticResource SBSep}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"8,0\"><TextBlock Name=\"txtEol\"   Text=\"Windows (CRLF)\" Style=\"{StaticResource SBText}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"0\"><Rectangle Style=\"{StaticResource SBSep}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"8,0\"><TextBlock Name=\"txtZoom\"  Text=\"100%\"           Style=\"{StaticResource SBText}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"0\"><Rectangle Style=\"{StaticResource SBSep}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"8,0\"><TextBlock Name=\"txtLines\" Text=\"Lines: 1\"       Style=\"{StaticResource SBText}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"0\"><Rectangle Style=\"{StaticResource SBSep}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"8,0\"><TextBlock Name=\"txtChars\" Text=\"Chars: 0\"       Style=\"{StaticResource SBText}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"0\"><Rectangle Style=\"{StaticResource SBSep}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"8,0\"><TextBlock Name=\"txtWords\" Text=\"Words: 0\"       Style=\"{StaticResource SBText}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"0\"><Rectangle Style=\"{StaticResource SBSep}\"/></StatusBarItem>" +
            "          <StatusBarItem DockPanel.Dock=\"Right\" Padding=\"8,0,10,0\"><TextBlock Name=\"txtPos\" Text=\"Ln 1, Col 1\" Style=\"{StaticResource SBText}\"/></StatusBarItem>" +
            "        </StatusBar>" +
            "      </Border>" +
            "    </Border>" +
            "    <Border Background=\"#F0F0F0\">" +
            "      <TextBox Name=\"txtEditor\"" +
            "               AcceptsReturn=\"True\" AcceptsTab=\"True\"" +
            "               VerticalScrollBarVisibility=\"Auto\"" +
            "               HorizontalScrollBarVisibility=\"Auto\"" +
            "               BorderThickness=\"0\"" +
            "               Background=\"#FFFFFF\" Foreground=\"#1E1E1E\"" +
            "               Padding=\"8,6\" UndoLimit=\"2000\" IsUndoEnabled=\"True\"" +
            "               FontFamily=\"Consolas\" FontSize=\"14\"" +
            "               SpellCheck.IsEnabled=\"False\"/>" +
            "    </Border>" +
            "  </DockPanel>" +
            "</Window>";
    }
}
"@

$ReferencedAssemblies = @(
    "System",
    "System.Core",
    "System.Xml",
    "PresentationFramework",
    "PresentationCore",
    "WindowsBase",
    "System.Xaml",
    "System.Windows.Forms",
    "System.Drawing"
)

Write-Host "Compiling C# Notepad..." -ForegroundColor Cyan
try {
    Add-Type `
        -TypeDefinition       $CSharpCode `
        -Language             CSharp `
        -OutputAssembly       $OutputExe `
        -OutputType           WindowsApplication `
        -ReferencedAssemblies $ReferencedAssemblies `
        -ErrorAction          Stop

    Write-Host "Done: $OutputExe" -ForegroundColor Green
}
catch {
    Write-Error "Compilation failed: $_"
}
