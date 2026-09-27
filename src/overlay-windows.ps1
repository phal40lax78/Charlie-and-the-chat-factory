# VS-code-chat-manager, src/overlay-windows.ps1: dot-sourced by VS-code-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region overlay: Windows window ------------------------------------------------
# WPF in a hidden powershell.exe -STA. The window never takes focus and lets
# clicks through while locked: WS_EX_NOACTIVATE, WS_EX_TRANSPARENT on top of
# the WS_EX_LAYERED a transparent WPF window has anyway, and WS_EX_TOOLWINDOW
# to keep it out of Alt+Tab and off the taskbar. Its buttons are a second
# small window beside it, shown while the pointer is near, which takes the
# mouse where it is drawn. The C# below is C# 5, which is what Windows
# PowerShell 5.1 compiles, and holds nothing that moves the pointer, types,
# or brings a window forward; the pointer, and which window is in front, are
# only ever read. The console is a mode of this same window
# (Enter-ChatOverlayConsoleMode): while it shows, the window is one like any
# other, and takes focus.

$script:ChatOverlayNativeCode = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class ChatOverlayNative {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLong")] static extern int SetWindowLong32(IntPtr h, int i, int v);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    const int GWL_EXSTYLE = -20;
    public const long WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;
    const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_NOOWNERZORDER = 0x200;

    public static long GetExStyle(IntPtr h) {
        return IntPtr.Size == 8 ? GetWindowLongPtr64(h, GWL_EXSTYLE).ToInt64() : GetWindowLong32(h, GWL_EXSTYLE);
    }
    static void SetExStyle(IntPtr h, long v) {
        if (IntPtr.Size == 8) { SetWindowLongPtr64(h, GWL_EXSTYLE, new IntPtr(v)); } else { SetWindowLong32(h, GWL_EXSTYLE, (int)v); }
    }
    // always a tool window that never activates; clicks go through only while
    // locked. WPF sets APPWINDOW for ShowInTaskbar, which would put a button
    // on the taskbar in spite of TOOLWINDOW, so it goes.
    public static void ApplyExStyle(IntPtr h, bool clickThrough) {
        long s = (GetExStyle(h) | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED) & ~WS_EX_APPWINDOW;
        s = clickThrough ? (s | WS_EX_TRANSPARENT) : (s & ~WS_EX_TRANSPARENT);
        SetExStyle(h, s);
    }
    // The console's mode of the same window: one like any other, that takes
    // clicks and focus and is on the taskbar and in Alt+Tab. LAYERED stays,
    // as a transparent WPF window has it from the start.
    public static void ApplyInteractiveStyle(IntPtr h) {
        long s = (GetExStyle(h) | WS_EX_APPWINDOW | WS_EX_LAYERED) & ~(WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        SetExStyle(h, s);
    }
    // back above windows that took the topmost band since - without activating
    public static void KeepTopmost(IntPtr h) {
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    // out of the topmost band, so other windows can cover it - without activating
    public static void DropTopmost(IntPtr h) {
        SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    public static void MoveTo(IntPtr h, int x, int y) {
        SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }
    // where and how big, in the pixels of the screen it lands on
    public static void Place(IntPtr h, int x, int y, int w, int hgt) {
        SetWindowPos(h, IntPtr.Zero, x, y, w, hgt, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }
    public static int[] GetRect(IntPtr h) {
        RECT r;
        if (!GetWindowRect(h, out r)) { return null; }
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }
    // the process whose window is in front, 0 for none - read, never set:
    // whether a chat that just finished was in front (Update-ChatOverlayUnread)
    public static int ForegroundPid() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) { return 0; }
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }
    // per-monitor v2 where Windows has it (1703+), else system-wide
    public static bool SetDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) { return true; } } catch (EntryPointNotFoundException) { }
        try { return SetProcessDPIAware(); } catch (EntryPointNotFoundException) { return false; }
    }
    // a file dropped on the console, copied off the window's thread: a large
    // one would otherwise freeze the panel and the console both
    public static System.Threading.Tasks.Task CopyFileAsync(string from, string to) {
        return System.Threading.Tasks.Task.Run(() => System.IO.File.Copy(from, to, true));
    }
}

// A system-wide hotkey: a hidden window of its own to receive WM_HOTKEY,
// filtered here so PowerShell hears only the key press, not every message.
public class ChatOverlayHotkey : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int WM_HOTKEY = 0x312;
    const uint MOD_NOREPEAT = 0x4000;
    bool registered;
    public event EventHandler Pressed;
    public ChatOverlayHotkey() { CreateHandle(new CreateParams()); }
    public bool Register(uint mods, uint vk) {
        if (registered) { UnregisterHotKey(Handle, 1); registered = false; }
        registered = RegisterHotKey(Handle, 1, mods | MOD_NOREPEAT, vk);
        return registered;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && Pressed != null) { Pressed(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
    public void Dispose() {
        if (registered) { UnregisterHotKey(Handle, 1); registered = false; }
        if (Handle != IntPtr.Zero) { DestroyHandle(); }
    }
}
'@

# Two looks. A state keeps its colour's meaning in both; the light look's are
# darker, to read on white. panel is the ground of the buttons and settings
# box, which sit over the rows; accent marks the choice made, and a chat
# with a turn unseen. recent is a chat not open: no state, so faint.
$script:ChatOverlayPalettes = @{
    dark  = @{
        waiting = '#F5B942'; 'needs-input' = '#F5B942'; busy = '#4CC38A'; running = '#4EA1FF'; idle = '#80868F'; queued = '#B48CFF'; cutoff = '#FF8A4C'; recent = '#6B7079'
        text = '#E8EAED'; dim = '#9AA0A6'; faint = '#6B7079'; project = '#8AB8FF'; frame = '#EB1B1F24'; edge = '#2EFFFFFF'
        unlocked = '#4EA1FF'; track = '#26FFFFFF'; normal = '#5AA9E6'; warning = '#F5B942'; critical = '#FF5C5C'
        warn = '#F5B942'; error = '#FF7B72'; panel = '#F7262B33'; hover = '#33FFFFFF'; accent = '#4EA1FF'; onAccent = '#FFFFFF'
        window = '#FF1E2227'; input = '#FF15181C'; inputEdge = '#3DFFFFFF'; select = '#384EA1FF'
    }
    light = @{
        waiting = '#C98A00'; 'needs-input' = '#C98A00'; busy = '#1A8F4C'; running = '#1F6FEB'; idle = '#8C959F'; queued = '#8250DF'; cutoff = '#BC4C00'; recent = '#8C959F'
        text = '#1F2328'; dim = '#57606A'; faint = '#8C959F'; project = '#0969DA'; frame = '#F2FAFAFB'; edge = '#26000000'
        unlocked = '#0969DA'; track = '#1F000000'; normal = '#0969DA'; warning = '#BF8700'; critical = '#CF222E'
        warn = '#9A6700'; error = '#CF222E'; panel = '#FAFFFFFF'; hover = '#1A000000'; accent = '#0969DA'; onAccent = '#FFFFFF'
        window = '#FFF6F8FA'; input = '#FFFFFFFF'; inputEdge = '#40000000'; select = '#290969DA'
    }
}
$script:ChatOverlayColors = $script:ChatOverlayPalettes.dark

function Initialize-ChatOverlayNative {
    # In the one order that works: DPI awareness is process-wide and only the
    # first call gets to set it, and WPF reads it as it loads. The AppContext
    # switch lets WPF redraw at a second monitor's own scale when the panel is
    # dragged there, instead of keeping the first one's.
    if (-not ('ChatOverlayNative' -as [type])) {
        Add-Type -TypeDefinition $script:ChatOverlayNativeCode -ReferencedAssemblies System.Windows.Forms
    }
    # A type is compiled once per process: one that loaded an older copy of
    # this script keeps its ChatOverlayNative, without the console mode's
    # calls. The same code goes in again under names of its own then, and
    # the console mode's calls go through $script:ChatOverlayModeNative.
    $script:ChatOverlayModeNative = [ChatOverlayNative]
    if (-not [ChatOverlayNative].GetMethod('ApplyInteractiveStyle')) {
        if (-not ('ChatOverlayNativeNext' -as [type])) {
            $next = $script:ChatOverlayNativeCode -replace '\bChatOverlayNative\b', 'ChatOverlayNativeNext' -replace '\bChatOverlayHotkey\b', 'ChatOverlayHotkeyNext'
            Add-Type -TypeDefinition $next -ReferencedAssemblies System.Windows.Forms
        }
        $script:ChatOverlayModeNative = 'ChatOverlayNativeNext' -as [type]
    }
    try { [void][ChatOverlayNative]::SetDpiAware() } catch { Write-ChatOverlayLog "dpi: $($_.Exception.Message)" }
    try { [System.AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false) } catch {}
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
    # A panel this small, redrawn every few seconds at most, gains nothing
    # from a Direct3D device - which is most of what WPF would otherwise hold.
    try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch {}
}

function Get-ChatOverlayBrush {
    param([string]$Name)
    $hex = if ($Name.StartsWith('#')) { $Name } else { $script:ChatOverlayColors[$Name] }
    if (-not $hex) { $hex = $script:ChatOverlayColors.text }
    $b = $script:ChatOverlayBrushes[$hex]
    if (-not $b) {
        $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
        $b.Freeze()
        $script:ChatOverlayBrushes[$hex] = $b
    }
    return $b
}

function New-ChatOverlayText {
    param([string]$Text, [string]$Color = 'text', [double]$Size = 0, [switch]$Bold, [switch]$Trim)
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    $t.Foreground = Get-ChatOverlayBrush $Color
    if ($Size) { $t.FontSize = $Size }
    if ($Bold) { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Trim) { $t.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis }
    return $t
}

function New-ChatOverlayWindow {
    # The window and its frame, built in code rather than XAML: rows come and
    # go every pass, and one way of making elements is simpler than two.
    param($H)
    $cfg = $H.Ctx.Config
    [void](Select-ChatOverlayPalette $H)
    $w = [System.Windows.Window]::new()
    $w.Title = 'chatoverlay'
    $w.WindowStyle = [System.Windows.WindowStyle]::None
    $w.AllowsTransparency = $true
    $w.Background = [System.Windows.Media.Brushes]::Transparent
    $w.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $w.Topmost = $true
    $w.ShowActivated = $false
    # true, with WS_EX_TOOLWINDOW keeping it off the taskbar: false would make
    # WPF parent the window to a hidden owner that is not topmost
    $w.ShowInTaskbar = $true
    $w.SizeToContent = [System.Windows.SizeToContent]::Height
    $w.Width = $cfg.width
    $w.Opacity = $cfg.opacity
    $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $w.Left = -32000
    $w.Top = -32000
    $w.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI, Malgun Gothic, Microsoft YaHei UI')
    $w.FontSize = 12
    $frame = [System.Windows.Controls.Border]::new()
    $frame.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $frame.Background = Get-ChatOverlayBrush 'frame'
    $frame.BorderBrush = Get-ChatOverlayBrush 'edge'
    $frame.BorderThickness = [System.Windows.Thickness]::new(1)
    $frame.Padding = [System.Windows.Thickness]::new(11, 8, 11, 9)
    $stack = [System.Windows.Controls.StackPanel]::new()
    $frame.Child = $stack
    $w.Content = $frame
    # only ever raised while unlocked - a locked window lets the mouse through
    $frame.add_MouseLeftButtonDown({ Invoke-ChatOverlayDrag })
    $frame.add_MouseEnter({ $script:ChatOverlayHost.PointerIn = $true })
    $frame.add_MouseLeave({ $script:ChatOverlayHost.PointerIn = $false; $script:ChatOverlayHost.LeftAt = Get-Date })
    # The console's mode only - the panel never has the keyboard, nor a
    # close button. Alt+F4, or anything else that would close it, goes back
    # to the panel instead, unless the overlay is stopping; put off a moment,
    # as WPF refuses to hide a window from inside its own Closing.
    $w.add_Closing({
            param($s, $e)
            $X = $script:ChatOverlayHost
            if ($X -and $X.Mode -eq 'console' -and -not $X.ShuttingDown) {
                $e.Cancel = $true
                [void]$s.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [Action] { Exit-ChatOverlayConsoleMode $script:ChatOverlayHost })
            }
        })
    # Esc goes back to the panel; any key holds off the next collector pass a
    # moment, so typing never stutters behind one
    $w.add_PreviewKeyDown({
            param($s, $e)
            $X = $script:ChatOverlayHost
            if (-not $X -or $X.Mode -ne 'console' -or -not $X.Con) { return }
            $X.Con.TypedAt = Get-Date
            if ($e.Key -eq [System.Windows.Input.Key]::Escape -and -not $X.Con.Modal) { $e.Handled = $true; Exit-ChatOverlayConsoleMode $X }
        })
    $H.Win = $w
    $H.Frame = $frame
    $H.Stack = $stack
    $H.Hwnd = [System.Windows.Interop.WindowInteropHelper]::new($w).EnsureHandle()
    [ChatOverlayNative]::ApplyExStyle($H.Hwnd, $H.Locked)
    New-ChatOverlayControlsWindow $H
    New-ChatOverlayChipWindow $H
}

function New-ChatOverlayControlsWindow {
    <#
    The buttons and the settings box live in a small window of their own,
    on the panel's top edge rather than over its rows. So the panel stays
    click-through all over, and this one - shown only while the pointer is
    near - takes the mouse where it is drawn; its see-through parts let
    clicks through, as any layered window's do. The same styles as the panel
    less WS_EX_TRANSPARENT: it never takes focus either, and is in neither
    Alt+Tab nor the taskbar. Kept at full opacity, so the slider stays
    readable whatever it is set to.
    #>
    param($H)
    $c = [System.Windows.Window]::new()
    $c.Title = 'chatoverlay controls'
    $c.WindowStyle = [System.Windows.WindowStyle]::None
    $c.AllowsTransparency = $true
    $c.Background = [System.Windows.Media.Brushes]::Transparent
    $c.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $c.Topmost = $true
    $c.ShowActivated = $false
    # true for the same reason as the panel's: false means a hidden owner
    # that is not topmost
    $c.ShowInTaskbar = $true
    $c.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $c.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $c.Left = -32000
    $c.Top = -32000
    $c.FontFamily = $H.Win.FontFamily
    $c.FontSize = 12
    $stack = [System.Windows.Controls.StackPanel]::new()
    $c.Content = $stack
    $H.CtlWin = $c
    $H.CtlStack = $stack
    New-ChatOverlayControls $H
    $H.CtlHwnd = [System.Windows.Interop.WindowInteropHelper]::new($c).EnsureHandle()
    [ChatOverlayNative]::ApplyExStyle($H.CtlHwnd, $false)
    # the box opening or closing changes its size; the edge by the panel stays
    $c.add_SizeChanged({ param($s, $e) Set-ChatOverlayControlsPlacement $script:ChatOverlayHost $e.NewSize })
}

function Select-ChatOverlayPalette {
    # the colours for the theme set, and whether that changed the look
    param($H)
    $name = Resolve-ChatOverlayTheme $H.Ctx.Config.theme
    if ($name -eq $H.ThemeName) { return $false }
    $H.ThemeName = $name
    $script:ChatOverlayColors = $script:ChatOverlayPalettes[$name]
    return $true
}

function Update-ChatOverlayTheme {
    # the look again, after the setting or Windows' own changed: the frame,
    # the buttons and settings box made anew, the rows redrawn, the tray dot
    param($H)
    if (-not (Select-ChatOverlayPalette $H)) { return }
    $H.Frame.Background = Get-ChatOverlayBrush 'frame'
    $H.Frame.BorderBrush = Get-ChatOverlayBrush $(if ($H.Locked) { 'edge' } else { 'unlocked' })
    New-ChatOverlayControls $H
    Hide-ChatOverlayChip $H
    if ($H.ChipWin) { New-ChatOverlayChipContent $H }
    # the console too, keeping what is typed in it - and in the window
    # still, if it shows
    if ($H.Con) { Initialize-ChatConsoleContent $H }
    $H.ViewKey = $null
    if ($H.Snap) {
        Update-ChatOverlayView $H $H.Snap
        if ($H.Tray) { Update-ChatOverlayTray $H $H.Snap }
    }
}

function New-ChatOverlayIcon {
    # A small button drawn as a path, so no icon font is needed: stroked for
    # lines, filled for dots, or both.
    param([string]$Tip, $Geometry, [switch]$Stroke, [switch]$Fill)
    $b = [System.Windows.Controls.Border]::new()
    $b.Width = 22
    $b.Height = 20
    $b.CornerRadius = [System.Windows.CornerRadius]::new(4)
    # transparent, not none: WPF sends the mouse only to what is painted
    $b.Background = [System.Windows.Media.Brushes]::Transparent
    $b.ToolTip = $Tip
    $p = [System.Windows.Shapes.Path]::new()
    $p.Data = $Geometry
    if ($Stroke) {
        $p.Stroke = Get-ChatOverlayBrush 'dim'
        $p.StrokeThickness = 1.4
        $p.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
        $p.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    }
    if ($Fill) { $p.Fill = Get-ChatOverlayBrush 'dim' }
    $p.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $p.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $b.Child = $p
    $b.add_MouseEnter({ param($s, $e) $s.Background = Get-ChatOverlayBrush 'hover' })
    $b.add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })
    return $b
}

function New-ChatOverlayControls {
    <#
    The controls window's content: a row of buttons - drag grip, resize
    handle, collapse, refresh usage, the console, settings, hide to the
    tray, close, left to right, so close sits at the corner as it does on
    any window - and the settings box on the far side of them from the
    panel. Made anew when the look changes or the panel folds; the box
    stays open or shut as it was.
    #>
    param($H)
    $H.CtlStack.Children.Clear()
    $geo = { param($d) [System.Windows.Media.Geometry]::Parse($d) }
    $dots = [System.Windows.Media.GeometryGroup]::new()
    foreach ($x in 1.5, 5.5) { foreach ($y in 1.5, 5.5, 9.5) { $dots.Children.Add([System.Windows.Media.EllipseGeometry]::new([System.Windows.Point]::new($x, $y), 1.25, 1.25)) } }
    $sliders = [System.Windows.Media.GeometryGroup]::new()
    $sliders.Children.Add((& $geo 'M0,2.5 L11,2.5 M0,8.5 L11,8.5'))
    $sliders.Children.Add([System.Windows.Media.EllipseGeometry]::new([System.Windows.Point]::new(3.5, 2.5), 1.8, 1.8))
    $sliders.Children.Add([System.Windows.Media.EllipseGeometry]::new([System.Windows.Point]::new(7.5, 8.5), 1.8, 1.8))
    # a chevron pointing where the panel will go: up to fold it, down to open it
    $fold = if ($H.Collapsed) { & $geo 'M0.5,1 L4.5,5 L8.5,1' } else { & $geo 'M0.5,5 L4.5,1 L8.5,5' }
    # a circle with a gap and an arrowhead
    $again = & $geo 'M8.6,3.2 A4,4 0 1 0 9,6.5 M8.8,0.6 L8.7,3.4 L5.9,3.1'
    # an arrow down onto a line: into the tray
    $tray = & $geo 'M4.5,0.5 L4.5,6 M2,3.6 L4.5,6 L7,3.6 M0.5,9 L8.5,9'
    # a speech bubble: the console, to write to a chat
    $bubble = & $geo 'M1,1 L10,1 L10,7 L4.5,7 L2,9.5 L2,7 L1,7 Z'
    $cross = & $geo 'M0.5,0.5 L8.5,8.5 M8.5,0.5 L0.5,8.5'
    # two arrows on one diagonal, out to the corners: the resize handle
    $corners = & $geo 'M1,9 L9,1 M5,1 L9,1 L9,5 M1,5 L1,9 L5,9'

    $grip = New-ChatOverlayIcon 'Drag to move' $dots -Fill
    $grip.Cursor = [System.Windows.Input.Cursors]::SizeAll
    $grip.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Start-ChatOverlayGripDrag $s })
    $grip.add_MouseMove({ param($s, $e) Move-ChatOverlayGripDrag })
    $grip.add_MouseLeftButtonUp({ param($s, $e) Stop-ChatOverlayGripDrag $s })
    $grip.add_LostMouseCapture({ param($s, $e) Stop-ChatOverlayGripDrag $s })
    $sizeB = New-ChatOverlayIcon 'Drag to resize - sideways for width, up and down for rows' $corners -Stroke
    $sizeB.Cursor = [System.Windows.Input.Cursors]::SizeNESW
    $sizeB.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Start-ChatOverlaySizeDrag $s })
    $sizeB.add_MouseMove({ param($s, $e) Move-ChatOverlaySizeDrag })
    $sizeB.add_MouseLeftButtonUp({ param($s, $e) Stop-ChatOverlaySizeDrag $s })
    $sizeB.add_LostMouseCapture({ param($s, $e) Stop-ChatOverlaySizeDrag $s })
    $foldB = New-ChatOverlayIcon $(if ($H.Collapsed) { 'Expand' } else { 'Collapse to one line' }) $fold -Stroke
    $foldB.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-ChatOverlayVerb $(if ($script:ChatOverlayHost.Collapsed) { 'expand' } else { 'collapse' }) })
    $againB = New-ChatOverlayIcon 'Ask Claude for usage now - Codex''s moves only when Codex runs' $again -Stroke
    $againB.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-ChatOverlayRefresh })
    # turns while an ask is out (Update-ChatOverlaySpin), about the arc's centre
    $againB.Child.RenderTransform = [System.Windows.Media.RotateTransform]::new(0, 5.2, 5.3)
    $H.Spin = $againB.Child.RenderTransform
    $H.Spinning = $false
    $conB = New-ChatOverlayIcon 'The console, in the panel''s place - write to a chat, queue, continue; Esc brings the panel back' $bubble -Stroke
    $conB.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-ChatOverlayVerb 'console' })
    $gear = New-ChatOverlayIcon 'Settings - size, rows, opacity, theme, usage, compact rows, recent chats, cut-off chats' $sliders -Stroke -Fill
    $gear.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Set-ChatOverlaySettingsOpen $script:ChatOverlayHost (-not $script:ChatOverlayHost.SettingsOpen) })
    $trayB = New-ChatOverlayIcon 'Hide to the tray - click the tray dot to show it' $tray -Stroke
    $trayB.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Hide-ChatOverlayByButton })
    $close = New-ChatOverlayIcon 'Close the overlay - it starts again with the next shell or VS Code window; chatoverlay -AutoStart off keeps it closed' $cross -Stroke
    $close.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-ChatOverlayVerb 'stop' })
    $line = [System.Windows.Controls.StackPanel]::new()
    $line.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $H.CtlButtons = @($grip, $foldB, $againB, $conB, $gear, $trayB, $close)
    foreach ($b in $H.CtlButtons) { [void]$line.Children.Add($b) }
    # the handle beside the grip, since both are dragged rather than
    # clicked; CtlButtons keeps its places, the collapse button second
    $line.Children.Insert(1, $sizeB)
    $H.CtlSize = $sizeB
    $H.CtlLine = $line
    $bar = [System.Windows.Controls.Border]::new()
    $bar.Background = Get-ChatOverlayBrush 'panel'
    $bar.BorderBrush = Get-ChatOverlayBrush 'edge'
    $bar.BorderThickness = [System.Windows.Thickness]::new(1)
    $bar.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $bar.Padding = [System.Windows.Thickness]::new(1)
    $bar.Child = $line
    $H.Controls = $bar
    $H.Settings = New-ChatOverlaySettings $H
    Set-ChatOverlayControlsSide $H $(if ($H.CtlSide) { $H.CtlSide } else { 'above' })
}

function New-ChatOverlaySettings {
    <#
    The box beside the row of buttons: opacity, and width and rows side by
    side, on sliders; the theme, usage as lines or bars, rows full or
    compact, how many recent chats, and whether to ask about the chats the
    limit cut off once it is over, as choices. Each slider applies as
    it moves, and config.json
    gets it once it rests; a slider's handler does nothing while
    Sync-ChatOverlaySettings sets it. Kept short - a row of its own for each
    setting would make it too tall to fit under a panel at the top of the
    screen - so a new row goes at the end, a choice as a row of chips.
    #>
    param($H)
    $theme = [string]$H.Ctx.Config.theme
    $box = [System.Windows.Controls.Border]::new()
    $box.Background = Get-ChatOverlayBrush 'panel'
    $box.BorderBrush = Get-ChatOverlayBrush 'edge'
    $box.BorderThickness = [System.Windows.Thickness]::new(1)
    $box.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $box.Padding = [System.Windows.Thickness]::new(10, 5, 10, 5)
    $box.Width = 280
    $box.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $box.Visibility = if ($H.SettingsOpen) { 'Visible' } else { 'Collapsed' }
    $g = [System.Windows.Controls.Grid]::new()
    # label, slider, its value - then, on the width row alone, the rows
    # label, slider and value; everything else spans them
    foreach ($cw in 44, 0, 30, -1, 0, 30) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        $cd.Width = if ($cw -gt 0) { [System.Windows.GridLength]::new($cw) } elseif ($cw -lt 0) { [System.Windows.GridLength]::Auto } else { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
        $g.ColumnDefinitions.Add($cd)
    }
    $put = {
        param($el, $row, $col, $span = 1)
        while ($g.RowDefinitions.Count -le $row) { $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) }
        [System.Windows.Controls.Grid]::SetRow($el, $row)
        [System.Windows.Controls.Grid]::SetColumn($el, $col)
        [System.Windows.Controls.Grid]::SetColumnSpan($el, $span)
        [void]$g.Children.Add($el)
    }
    $label = { param($t) $l = New-ChatOverlayText $t 'dim' 11; $l.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $l }

    & $put (& $label 'Opacity') 0 0
    $slider = [System.Windows.Controls.Slider]::new()
    $slider.Minimum = 0.3
    $slider.Maximum = 1.0
    $slider.SmallChange = 0.05
    $slider.LargeChange = 0.1
    $slider.IsMoveToPointEnabled = $true
    $slider.Value = if ($H.Win) { $H.Win.Opacity } else { $H.Ctx.Config.opacity }
    $slider.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $slider.Margin = [System.Windows.Thickness]::new(0, 1, 4, 1)
    $slider.add_ValueChanged({ param($s, $e) if (-not $script:ChatOverlayHost.SettingsSync) { Set-ChatOverlayOpacity $script:ChatOverlayHost $e.NewValue } })
    $slider.Tag = 'opacity'
    & $put $slider 0 1 4
    $H.OpacitySlider = $slider
    $H.OpacityText = New-ChatOverlayText "$([int][Math]::Round($slider.Value * 100))%" 'text' 11
    $H.OpacityText.TextAlignment = [System.Windows.TextAlignment]::Right
    $H.OpacityText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    & $put $H.OpacityText 0 5

    # whole numbers only, snapped as they move; the maximum set before the
    # minimum, or a default maximum of 10 would hold 260 down
    $whole = {
        param([string]$Tag, [int]$Lo, [int]$Hi, [int]$Now, [int]$Big)
        $s = [System.Windows.Controls.Slider]::new()
        $s.Maximum = $Hi
        $s.Minimum = $Lo
        $s.SmallChange = 1
        $s.LargeChange = $Big
        $s.TickFrequency = 1
        $s.IsSnapToTickEnabled = $true
        $s.IsMoveToPointEnabled = $true
        $s.Value = [Math]::Max($Lo, [Math]::Min($Hi, $Now))
        $s.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $s.Margin = [System.Windows.Thickness]::new(0, 1, 4, 1)
        $s.Tag = $Tag
        $s
    }
    $valueText = { param($t) $x = New-ChatOverlayText $t 'text' 11; $x.TextAlignment = [System.Windows.TextAlignment]::Right; $x.VerticalAlignment = [System.Windows.VerticalAlignment]::Center; $x }
    & $put (& $label 'Width') 1 0
    $wNow = if ($H.Win -and $H.Win.Width -gt 0) { [int]$H.Win.Width } else { [int]$H.Ctx.Config.width }
    $wide = & $whole 'width' 260 800 $wNow 40
    $wide.add_ValueChanged({ param($s, $e) if (-not $script:ChatOverlayHost.SettingsSync) { Set-ChatOverlayWidthChoice $script:ChatOverlayHost $e.NewValue } })
    & $put $wide 1 1
    $H.WidthSlider = $wide
    $H.WidthText = & $valueText "$([int]$wide.Value)"
    & $put $H.WidthText 1 2
    $rowsLabel = & $label 'Rows'
    $rowsLabel.Margin = [System.Windows.Thickness]::new(10, 0, 6, 0)
    & $put $rowsLabel 1 3
    $tall = & $whole 'rows' 1 30 ([int]$H.Ctx.Config.maxRows) 5
    $tall.add_ValueChanged({ param($s, $e) if (-not $script:ChatOverlayHost.SettingsSync) { Set-ChatOverlayRowsChoice $script:ChatOverlayHost $e.NewValue } })
    & $put $tall 1 4
    $H.RowsSlider = $tall
    $H.RowsText = & $valueText "$([int]$tall.Value)"
    & $put $H.RowsText 1 5

    $choice = {
        param($row, [string]$Name, [string[]]$Names, [string]$Current, [scriptblock]$OnClick, [hashtable]$Tips, [string]$Tip)
        $l = & $label $Name
        if ($Tip) { $l.ToolTip = $Tip }
        & $put $l $row 0
        $c = New-ChatOverlayChips $Names $Current $OnClick -Tips $Tips
        $c.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        & $put $c $row 1 5
    }
    & $choice 2 'Theme' @('dark', 'light', 'system') $theme { param($s, $e) $e.Handled = $true; Set-ChatOverlayThemeChoice $script:ChatOverlayHost ([string]$s.Tag) }
    & $choice 3 'Usage' @('lines', 'bars') ([string]$H.Ctx.Config.usageView) { param($s, $e) $e.Handled = $true; Set-ChatOverlayUsageView $script:ChatOverlayHost ([string]$s.Tag) }
    # compact: the prompt line off, one line a chat
    & $choice 4 'Style' @('full', 'compact') $(if ($H.Ctx.Config.prompts) { 'full' } else { 'compact' }) { param($s, $e) $e.Handled = $true; Set-ChatOverlayRowStyle $script:ChatOverlayHost ([string]$s.Tag) }
    # the chats not open under the open ones: none, or a few. -Recent takes
    # any count up to 20; one set that way fills no chip
    $rc = [int]$H.Ctx.Config.recent
    & $choice 5 'Recent' @('off', '5', '10') $(if ($rc -le 0) { 'off' } else { "$rc" }) { param($s, $e) $e.Handled = $true; Set-ChatOverlayRecentChoice $script:ChatOverlayHost ([string]$s.Tag) }
    # what the limit cut off: continue it by itself, ask once it is over, or
    # only mark it. The setting is config.json's autoContinue, whose "on"
    # reads as Continue here and "off" as Leave
    $cutTips = @{
        continue = 'Continue each chat the limit cuts off, by itself.'
        ask      = 'Once the limit is over, say how many chats it cut off, and continue them on a click.'
        leave    = 'Only mark them - Continue in the console, or chatq ''<title>'' -Continue, queues one.'
    }
    $cutTip = 'A chat the usage limit cuts off: Continue sends it "Continue from where you left off." a minute after the reset. Ask says so once the limit is over, and continues it if you say so. Leave only marks it orange.'
    $cutNow = switch ([string]$H.Ctx.Config.autoContinue) { 'on' { 'continue' } 'ask' { 'ask' } default { 'leave' } }
    & $choice 6 'Cut off' @('continue', 'ask', 'leave') $cutNow { param($s, $e) $e.Handled = $true; Set-ChatOverlayAutoChoice $script:ChatOverlayHost ([string]$s.Tag) } $cutTips $cutTip
    $box.Child = $g
    return $box
}

function Sync-ChatOverlaySettings {
    # The sliders to what the panel has now: a drag of the resize handle or
    # a reload may have moved it while the box was shut, and a slider still
    # on the old value made the panel jump when next nudged. Their handlers
    # are kept out of it, or setting one would count as a move.
    param($H)
    if (-not $H) { return }
    $H.SettingsSync = $true
    try {
        if ($H.OpacitySlider) {
            $H.OpacitySlider.Value = $H.Win.Opacity
            if ($H.OpacityText) { $H.OpacityText.Text = "$([int][Math]::Round($H.Win.Opacity * 100))%" }
        }
        if ($H.WidthSlider) {
            $H.WidthSlider.Value = if ($H.Win.Width -gt 0) { [int]$H.Win.Width } else { [int]$H.Ctx.Config.width }
            if ($H.WidthText) { $H.WidthText.Text = "$([int]$H.WidthSlider.Value)" }
        }
        if ($H.RowsSlider) {
            $H.RowsSlider.Value = [int]$H.Ctx.Config.maxRows
            if ($H.RowsText) { $H.RowsText.Text = "$([int]$H.RowsSlider.Value)" }
        }
    }
    finally { $H.SettingsSync = $false }
}

function New-ChatOverlayChips {
    # a row of choices, the one in force filled in; a click hands its name
    # to -OnClick. -Tips: a tooltip for a chip, by its name
    param([string[]]$Names, [string]$Current, [scriptblock]$OnClick, [hashtable]$Tips)
    $chips = [System.Windows.Controls.StackPanel]::new()
    $chips.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $chips.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
    foreach ($t in $Names) {
        $on = $t -eq $Current
        $c = [System.Windows.Controls.Border]::new()
        $c.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $c.BorderThickness = [System.Windows.Thickness]::new(1)
        $c.Padding = [System.Windows.Thickness]::new(8, 1, 8, 2)
        $c.Margin = [System.Windows.Thickness]::new(0, 0, 4, 0)
        $c.Background = if ($on) { Get-ChatOverlayBrush 'accent' } else { [System.Windows.Media.Brushes]::Transparent }
        $c.BorderBrush = Get-ChatOverlayBrush $(if ($on) { 'accent' } else { 'edge' })
        $c.Cursor = [System.Windows.Input.Cursors]::Hand
        $c.Tag = $t
        $c.Child = New-ChatOverlayText ($t.Substring(0, 1).ToUpperInvariant() + $t.Substring(1)) $(if ($on) { 'onAccent' } else { 'text' }) 11
        if ($Tips -and $Tips[$t]) { $c.ToolTip = $Tips[$t] }
        $c.add_MouseLeftButtonUp($OnClick)
        [void]$chips.Children.Add($c)
    }
    return $chips
}

function Set-ChatOverlaySettingsOpen {
    # opened, its sliders show what the panel has now, not what it had when
    # the box was made
    param($H, [bool]$Open)
    $H.SettingsOpen = $Open
    if ($Open) { Sync-ChatOverlaySettings $H }
    if ($H.Settings) { $H.Settings.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' } }
}

function Show-ChatOverlayControls {
    # the controls window comes with the pointer and goes with it, closing
    # the box; placed before it shows, so it never flashes where it last was
    param($H, [bool]$Show)
    $H.ControlsShown = $Show
    if (-not $H.CtlWin) { return }
    if ($Show) {
        Set-ChatOverlayControlsPlacement $H
        $H.CtlWin.Show()
        # WPF sets WS_EX_APPWINDOW again as it shows a window
        [ChatOverlayNative]::ApplyExStyle($H.CtlHwnd, $false)
        [ChatOverlayNative]::KeepTopmost($H.CtlHwnd)
        Set-ChatOverlayControlsPlacement $H
    }
    else {
        if ($H.SettingsOpen) { Set-ChatOverlaySettingsOpen $H $false }
        $H.CtlWin.Hide()
    }
}

function Get-ChatOverlayControlsPlacement {
    <#
    Where the controls window goes, all in screen pixels (-Panel a rect,
    x y width height; -Size just width and height): its long edge along the
    panel's top, its right end at the panel's top-right corner - above the
    panel while the row of buttons (-Bar tall) fits there, else below it,
    on the side -Prefer names while it fits: the side they are on while
    they are up, above otherwise. So the box opening, which makes the window
    taller away from the panel, never moves the buttons out from under the
    pointer; a box too tall for its side is kept on the screen instead. Kept
    on the screen side to side too. Pure, for the tests.
    #>
    param([int[]]$Panel, [int[]]$Size, $Screen, [int]$Gap = 4, [string]$Prefer = 'above', [int]$Bar = 0)
    if ($Bar -le 0) { $Bar = $Size[1] }
    $top = $Screen.Y
    $bottom = $Screen.Y + $Screen.Height
    $fitsAbove = $Panel[1] - $Gap - $Bar -ge $top
    $fitsBelow = $Panel[1] + $Panel[3] + $Gap + $Bar -le $bottom
    $side = if ($Prefer -eq 'below') { if ($fitsBelow -or -not $fitsAbove) { 'below' } else { 'above' } }
    else { if ($fitsAbove -or -not $fitsBelow) { 'above' } else { 'below' } }
    $y = if ($side -eq 'above') { [Math]::Max($top, $Panel[1] - $Gap - $Size[1]) } else { [Math]::Min($bottom - $Size[1], $Panel[1] + $Panel[3] + $Gap) }
    $x = [Math]::Max($Screen.X, [Math]::Min($Panel[0] + $Panel[2] - $Size[0], $Screen.X + $Screen.Width - $Size[0]))
    return [pscustomobject]@{ X = [int]$x; Y = [int]$y; Side = $side }
}

function Set-ChatOverlayControlsSide {
    # The row of buttons hugs the panel's edge, above it or below, flush
    # with its right; the settings box goes on the far side of the row, so
    # opening it never pushes the row off the panel's edge.
    param($H, [string]$Side)
    $H.CtlSide = $Side
    foreach ($el in @($H.Controls, $H.Settings)) { if ($el) { $el.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right } }
    if (-not $H.CtlStack -or -not $H.Controls -or -not $H.Settings) { return }
    $H.Settings.Margin = if ($Side -eq 'below') { [System.Windows.Thickness]::new(0, 4, 0, 0) } else { [System.Windows.Thickness]::new(0, 0, 0, 4) }
    $H.CtlStack.Children.Clear()
    $order = if ($Side -eq 'below') { $H.Controls, $H.Settings } else { $H.Settings, $H.Controls }
    foreach ($el in $order) { [void]$H.CtlStack.Children.Add($el) }
}

function Get-ChatOverlayControlsTarget {
    # Where the controls window goes now, in screen pixels - x, y, width,
    # height, the side of the panel and the gap to it - worked out as for
    # placing it, without moving it: the pointer check wants the spot while
    # it is hidden too. -Dip the size it is about to take, in WPF's units.
    param($H, $Dip)
    if (-not $H -or -not $H.CtlWin -or $H.CtlHwnd -eq [IntPtr]::Zero -or $H.Hwnd -eq [IntPtr]::Zero) { return $null }
    $p = [ChatOverlayNative]::GetRect($H.Hwnd)
    $c = [ChatOverlayNative]::GetRect($H.CtlHwnd)
    if (-not $p -or -not $c) { return $null }
    $a = if ($script:ChatOverlayWorkAreaSeam) { & $script:ChatOverlayWorkAreaSeam $p }
    else { [System.Windows.Forms.Screen]::FromRectangle([System.Drawing.Rectangle]::new($p[0], $p[1], $p[2], $p[3])).WorkingArea }
    # this screen's pixels to one of WPF's units: 4 of them between the two
    $px = $p[2] / [Math]::Max(1.0, [double]$H.Win.ActualWidth)
    $gap = [int][Math]::Round(4 * $px)
    # Its width and height - never its rect, whose first two numbers are
    # where it is: placed by those, it jumped between two spots each pass.
    # Its rect is behind in two cases. As the box opens or shuts, WPF says
    # the new size before the window takes it, so that size is passed in:
    # the window moves as it grows and is never over the panel. Hidden, it
    # keeps the size it last had, or WPF's default before it first shows, so
    # what its content will take instead: it never shows up somewhere else
    # first.
    if (-not $Dip -and -not $H.CtlWin.IsVisible) {
        $H.CtlStack.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $Dip = $H.CtlStack.DesiredSize
    }
    $size = if ($Dip) { @([int][Math]::Ceiling($Dip.Width * $px), [int][Math]::Ceiling($Dip.Height * $px)) } else { @($c[2], $c[3]) }
    # the row of buttons' own height: what has to fit beside the panel
    $rowDip = if (-not $H.Controls) { 0 } elseif ($H.Controls.ActualHeight -gt 0) { $H.Controls.ActualHeight } else { $H.Controls.DesiredSize.Height }
    $bar = [int][Math]::Round($rowDip * $px)
    # Up, they keep their side while they fit there, so the box opening or
    # a drag short of the screen's edge never moves them out from under the
    # pointer. Hidden, above wins again wherever it fits: held for good, a
    # panel started at the screen's top and dragged down kept them under it
    # until the overlay restarted.
    $prefer = if ($H.CtlWin.IsVisible) { $H.CtlSide } else { 'above' }
    $at = Get-ChatOverlayControlsPlacement $p $size ([pscustomobject]@{ X = $a.X; Y = $a.Y; Width = $a.Width; Height = $a.Height }) $gap $prefer $bar
    return [pscustomobject]@{ X = $at.X; Y = $at.Y; Width = $size[0]; Height = $size[1]; Side = $at.Side; Gap = $gap; Now = $c }
}

function Set-ChatOverlayControlsPlacement {
    # the controls window on the panel's top edge, wherever the panel is
    # now; -Dip the size it is about to take, in WPF's units
    param($H, $Dip)
    $t = Get-ChatOverlayControlsTarget $H $Dip
    if (-not $t) { return }
    if ($t.Side -ne $H.CtlSide) { Set-ChatOverlayControlsSide $H $t.Side }
    if ($t.X -ne $t.Now[0] -or $t.Y -ne $t.Now[1]) { [ChatOverlayNative]::MoveTo($H.CtlHwnd, $t.X, $t.Y) }
}

function Get-ChatOverlayControlsZone {
    <#
    Where the pointer counts as on the buttons, in screen pixels: their
    window's rect (-Rect x y width height) - where it is, or while hidden
    where it would go - and the gap between it and the panel on its -Side.
    So the buttons can be reached straight from anywhere, not only by way of
    the panel, and crossing the gap never leaves them. Pure, for the tests.
    #>
    param([int[]]$Rect, [string]$Side, [int]$Gap)
    if (-not $Rect -or $Rect.Count -lt 4) { return $null }
    if ($Side -eq 'below') { return @($Rect[0], ($Rect[1] - $Gap), $Rect[2], ($Rect[3] + $Gap)) }
    return @($Rect[0], $Rect[1], $Rect[2], ($Rect[3] + $Gap))
}

function Get-ChatOverlayControlsHoverZone {
    # the buttons' zone for the pointer check, shown or hidden; $null when
    # there is no controls window to place
    param($H)
    $t = Get-ChatOverlayControlsTarget $H
    if (-not $t) { return $null }
    return Get-ChatOverlayControlsZone @($t.X, $t.Y, $t.Width, $t.Height) $t.Side $t.Gap
}

function Start-ChatOverlayGripDrag {
    # A press on the grip: the panel follows the pointer until it is let go,
    # and the controls follow the panel. The pointer is only read; the
    # windows moved are the overlay's own.
    param($Grip)
    $H = $script:ChatOverlayHost
    if (-not $H) { return }
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    if (-not $r) { return }
    $m = [System.Windows.Forms.Control]::MousePosition
    $H.GripDrag = @{ Mx = $m.X; My = $m.Y; X = $r[0]; Y = $r[1] }
    $H.Dragging = $true
    [void]$Grip.CaptureMouse()
}

function Move-ChatOverlayGripDrag {
    $H = $script:ChatOverlayHost
    if (-not $H -or -not $H.GripDrag) { return }
    $d = $H.GripDrag
    $m = [System.Windows.Forms.Control]::MousePosition
    [ChatOverlayNative]::MoveTo($H.Hwnd, $d.X + $m.X - $d.Mx, $d.Y + $m.Y - $d.My)
    Set-ChatOverlayControlsPlacement $H
}

function Stop-ChatOverlayGripDrag {
    # let go - or the capture lost some other way: where it ended is kept
    param($Grip)
    $H = $script:ChatOverlayHost
    if (-not $H -or -not $H.GripDrag) { return }
    $H.GripDrag = $null
    $H.Dragging = $false
    if ($Grip -and $Grip.IsMouseCaptured) { $Grip.ReleaseMouseCapture() }
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    if ($r) { $H.State.x = $r[0]; $H.State.y = $r[1]; Save-ChatOverlayState $H.State }
    Sync-ChatOverlayHeightCap $H
}

function Get-ChatOverlayResize {
    <#
    What a drag of the resize handle comes to, from where it started: the
    panel's -Width (WPF units) and -Rows then, the pointer's travel since
    (-Dx, -Dy, screen pixels), one row's height (-RowHeight, screen pixels),
    -Scale screen pixels to a WPF unit, and the panel's -Right edge. The
    buttons sit at the panel's top-right, so that edge stays where it is:
    left widens, right narrows, and Left is where the panel's left edge
    goes. Down adds a row for each row's height of travel, up takes one
    away; Steps says how many, 0 while the pointer is still within the
    first. Width 260 to 800, rows 1 to 30. -Collapsed: one line, so width
    only. A row height not known (0) is taken as 36 units, a row with its
    prompt line. -Kept: the row count saved when the drag started, where
    -Rows is the rows drawn - fewer, with fewer chats open. Then no travel
    is Kept, and travel down never comes to less than Kept: counted from
    the rows drawn, one row down had saved 4 over 8 with 3 chats open.
    Pure, for the tests.
    #>
    param([double]$Width, [int]$Rows, [double]$Dx, [double]$Dy, [double]$RowHeight, [double]$Scale = 1, [int]$Right = 0, [switch]$Collapsed, [int]$Kept = 0)
    if ($Scale -le 0) { $Scale = 1 }
    $w = [int][Math]::Max(260, [Math]::Min(800, [Math]::Round($Width - $Dx / $Scale)))
    $rh = if ($RowHeight -gt 0) { $RowHeight } else { 36 * $Scale }
    $steps = if ($Collapsed) { 0 } else { [int][Math]::Truncate($Dy / $rh) }
    $n = [int][Math]::Max(1, [Math]::Min(30, $Rows + $steps))
    if ($Kept -gt 0) {
        if ($steps -eq 0) { $n = $Kept } elseif ($steps -gt 0) { $n = [Math]::Max($Kept, $n) }
    }
    return [pscustomobject]@{ Width = $w; Rows = $n; Steps = $steps; Left = [int]($Right - [Math]::Round($w * $Scale)) }
}

function Get-ChatOverlayScale {
    # this screen's pixels to one of WPF's units, for the panel where it is
    # now: from its rect while it is laid out, else from WPF itself.
    # -Device: WPF's own first. The rect's ratio holds only while the rect
    # and ActualWidth are in step, and mid-drag, just after Width is set,
    # the rect can be ahead - the ratio then off by the width's change.
    param($H, [int[]]$Rect, [switch]$Device)
    $wpf = {
        try {
            $src = [System.Windows.PresentationSource]::FromVisual($H.Win)
            if ($src -and $src.CompositionTarget) { return [double]$src.CompositionTarget.TransformToDevice.M11 }
        }
        catch {}
        return $null
    }
    if ($Device) { $m = & $wpf; if ($m) { return $m } }
    if ($Rect -and $H.Win.ActualWidth -gt 0) { return $Rect[2] / [double]$H.Win.ActualWidth }
    $m = & $wpf
    if ($m) { return $m }
    return 1.0
}

function Get-ChatOverlayRowHeight {
    # one drawn row's height, margins in, in WPF units - their average, as a
    # row with a prompt line is taller than one without; 0 when none is drawn
    param($H)
    $hs = @(@($H.Stack.Children) | Where-Object { (Test-ChatOverlayOpenRowElement $_) -and $_.ActualHeight -gt 0 } |
            ForEach-Object { $_.ActualHeight + $_.Margin.Top + $_.Margin.Bottom })
    if (-not $hs.Count) { return 0 }
    return (($hs | Measure-Object -Average).Average)
}

function Test-ChatOverlayOpenRowElement {
    # an element of the panel that draws one of the rows maxRows counts: a
    # row's wrapper, tagged with its row - not a Recent line, nor the
    # banner about the chats the limit cut off, which are tagged the same
    # way for the chip but are no rows of those
    param($El)
    return [bool]($El.Tag -and $El.Tag -isnot [string] -and [string](Get-ChatField $El.Tag 'kind') -notin 'recent', 'ask')
}

function Get-ChatOverlayDrawnRows {
    # how many chat rows the panel draws now
    param($H)
    return @(@($H.Stack.Children) | Where-Object { Test-ChatOverlayOpenRowElement $_ }).Count
}

function Get-ChatOverlayHeightCap {
    <#
    The panel's MaxHeight in WPF units: from its top edge (-Top, screen
    pixels) down to the bottom of its screen's working area (-Area, screen
    pixels), at -Scale pixels a unit. The whole area's height let a panel
    half way down the screen run off its foot, the rows under the edge
    never counted on the "+N more" line. Never under -Floor, about one row:
    a panel dragged to the screen's foot, or below it, still draws a row -
    clipped, where the screen is shorter still. Pure, for the tests.
    #>
    param([int]$Top, $Area, [double]$Scale = 1, [double]$Floor = 0)
    if ($Scale -le 0) { $Scale = 1 }
    $room = [Math]::Floor(([double]$Area.Y + [double]$Area.Height - $Top) / $Scale)
    return [double][Math]::Max([Math]::Ceiling($Floor), $room)
}

function Update-ChatOverlayMaxHeight {
    # Never past the foot of the working area of the screen it is on, from
    # where its top edge is now (Get-ChatOverlayHeightCap): a row count or a
    # drag that asks for more is cut to what fits, and Update-ChatOverlayView
    # says how many more there are. The scale is WPF's own (-Device): this
    # runs mid-drag, just after Width is set. The floor is one row as last
    # drawn - 36 units, a row with its prompt line, before any is - with the
    # frame's padding and edge.
    param($H)
    # the console's mode is sized by hand: no cap on it
    if (-not $H.Win -or $H.Hwnd -eq [IntPtr]::Zero -or $H.Mode -eq 'console') { return }
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    if (-not $r) { return }
    $a = if ($script:ChatOverlayWorkAreaSeam) { & $script:ChatOverlayWorkAreaSeam $r }
    else { [System.Windows.Forms.Screen]::FromRectangle([System.Drawing.Rectangle]::new($r[0], $r[1], [Math]::Max(1, $r[2]), [Math]::Max(1, $r[3]))).WorkingArea }
    $row = Get-ChatOverlayRowHeight $H
    if ($row -le 0) { $row = 36 }
    $f = $H.Frame
    $chrome = if ($f) { $f.Padding.Top + $f.Padding.Bottom + $f.BorderThickness.Top + $f.BorderThickness.Bottom } else { 0 }
    $max = Get-ChatOverlayHeightCap $r[1] $a (Get-ChatOverlayScale $H $r -Device) ($row + $chrome)
    if ($max -gt 0 -and $H.Win.MaxHeight -ne $max) { $H.Win.MaxHeight = $max }
}

function Sync-ChatOverlayHeightCap {
    # The panel moved - a drag let go, or placed: its height cap goes by its
    # top edge, so it is worked out again now, and the rows drawn to it, not
    # at the next pass.
    param($H)
    if (-not $H -or -not $H.Win) { return }
    if ($H.Snap) { Update-ChatOverlayView $H $H.Snap } else { Update-ChatOverlayMaxHeight $H }
}

function Get-ChatOverlayWorkArea {
    # the working area of the screen a rect from GetRect is on, in pixels -
    # or the tests' own screen
    param([int[]]$Rect)
    if ($script:ChatOverlayWorkAreaSeam) { return (& $script:ChatOverlayWorkAreaSeam $Rect) }
    return [System.Windows.Forms.Screen]::FromRectangle([System.Drawing.Rectangle]::new($Rect[0], $Rect[1], [Math]::Max(1, $Rect[2]), [Math]::Max(1, $Rect[3]))).WorkingArea
}

function Set-ChatOverlayWidth {
    <#
    The panel this wide (WPF units, 260 to 800), its right edge held where
    it is - or at -Right, screen pixels - since the buttons sit at its
    top-right, and the settings box above them. Its left edge never goes
    past the left of its screen's working area: held there, it grows to the
    right instead. Where it ends up is not saved: the caller says when
    (Stop-ChatOverlaySizeDrag, the slider once it rests, a reload).
    #>
    param($H, [double]$Width, $Right = $null)
    if (-not $H -or -not $H.Win) { return }
    $v = [int][Math]::Max(260, [Math]::Min(800, [Math]::Round($Width)))
    if ($H.Win.Width -eq $v) { return }
    $r = if ($H.Hwnd -ne [IntPtr]::Zero) { [ChatOverlayNative]::GetRect($H.Hwnd) } else { $null }
    $px = Get-ChatOverlayScale $H $r
    $H.Win.Width = $v
    if (-not $r) { return }
    $edge = if ($null -ne $Right) { [int]$Right } else { $r[0] + $r[2] }
    # WPF sizes the window as Width is set; should it not have yet, what it
    # is about to be
    $now = [ChatOverlayNative]::GetRect($H.Hwnd)
    $wide = if ($now -and $now[2] -ne $r[2]) { $now[2] } else { [int][Math]::Round($v * $px) }
    $top = if ($now) { $now[1] } else { $r[1] }
    $a = if ($script:ChatOverlayWorkAreaSeam) { & $script:ChatOverlayWorkAreaSeam $r }
    else { [System.Windows.Forms.Screen]::FromRectangle([System.Drawing.Rectangle]::new($r[0], $r[1], [Math]::Max(1, $r[2]), [Math]::Max(1, $r[3]))).WorkingArea }
    [ChatOverlayNative]::MoveTo($H.Hwnd, [Math]::Max([int]$a.X, $edge - $wide), $top)
}

function Save-ChatOverlayPlace {
    # where the panel is now, kept in overlay-state.json for the next start;
    # not before it was first placed, while it waits off every screen
    param($H)
    if (-not $H -or -not $H.State -or -not $H.Placed -or -not $H.Hwnd -or $H.Hwnd -eq [IntPtr]::Zero) { return }
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    if ($r) { $H.State.x = $r[0]; $H.State.y = $r[1]; Save-ChatOverlayState $H.State }
}

function Set-ChatOverlayRowCount {
    # at most this many rows, drawn now; not saved - the caller says when
    param($H, [int]$Rows)
    $n = [Math]::Max(1, [Math]::Min(30, $Rows))
    if ($H.Ctx.Config.maxRows -eq $n) { return }
    $H.Ctx.Config.maxRows = $n
    $H.ViewKey = $null
    if ($H.Snap) { Update-ChatOverlayView $H $H.Snap }
}

function Set-ChatOverlayWidthChoice {
    # the width slider, as it moves; config.json gets it once it rests
    param($H, [double]$Value)
    if (-not $H) { return }
    $v = [int][Math]::Round($Value)
    Set-ChatOverlayWidth $H $v
    if ($H.WidthText) { $H.WidthText.Text = "$v" }
    $H.PendingWidth = $v
    $H.PendingAt = Get-Date
    Set-ChatOverlayControlsPlacement $H
}

function Set-ChatOverlayRowsChoice {
    # the rows slider, as it moves; config.json gets it once it rests
    param($H, [double]$Value)
    if (-not $H) { return }
    $v = [int][Math]::Round($Value)
    Set-ChatOverlayRowCount $H $v
    if ($H.RowsText) { $H.RowsText.Text = "$v" }
    $H.PendingRows = $v
    $H.PendingAt = Get-Date
}

function Start-ChatOverlaySizeDrag {
    # A press on the resize handle: the panel's width and rows follow the
    # pointer until it is let go (Get-ChatOverlayResize). The pointer is
    # only read - or -At, for the tests; the window resized is the overlay's
    # own. The pass waits meanwhile, as for the grip, and the chip too.
    param($Handle, $At = $null)
    $H = $script:ChatOverlayHost
    if (-not $H -or $H.GripDrag) { return }
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    if (-not $r) { return }
    $m = if ($At) { $At } else { [System.Windows.Forms.Control]::MousePosition }
    $px = Get-ChatOverlayScale $H $r
    $rows = [int]$H.Ctx.Config.maxRows
    # From the rows drawn when there are fewer than that - fewer chats, or
    # the screen's height - so the first row's travel up takes one away
    # rather than going on rows nobody sees.
    $drawn = Get-ChatOverlayDrawnRows $H
    $from = if ($drawn -gt 0 -and $drawn -lt $rows) { $drawn } else { $rows }
    $H.SizeDrag = @{ Mx = $m.X; My = $m.Y; Right = $r[0] + $r[2]; Width = [double]$H.Win.Width; Rows = $from; Kept = $rows
        WasWidth = [int]$H.Ctx.Config.width; RowPx = (Get-ChatOverlayRowHeight $H) * $px; Px = $px }
    $H.Dragging = $true
    Hide-ChatOverlayChip $H
    if ($Handle) { [void]$Handle.CaptureMouse() }
}

function Move-ChatOverlaySizeDrag {
    param($At = $null)
    $H = $script:ChatOverlayHost
    if (-not $H -or -not $H.SizeDrag) { return }
    $d = $H.SizeDrag
    $m = if ($At) { $At } else { [System.Windows.Forms.Control]::MousePosition }
    # back within the first row's travel, the count it had, not the one the
    # drag started from; down, never fewer than that
    $z = Get-ChatOverlayResize $d.Width $d.Rows ($m.X - $d.Mx) ($m.Y - $d.My) $d.RowPx $d.Px $d.Right -Collapsed:([bool]$H.Collapsed) -Kept $d.Kept
    Set-ChatOverlayWidth $H $z.Width $d.Right
    Set-ChatOverlayRowCount $H $z.Rows
    Set-ChatOverlayControlsPlacement $H
}

function Stop-ChatOverlaySizeDrag {
    # let go - or the capture lost some other way: the size is kept in
    # config.json, where the panel is in overlay-state.json
    param($Handle)
    $H = $script:ChatOverlayHost
    if (-not $H -or -not $H.SizeDrag) { return }
    $d = $H.SizeDrag
    $H.SizeDrag = $null
    $H.Dragging = $false
    if ($Handle -and $Handle.IsMouseCaptured) { $Handle.ReleaseMouseCapture() }
    $set = @{}
    if ([int]$H.Win.Width -ne $d.WasWidth) { $set.width = [int]$H.Win.Width }
    if ([int]$H.Ctx.Config.maxRows -ne $d.Kept) { $set.maxRows = [int]$H.Ctx.Config.maxRows }
    if ($set.Count) { Save-ChatOverlaySetting $H $set }
    Save-ChatOverlayPlace $H
    # an open settings box's sliders to what was dragged to; a shut one's
    # as it opens
    if ($H.SettingsOpen) { Sync-ChatOverlaySettings $H }
    Set-ChatOverlayControlsPlacement $H
}

function Set-ChatOverlayCollapsed {
    # one line - what is running, and usage - or the whole panel; kept for
    # the next start in overlay-state.json
    param($H, [bool]$Collapsed)
    $H.Collapsed = $Collapsed
    Hide-ChatOverlayChip $H
    Set-ChatqProp $H.State 'collapsed' $Collapsed
    Save-ChatOverlayState $H.State
    $H.ViewKey = $null
    if ($H.Snap) { Update-ChatOverlayView $H $H.Snap }
    # the chevron turns
    if ($H.CtlWin) { New-ChatOverlayControls $H }
    Update-ChatOverlayMenu $H
}

function Set-ChatOverlayOpacity {
    # as the slider moves; config.json gets it once the slider rests
    param($H, [double]$Value)
    if (-not $H) { return }
    $v = [Math]::Round([Math]::Max(0.3, [Math]::Min(1.0, $Value)), 2)
    $H.Win.Opacity = $v
    if ($H.OpacityText) { $H.OpacityText.Text = "$([int][Math]::Round($v * 100))%" }
    $H.PendingOpacity = $v
    $H.PendingAt = Get-Date
}

function Get-ChatOverlayPending {
    # What the sliders moved to and config.json has not got yet, taken:
    # @{ opacity; width; maxRows }, only those moved. A width moved the
    # panel's left edge too, so where it is now is kept with it - or the
    # next start put it back where it was, as wide as it is now, and a
    # panel near the right of the screen ran off it. Not while the window
    # is the console: its rect is the console's then, and the panel's place
    # is kept as it comes back (Exit-ChatOverlayConsoleMode).
    param($H)
    $v = @{}
    if ($null -ne $H.PendingOpacity) { $v.opacity = $H.PendingOpacity }
    if ($null -ne $H.PendingWidth) { $v.width = [int]$H.PendingWidth; if ($H.Mode -ne 'console') { Save-ChatOverlayPlace $H } }
    if ($null -ne $H.PendingRows) { $v.maxRows = [int]$H.PendingRows }
    $H.PendingOpacity = $null
    $H.PendingWidth = $null
    $H.PendingRows = $null
    return $v
}

function Save-ChatOverlaySetting {
    # A choice made in the settings box, kept in config.json like one made
    # with chatoverlay, so the next start has it. A slider not yet at rest
    # goes with it: the config read back after would otherwise take the
    # panel back to what it had before the slider moved.
    param($H, [hashtable]$Values)
    try {
        $all = Get-ChatOverlayPending $H
        foreach ($k in $Values.Keys) { $all[$k] = $Values[$k] }
        Set-ChatOverlayConfig $all
        $H.Ctx.Config = Get-ChatOverlayConfig
    }
    catch { Write-ChatOverlayLog "settings: $($_.Exception.Message)" }
}

function Set-ChatOverlayThemeChoice {
    param($H, [string]$Theme)
    if (-not $H -or $H.Ctx.Config.theme -eq $Theme) { return }
    Save-ChatOverlaySetting $H @{ theme = $Theme }
    # made anew even when the look stays the same, so the choice shows
    $H.ThemeName = $null
    Update-ChatOverlayTheme $H
}

function Set-ChatOverlayUsageView {
    # lines or bars, from the settings box: kept in config.json, drawn now
    param($H, [string]$View)
    if (-not $H -or $H.Ctx.Config.usageView -eq $View) { return }
    Save-ChatOverlaySetting $H @{ usageView = $View }
    New-ChatOverlayControls $H
    $H.ViewKey = $null
    if ($H.Snap) { Update-ChatOverlayView $H $H.Snap }
}

function Set-ChatOverlayRowStyle {
    # full or compact rows, from the settings box: compact is the prompt
    # line off, kept in config.json as prompts. The view key carries it, so
    # the pass below draws the rows anew.
    param($H, [string]$Style)
    $prompts = $Style -ne 'compact'
    if (-not $H -or [bool]$H.Ctx.Config.prompts -eq $prompts) { return }
    Save-ChatOverlaySetting $H @{ prompts = $prompts }
    New-ChatOverlayControls $H
    if ($H.Snap) { Update-ChatOverlayView $H $H.Snap }
}

function Set-ChatOverlayRecentChoice {
    # off, 5 or 10 recent chats, from the settings box: kept in config.json,
    # and the list built afresh by the next pass, two seconds on - building
    # it lists every project's transcripts, which is the collector's to do
    param($H, [string]$Choice)
    $n = if ($Choice -eq 'off') { 0 } else { [int]$Choice }
    if (-not $H -or [int]$H.Ctx.Config.recent -eq $n) { return }
    Save-ChatOverlaySetting $H @{ recent = $n }
    $H.Ctx.RecentSig = $null
    New-ChatOverlayControls $H
}

function Set-ChatOverlayAutoChoice {
    # Continue, Ask or Leave for the chats the limit cut off, from the
    # settings box - and the tray's item, through Invoke-ChatOverlayVerb. It
    # is config.json's top-level autoContinue, not one of the overlay's own
    # settings, so Set-ChatqAutoContinue writes it; Continue is its on and
    # Leave its off. The config is read back with a slider not yet at rest,
    # and the next pass takes a fresh look at what was cut off. Continue
    # chosen for the first time says once, in the tray, what it does.
    param($H, [string]$Choice)
    if (-not $H) { return }
    $v = switch ($Choice) { 'leave' { 'off' } 'continue' { 'on' } default { 'ask' } }
    if ([string]$H.Ctx.Config.autoContinue -eq $v) { return }
    try {
        [void](Set-ChatqAutoContinue -Value $v)
        Save-ChatOverlaySetting $H @{}
        $H.Ctx.CutAt = [datetime]::MinValue
        Write-ChatOverlayLog "auto-continue $v from the panel" -Always
        if ($H.CtlStack) { New-ChatOverlayControls $H }
        $H.ViewKey = $null
        if ($H.Menu) { Update-ChatOverlayMenu $H }
        if ($v -eq 'on') { Show-ChatOverlayAutoNotice $H }
    }
    catch { Write-ChatOverlayLog "settings: $($_.Exception.Message)" }
}

function Invoke-ChatOverlayRefresh {
    # the refresh button: a pass now, which sends the ask; the next pass,
    # two seconds on, draws the answer
    $H = $script:ChatOverlayHost
    if (-not $H -or $H.Dragging) { return }
    Request-ChatOverlayUsageRefresh $H.Ctx
    $H.ViewKey = $null
    Update-ChatOverlayView $H (Invoke-ChatOverlayCycle $H.Ctx -Peek)
    Update-ChatOverlaySpin $H
}

function Update-ChatOverlaySpin {
    # Every pointer check: the refresh icon turns while an ask is out, and an
    # answer that is in is drawn now - a pass would pick it up only up to 2 s
    # on, long enough for a click to look like it did nothing.
    param($H)
    $ready = { param($f) $f -and ($f.Done -or ($f.Task -and $f.Task.IsCompleted) -or ($f.Proc -and $f.Proc.HasExited)) }
    if (((& $ready $H.Ctx.Fetch) -or (& $ready $H.Ctx.CopilotFetch)) -and -not $H.Dragging) {
        Update-ChatOverlayView $H (Invoke-ChatOverlayCycle $H.Ctx -Peek)
    }
    $out = [bool]($H.Ctx.Fetch -or $H.Ctx.CopilotFetch)
    if (-not $H.Spin -or $out -eq $H.Spinning) { return }
    $H.Spinning = $out
    $prop = [System.Windows.Media.RotateTransform]::AngleProperty
    if ($out) {
        $a = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 360, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(900)))
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $H.Spin.BeginAnimation($prop, $a)
    }
    else { $H.Spin.BeginAnimation($prop, $null) }
}

function Hide-ChatOverlayByButton {
    # the tray button hides the panel, and says once where it went
    $H = $script:ChatOverlayHost
    if (-not $H) { return }
    Invoke-ChatOverlayVerb 'hide'
    if ($H.Tray -and -not $H.HideTold) {
        $H.HideTold = $true
        $key = if ($H.Hotkey) { " or press $($H.HotkeyText)" } else { '' }
        Show-ChatOverlayBalloon $H "Hidden. Click the tray dot$key to show it again."
    }
}

function Show-ChatOverlayBalloon {
    <#
    The tray's balloon - the one place that shows one. -Kind says what a
    click on it means (ask: the chats the limit cut off, -Keys those asked
    about); the tray's handlers read it back, and clear it as it closes.
    Windows cuts the text itself past 255 characters, so it is cut here
    first, with an ellipsis. The tests' seam takes it in the tray's place.
    #>
    param($H, [string]$Text, [string]$Title = 'chatoverlay', [int]$Ms = 6000, [string]$Icon = 'None', [string]$Kind = '', [string[]]$Keys = @())
    if (-not $H -or -not $Text) { return }
    if ($Text.Length -gt 250) { $Text = $Text.Substring(0, 249) + $script:ChatqEllipsis }
    $ks = @($Keys | Where-Object { $_ })
    if ($script:ChatOverlayBalloonSeam) {
        $H.BalloonKind = $Kind
        $H.BalloonKeys = $ks
        [void](& $script:ChatOverlayBalloonSeam @{ Title = $Title; Text = $Text; Kind = $Kind; Keys = $ks })
        return
    }
    if (-not $H.Tray) { return }
    $H.BalloonKind = $Kind
    $H.BalloonKeys = $ks
    $H.Tray.ShowBalloonTip($Ms, $Title, $Text, [System.Windows.Forms.ToolTipIcon]$Icon)
}

function Get-ChatOverlayControlsShown {
    <#
    Whether the buttons show, from where the pointer is. Not on first
    contact: a pointer crossing the click-through panel, or the spot above
    it where the buttons go, on its way to the window under it would meet
    buttons that take its click. It rests on either 350 ms first - so the
    buttons can be pointed at straight away, and come up under the pointer.
    Never while a mouse button is held: a tab or a file dragged across that
    corner in the app below would be dropped on them. Once up they stay
    while the pointer is on the panel or on them, while a mouse button is
    held (a slider dragged off the box), mid-drag, and 700 ms after it
    leaves. Pure, for the tests.
    #>
    param([bool]$Shown, [bool]$OnPanel, [bool]$OnControls, [bool]$Dragging, [bool]$Down, [double]$RestedMs, [double]$SinceOverMs)
    if ($Dragging) { return $true }
    if (-not $Shown) { return ((-not $Down) -and ($OnPanel -or $OnControls) -and $RestedMs -ge 350) }
    return ($OnPanel -or $OnControls -or $Down -or $SinceOverMs -lt 700)
}

function Test-ChatOverlayPointerIn {
    # a point, in screen pixels, inside a window's rect from GetRect
    param($At, $Rect)
    return [bool]($Rect -and $At.X -ge $Rect[0] -and $At.X -lt ($Rect[0] + $Rect[2]) -and $At.Y -ge $Rect[1] -and $At.Y -lt ($Rect[1] + $Rect[3]))
}

function Update-ChatOverlayHover {
    <#
    Every 120 ms: where the pointer is - read, never moved - against the
    panel and the controls' zone: their window and the gap to the panel, or
    while hidden the spot they would take. Resting on either brings the
    controls, which stay a moment after it leaves; while a button is held
    they stay, so a slider dragged off the box keeps going. The controls
    follow a panel moved some other way, and what the settings box's
    sliders settled on is saved here too.
    #>
    $H = $script:ChatOverlayHost
    # the console's mode has neither the buttons nor the chip
    if (-not $H -or $H.ShuttingDown -or $H.Hidden -or $H.Mode -eq 'console' -or $H.Hwnd -eq [IntPtr]::Zero) { return }
    try {
        $m = [System.Windows.Forms.Control]::MousePosition
        $down = [System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None
        $onPanel = Test-ChatOverlayPointerIn $m ([ChatOverlayNative]::GetRect($H.Hwnd))
        $onCtl = Test-ChatOverlayPointerIn $m (Get-ChatOverlayControlsHoverZone $H)
        $now = Get-Date
        # a rest with a button held is a drag in the app below; it starts over
        # once the button is let go
        if (-not ($onPanel -or $onCtl) -or ($down -and -not $H.ControlsShown)) { $H.EnterAt = $null }
        elseif (-not $H.EnterAt) { $H.EnterAt = $now }
        if ($onPanel -or $onCtl) { $H.OverAt = $now }
        $rested = if ($H.EnterAt) { ($now - $H.EnterAt).TotalMilliseconds } else { 0 }
        $since = if ($H.OverAt) { ($now - $H.OverAt).TotalMilliseconds } else { [double]::MaxValue }
        $show = Get-ChatOverlayControlsShown ([bool]$H.ControlsShown) $onPanel $onCtl ([bool]$H.Dragging) $down $rested $since
        if ($show -ne [bool]$H.ControlsShown) { Show-ChatOverlayControls $H $show }
        # the grip's own drag places them as it goes; the unlocked panel's
        # DragMove does not
        elseif ($show -and -not $H.GripDrag -and -not $H.SizeDrag) { Set-ChatOverlayControlsPlacement $H }
        # the sliders, once at rest: opacity, width and rows in one write -
        # rows whatever they are, as the panel's config holds them live
        $pending = $null -ne $H.PendingOpacity -or $null -ne $H.PendingWidth -or $null -ne $H.PendingRows
        if ($pending -and -not $down -and ($now - $H.PendingAt).TotalMilliseconds -ge 700) {
            $v = Get-ChatOverlayPending $H
            if ($v.ContainsKey('opacity') -and $v.opacity -eq $H.Ctx.Config.opacity) { $v.Remove('opacity') }
            if ($v.ContainsKey('width') -and $v.width -eq $H.Ctx.Config.width) { $v.Remove('width') }
            if ($v.Count) { Save-ChatOverlaySetting $H $v }
        }
        Update-ChatOverlaySpin $H
        Update-ChatOverlayChip $H $m $down $now $onPanel
    }
    catch { Write-ChatOverlayLog "hover: $($_.Exception.Message)" }
}

function Test-ChatOverlayRowOpenable {
    # a row the open chip can show: a Claude chat, by its id, in a folder
    # its window can be found by. Pure.
    param($Row)
    if (-not $Row) { return $false }
    return ([string](Get-ChatField $Row 'provider') -eq 'claude' -and
        [string](Get-ChatField $Row 'sessionId') -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -and
        [bool][string](Get-ChatField $Row 'cwd'))
}

function Get-ChatOverlayChipActions {
    <#
    What the chip offers for a row, left to right, each an Id, a Label and
    a Tip: the banner about the chats the limit cut off its two answers;
    a cut-off row auto-continue's chip by its state (the row's auto,
    src/auto-continue.ps1) - don't continue on a continue that waits,
    continue on a cut-off nothing will continue, none on one running, held
    by a terminal or cut off by a 529 - then open, where the row can be
    opened. A cut-off row with no folder still gets its auto chip. Anything
    else nothing, and gets no chip. The auto chips' tooltips carry what the
    row says in full, since the chips may cover it. Pure.
    #>
    param($Row)
    if (-not $Row) { return @() }
    if ([string](Get-ChatField $Row 'kind') -eq 'ask') {
        $n = [int](Get-ChatField $Row 'count')
        $titles = @(Get-ChatField $Row 'titles') | Where-Object { $_ }
        return @(
            [pscustomobject]@{ Id = 'ask-go'; Label = "continue $n"; Tip = "Queue ""Continue from where you left off."" for each of the $n chats the limit cut off: $(@($titles) -join ', ')" }
            [pscustomobject]@{ Id = 'ask-leave'; Label = 'leave them'; Tip = 'Leave them as they are - their rows stay orange; Continue all in the console still continues them' }
        )
    }
    $out = @()
    $a = Get-ChatField $Row 'auto'
    $st = if ($a) { [string](Get-ChatField $a 'state') } else { '' }
    $long = if ($a) { [string](Get-ChatField $a 'long') } else { '' }
    $title = Format-ChatqAutoTitle ([string](Get-ChatField $Row 'title')) 40
    if ($st -in 'armed', 'due') {
        $out += [pscustomobject]@{ Id = 'dont'; Label = "don't continue"
            Tip = "$(if ($long) { "$long. " })Don't send ""continue"" to this chat after this reset. The next time the limit cuts it off, it is continued again - chatq '$title' -AutoContinue never stops that."
        }
    }
    elseif ($st -in 'off', 'never', 'declined', 'failed', 'stopped', 'far', 'late', 'ready') {
        $out += [pscustomobject]@{ Id = 'continue'; Label = 'continue'
            Tip = "$(if ($long) { "$long. " })Queue ""Continue from where you left off."" for this chat - it goes when the limit is over."
        }
    }
    if (Test-ChatOverlayRowOpenable $Row) {
        $out += [pscustomobject]@{ Id = 'open'; Label = 'open'; Tip = 'Open this chat as a tab in its VS Code window - or bring forward the tab already showing it.' }
    }
    return $out
}

function Get-ChatOverlayChipSig {
    # the chip's actions as one string, to tell whether its face changed -
    # the tooltips too: another row's don't continue says another state
    param([object[]]$Actions)
    return (@($Actions | Where-Object { $_ } | ForEach-Object { "$($_.Id)=$($_.Label)=$($_.Tip)" }) -join '|')
}

function Invoke-ChatOverlayChipRelease {
    # A release on chip -On after a press on -Pressed: acts only when they
    # are the same chip, so a press dragged from one onto another does
    # nothing. open goes as before; the banner's two answers through
    # Invoke-ChatOverlayAskAnswer, about the keys its row carries;
    # auto-continue's two through Invoke-ChatOverlayAutoChip, which never
    # takes the unread dot away (only an open does).
    param($H, [string]$Pressed, [string]$On)
    if (-not $Pressed -or $Pressed -ne $On) { return }
    switch ($On) {
        'open' { Invoke-ChatOverlayOpen $H $H.ChipRow }
        'ask-go' { Invoke-ChatOverlayAskAnswer $H 'continue' @(Get-ChatField $H.ChipRow 'keys') }
        'ask-leave' { Invoke-ChatOverlayAskAnswer $H 'leave' @(Get-ChatField $H.ChipRow 'keys') }
        { $_ -in 'dont', 'continue' } { Invoke-ChatOverlayAutoChip $H $H.ChipRow $On }
    }
}

function Get-ChatOverlayChipTarget {
    <#
    Which row the open chip shows for, from the pointer: '' for none. Not on
    first contact - a pointer crossing the click-through panel on its way to
    what is under it would find a chip in its path - but after it rested on a
    row -DelayMs from moving onto it (-RestedMs), with no button held, and
    once per visit to a row (-Spent: the row it last showed for, until the
    pointer leaves it). The delay is config overlay.chipDelayMs, 400 ms
    unless set: 1 s felt slow, and a crossing pointer rarely rests even
    that long on one row. Shown, it stays while the pointer is on it or its
    row, and 300 ms after, so crossing to it loses nothing; another row
    hides it at once. -Blocked: collapsed or mid-drag. Pure, for the tests.
    #>
    param([string]$Shown, [string]$Under, [double]$RestedMs, [bool]$OnChip, [double]$SinceOverMs,
        [bool]$Down, [bool]$Blocked, [string]$Spent, [double]$DelayMs = 400)
    if ($Blocked) { return '' }
    if ($Shown) {
        if ($OnChip -or $Under -eq $Shown) { return $Shown }
        if ($Under) { return '' }
        if ($SinceOverMs -lt 300) { return $Shown }
        return ''
    }
    if ($Under -and $Under -ne $Spent -and -not $Down -and $RestedMs -ge $DelayMs) { return $Under }
    return ''
}

function Step-ChatOverlayChipState {
    <#
    One pointer check's bookkeeping for the chip, on $S (the host state, or
    any hashtable with its Chip* keys): the row under the pointer and since
    when it rested there, the last time it was over the chip or its row, the
    row a chip already showed for, and whether a click on the chip counts.
    The rest starts only when the pointer moves onto a row: rows redrawn
    under a pointer that sits still start nothing. A click counts only once
    the pointer has been seen off the chip since it appeared, so a pointer
    parked where the chip comes up never opens anything with its next click.
    Pure but for $S.
    #>
    param($S, [string]$Under, [string]$Pos, [bool]$OnChip, [datetime]$Now)
    $moved = $Pos -ne [string]$S.ChipLastPos
    if ($Under -ne [string]$S.ChipUnder) {
        $S.ChipUnder = $Under
        $S.ChipUnderAt = if ($Under -and $moved) { $Now } else { $null }
    }
    elseif ($Under -and -not $S.ChipUnderAt -and $moved) { $S.ChipUnderAt = $Now }
    $S.ChipLastPos = $Pos
    if ($S.ChipKey -and ($OnChip -or $Under -eq $S.ChipKey)) { $S.ChipOverAt = $Now }
    if ($S.ChipSpent -and $Under -ne $S.ChipSpent) { $S.ChipSpent = $null }
    if ($S.ChipKey -and -not $OnChip) { $S.ChipArmed = $true }
}

function Get-ChatOverlayRowRects {
    # Each drawn row's rect, and its first line's, in screen pixels: what the
    # pointer is matched against. Only while the pointer is on the panel or
    # the chip; a row not laid out yet is left out.
    param($H)
    $out = [System.Collections.Generic.List[object]]::new()
    if (-not $H.Stack) { return $out.ToArray() }
    foreach ($w in @($H.Stack.Children)) {
        $row = $w.Tag
        if (-not $row -or $row -is [string] -or -not (Get-ChatField $row 'key')) { continue }
        try {
            $line = @($w.Children | Where-Object { $_.Tag -eq 'line' }) | Select-Object -First 1
            if (-not $line) { $line = $w }
            $rect = {
                param($el)
                $a = $el.PointToScreen([System.Windows.Point]::new(0, 0))
                $b = $el.PointToScreen([System.Windows.Point]::new($el.ActualWidth, $el.ActualHeight))
                @([int][Math]::Round($a.X), [int][Math]::Round($a.Y), [int][Math]::Round($b.X - $a.X), [int][Math]::Round($b.Y - $a.Y))
            }
            # the state at the line's right end, which an auto chip keeps clear of
            $sEl = if ($line -ne $w) { @($line.Children | Where-Object { $_.Tag -eq 'state' }) | Select-Object -First 1 } else { $null }
            $out.Add([pscustomobject]@{ Key = [string]$row.key; Row = $row; Rect = (& $rect $w); Line = (& $rect $line); State = $(if ($sEl) { & $rect $sEl } else { $null }) })
        }
        catch {}
    }
    return $out.ToArray()
}

function Find-ChatOverlayRowAt {
    # the row whose rect holds the point, or $null. Pure.
    param($At, [object[]]$Rects)
    foreach ($r in @($Rects)) { if ($r -and (Test-ChatOverlayPointerIn $At $r.Rect)) { return $r } }
    return $null
}

function Get-ChatOverlayChipPlacement {
    # The chip flush with its row's right end, centred on the row's first
    # line, kept on the screen; all in screen pixels (-Line a rect, -Size
    # width and height). -Reserve: pixels kept clear at the row's right end
    # - the state an auto-continue chip is about, which it must not cover -
    # though never so many that the chip leaves its row. Pure, for the tests.
    param([int[]]$Line, [int[]]$Size, $Screen, [int]$Reserve = 0)
    $x = [Math]::Max($Line[0], $Line[0] + $Line[2] - $Reserve - $Size[0])
    $y = $Line[1] + [int][Math]::Round(($Line[3] - $Size[1]) / 2.0)
    $x = [Math]::Max($Screen.X, [Math]::Min($x, $Screen.X + $Screen.Width - $Size[0]))
    $y = [Math]::Max($Screen.Y, [Math]::Min($y, $Screen.Y + $Screen.Height - $Size[1]))
    return [pscustomobject]@{ X = [int]$x; Y = [int]$y }
}

function New-ChatOverlayChipWindow {
    <#
    The open chip: a small window of its own, like the controls', over the
    right end of the row the pointer rests on. The panel stays click-through
    everywhere else. Never takes focus, and is in neither Alt+Tab nor the
    taskbar - the controls window's styles.
    #>
    param($H)
    $c = [System.Windows.Window]::new()
    $c.Title = 'chatoverlay open'
    $c.WindowStyle = [System.Windows.WindowStyle]::None
    $c.AllowsTransparency = $true
    $c.Background = [System.Windows.Media.Brushes]::Transparent
    $c.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $c.Topmost = $true
    $c.ShowActivated = $false
    # true for the same reason as the panel's: false means a hidden owner
    # that is not topmost
    $c.ShowInTaskbar = $true
    $c.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $c.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $c.Left = -32000
    $c.Top = -32000
    $c.FontFamily = $H.Win.FontFamily
    $c.FontSize = 12
    $H.ChipWin = $c
    New-ChatOverlayChipContent $H
    $H.ChipHwnd = [System.Windows.Interop.WindowInteropHelper]::new($c).EnsureHandle()
    [ChatOverlayNative]::ApplyExStyle($H.ChipHwnd, $false)
}

function New-ChatOverlayChipContent {
    # The chip's face: one bordered chip for each of its row's actions
    # ($H.ChipActions, Get-ChatOverlayChipActions), side by side. Made anew
    # when the look changes, and when the row's actions do - the banner's
    # count can change under a pointer at rest.
    param($H)
    $row = [System.Windows.Controls.StackPanel]::new()
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $H.ChipText = $null
    $first = $true
    foreach ($a in @($H.ChipActions | Where-Object { $_ })) {
        $b = [System.Windows.Controls.Border]::new()
        $b.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $b.Background = Get-ChatOverlayBrush 'panel'
        $b.BorderBrush = Get-ChatOverlayBrush 'edge'
        $b.BorderThickness = [System.Windows.Thickness]::new(1)
        $b.Padding = [System.Windows.Thickness]::new(7, 1, 7, 2)
        if (-not $first) { $b.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0) }
        $first = $false
        $b.ToolTip = [string]$a.Tip
        $b.Tag = [string]$a.Id
        # an open still running says so on its chip
        $busy = $a.Id -eq 'open' -and [bool]$H.OpenProc
        $t = New-ChatOverlayText $(if ($busy) { 'opening' } else { [string]$a.Label }) $(if ($busy) { 'dim' } else { 'text' }) 11
        $b.Child = $t
        if ($a.Id -eq 'open') { $H.ChipText = $t }
        $b.add_MouseEnter({ param($s, $e) $s.Background = Get-ChatOverlayBrush 'hover' })
        $b.add_MouseLeave({ param($s, $e) $s.Background = Get-ChatOverlayBrush 'panel' })
        # A press counts only once the chip is armed (Step-ChatOverlayChipState),
        # and only on the chip it was let go on: pressed on one and let go on
        # another, nothing happens.
        $b.add_MouseLeftButtonDown({
                param($s, $e)
                $e.Handled = $true
                $X = $script:ChatOverlayHost
                $X.ChipPressed = [bool]$X.ChipArmed
                $X.ChipPressedId = if ($X.ChipPressed) { [string]$s.Tag } else { $null }
            })
        $b.add_MouseLeftButtonUp({
                param($s, $e)
                $e.Handled = $true
                $X = $script:ChatOverlayHost
                $was = if ($X.ChipPressed) { [string]$X.ChipPressedId } else { '' }
                $X.ChipPressed = $false
                $X.ChipPressedId = $null
                Invoke-ChatOverlayChipRelease $X $was ([string]$s.Tag)
            })
        [void]$row.Children.Add($b)
    }
    $H.ChipWin.Content = $row
}

function Set-ChatOverlayChipPlacement {
    # over its row's right end, wherever that row is drawn now
    param($H)
    if (-not $H.ChipWin -or $H.ChipHwnd -eq [IntPtr]::Zero -or -not $H.ChipLine) { return }
    $p = [ChatOverlayNative]::GetRect($H.Hwnd)
    if (-not $p) { return }
    $px = $p[2] / [Math]::Max(1.0, [double]$H.Win.ActualWidth)
    if ($H.ChipWin.IsVisible) { $c = [ChatOverlayNative]::GetRect($H.ChipHwnd); $size = @($c[2], $c[3]) }
    else {
        $H.ChipWin.Content.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $d = $H.ChipWin.Content.DesiredSize
        $size = @([int][Math]::Ceiling($d.Width * $px), [int][Math]::Ceiling($d.Height * $px))
    }
    $l = [int[]]$H.ChipLine
    $a = if ($script:ChatOverlayWorkAreaSeam) { & $script:ChatOverlayWorkAreaSeam $l }
    else { [System.Windows.Forms.Screen]::FromRectangle([System.Drawing.Rectangle]::new($l[0], $l[1], [Math]::Max(1, $l[2]), [Math]::Max(1, $l[3]))).WorkingArea }
    # an auto-continue chip keeps clear of the row's state and a gap
    $auto = @($H.ChipActions | Where-Object { $_ -and [string]$_.Id -in 'dont', 'continue' }).Count
    $keep = if ($H.ChipState -and $auto) { [int]$H.ChipState[2] + [int][Math]::Round(6 * $px) } else { 0 }
    $at = Get-ChatOverlayChipPlacement $l $size ([pscustomobject]@{ X = $a.X; Y = $a.Y; Width = $a.Width; Height = $a.Height }) $keep
    [ChatOverlayNative]::MoveTo($H.ChipHwnd, $at.X, $at.Y)
}

function Show-ChatOverlayChip {
    # for one row (an entry of Get-ChatOverlayRowRects), with that row's
    # actions - its face made anew only when they differ from the last
    # row's; placed before it shows, so it never flashes where it last was,
    # and armed only when the pointer is not already on it
    param($H, $Entry, $At = $null)
    if (-not $H.ChipWin -or -not $Entry) { return }
    $H.ChipKey = [string]$Entry.Key
    $H.ChipRow = $Entry.Row
    $H.ChipLine = $Entry.Line
    $H.ChipState = Get-ChatField $Entry 'State'
    $H.ChipAt = Get-Date
    $H.ChipOverAt = $H.ChipAt
    $H.ChipSpent = $H.ChipKey
    $H.ChipPressed = $false
    $H.ChipPressedId = $null
    $acts = @(Get-ChatOverlayChipActions $Entry.Row)
    if ((Get-ChatOverlayChipSig $acts) -ne (Get-ChatOverlayChipSig @($H.ChipActions)) -or -not $H.ChipWin.Content) {
        $H.ChipActions = $acts
        New-ChatOverlayChipContent $H
    }
    Set-ChatOverlayChipPlacement $H
    $H.ChipWin.Show()
    # WPF sets WS_EX_APPWINDOW again as it shows a window
    [ChatOverlayNative]::ApplyExStyle($H.ChipHwnd, $false)
    [ChatOverlayNative]::KeepTopmost($H.ChipHwnd)
    Set-ChatOverlayChipPlacement $H
    $H.ChipArmed = -not ($At -and (Test-ChatOverlayPointerIn $At ([ChatOverlayNative]::GetRect($H.ChipHwnd))))
}

function Hide-ChatOverlayChip {
    param($H)
    if (-not $H) { return }
    if ($H.ChipWin) { try { $H.ChipWin.Hide() } catch {} }
    $H.ChipKey = $null
    $H.ChipRow = $null
    $H.ChipArmed = $false
    $H.ChipPressed = $false
    $H.ChipPressedId = $null
}

function Update-ChatOverlayChip {
    # Every pointer check, after the controls': the chip over a row the
    # pointer rests on that has something to offer (Get-ChatOverlayChipActions)
    # - a Claude row to open, the banner's answers - following its row, gone
    # when the pointer is (Get-ChatOverlayChipTarget). The pointer is only
    # read.
    param($H, $At, [bool]$Down, [datetime]$Now, [bool]$OnPanel)
    if (-not $H.ChipWin) { return }
    $blocked = [bool]($H.Collapsed -or $H.Dragging -or $H.GripDrag)
    $onChip = [bool]$H.ChipKey -and (Test-ChatOverlayPointerIn $At ([ChatOverlayNative]::GetRect($H.ChipHwnd)))
    $entry = $null
    $acts = @()
    if (($OnPanel -or $onChip) -and -not $blocked) {
        $entry = Find-ChatOverlayRowAt $At @(Get-ChatOverlayRowRects $H)
        if ($entry) { $acts = @(Get-ChatOverlayChipActions $entry.Row) }
        if (-not $acts.Count) { $entry = $null }
    }
    $under = if ($entry) { [string]$entry.Key } else { '' }
    Step-ChatOverlayChipState $H $under "$($At.X),$($At.Y)" $onChip $Now
    $rested = if ($H.ChipUnderAt) { ($Now - $H.ChipUnderAt).TotalMilliseconds } else { 0 }
    $since = if ($H.ChipOverAt) { ($Now - $H.ChipOverAt).TotalMilliseconds } else { [double]::MaxValue }
    $delay = if ($H.Ctx -and $H.Ctx.Config -and $H.Ctx.Config.chipDelayMs) { [double]$H.Ctx.Config.chipDelayMs } else { 400 }
    $target = Get-ChatOverlayChipTarget ([string]$H.ChipKey) $under $rested $onChip $since $Down $blocked ([string]$H.ChipSpent) $delay
    if (-not $target) { if ($H.ChipKey) { Hide-ChatOverlayChip $H }; return }
    if ($target -ne $H.ChipKey) { Show-ChatOverlayChip $H $entry $At; return }
    # the same row: follow it, should it have moved, and show what it
    # offers now - the banner's count can change under a resting pointer
    if ($entry -and $entry.Key -eq $H.ChipKey) {
        $H.ChipLine = $entry.Line
        $H.ChipState = Get-ChatField $entry 'State'
        if ((Get-ChatOverlayChipSig $acts) -ne (Get-ChatOverlayChipSig @($H.ChipActions))) {
            $H.ChipRow = $entry.Row
            $H.ChipActions = $acts
            New-ChatOverlayChipContent $H
        }
    }
    Set-ChatOverlayChipPlacement $H
}

function Start-ChatShowFreshProcess {
    <#
    Show-ChatFresh for a chip's row in a hidden Windows PowerShell of its
    own, so the window's thread never waits on the registry, CIM or the code
    CLI. Every value goes in single-quoted, quotes doubled - the curly ones
    too - and the title as base64, so nothing a chat is called is ever read
    as code. It exits with Show-ChatFresh's ExitCode.
    #>
    param($H, $Row)
    if (-not (Test-ChatOverlayRowOpenable $Row)) { return $null }
    $path = $script:ChatqScriptPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    $q = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$s) + "'" }
    $pre = '$env:CHATQ_OVERLAY=''1''; '
    foreach ($n in 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CHAT_CODE_USER', 'CHATQ_CLAUDE', 'CHATQ_CODE') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $pre += "`$env:$n=$(& $q $v); " }
    }
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string](Get-ChatField $Row 'title')))
    $home0 = if ($H -and $H.Ctx) { [string]$H.Ctx.ClaudeHome } else { $script:ChatClaudeHome }
    $cmd = $pre + ". $(& $q $path); `$r = @(Show-ChatFresh -Via chip -SessionId $(& $q $Row.sessionId) -Cwd $(& $q $Row.cwd) " +
    "-TitleB64 $(& $q $b64) -ConfigDir $(& $q $home0))[-1]; exit [int]`$r.ExitCode"
    if ($script:ChatShowSpawnSeam) { return (& $script:ChatShowSpawnSeam $cmd) }   # tests
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $exe = Join-Path $(if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try { return (Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) -WindowStyle Hidden -PassThru) }
    catch { Write-ChatOverlayLog "open: $($_.Exception.Message)"; return $null }
}

function Invoke-ChatOverlayOpen {
    # The chip clicked: one open at a time, in a child of its own. No window
    # is activated from here - code -n, in the child, has VS Code raise its own.
    param($H, $Row)
    if (-not $H -or -not $Row -or $H.OpenProc) { return }
    $p = Start-ChatShowFreshProcess $H $Row
    if (-not $p) { return }
    $H.OpenProc = $p
    $H.OpenAt = Get-Date
    # kept for the line its end writes, and for the dot an open that worked
    # takes away (Update-ChatOverlayOpen)
    $sid = [string]$Row.sessionId
    $H.OpenSessionId = $sid
    $H.OpenSid = $sid.Substring(0, [Math]::Min(8, $sid.Length))
    if ($H.ChipText) { $H.ChipText.Text = 'opening'; $H.ChipText.Foreground = Get-ChatOverlayBrush 'dim' }
    Write-ChatOverlayLog "open: $($H.OpenSid)" -Always
}

function Get-ChatOverlayOpenBalloon {
    # what the tray says when an open ends, by its child's exit code
    # (Show-ChatFresh); $null says nothing. Pure.
    param([int]$Code)
    switch ($Code) {
        15 { return 'A queued prompt is running in that chat - open it once it finishes.' }
        20 { return 'That chat is open in a terminal - not opened in VS Code as well.' }
        25 { return 'Shown in its window, which also has other folders open - bring it forward yourself.' }
        30 { return 'That chat has not started yet.' }
        40 { return 'Asked its window to show it, but VS Code''s code command was not found, so the window was not brought forward.' }
        41 { return 'code failed - see data/logs/watcher.log.' }
    }
    return $null
}

function Update-ChatOverlayOpen {
    # every tick while an open runs: when its child is done, say how it went,
    # and put the chip back; after 60 s stop waiting for it. Every end is
    # logged, 0 too, so each click has its outcome beside it in the log.
    # The chat's unread dot goes only once the open request for its window
    # was written (Show-ChatFresh): opened (0), shown in a window of several
    # folders (25), or asked of its window with code not found (40) or
    # failing (41) - the window still takes the request, only not brought
    # forward. Not on held (10): a chat at work, which the extension may yet
    # refuse to open. Turned away, failed before the request, or no answer,
    # its turn is still unseen, and the dot stays.
    param($H)
    $p = $H.OpenProc
    if (-not $p) { return }
    $ended = try { $p.HasExited } catch { $true }
    if (-not $ended -and ((Get-Date) - $H.OpenAt).TotalSeconds -lt 60) { return }
    if ($ended) {
        $code = try { [int]$p.ExitCode } catch { -1 }
        Write-ChatOverlayLog "open: $($H.OpenSid) ended $code" -Always
        if ($code -in 0, 25, 40, 41 -and $H.OpenSessionId -and $H.Ctx -and $H.Ctx.Unread) { $H.Ctx.Unread.Remove([string]$H.OpenSessionId) }
        $say = Get-ChatOverlayOpenBalloon $code
        if ($say) { Show-ChatOverlayBalloon $H $say }
    }
    else { Write-ChatOverlayLog "open: $($H.OpenSid) no answer after 60 s - stopped waiting" -Always }
    $H.OpenProc = $null
    $H.OpenSid = $null
    $H.OpenSessionId = $null
    if ($H.ChipText) { $H.ChipText.Text = 'open'; $H.ChipText.Foreground = Get-ChatOverlayBrush 'text' }
    Hide-ChatOverlayChip $H
}

function Add-ChatOverlayUsage {
    # The bars: a row per usage window - window, a bar in the server's colour
    # for it, the percent, and a reset countdown that ticks every second -
    # and beside them the provider's name with, under it, when its figure is
    # from (Get-ChatOverlayUsageStatus): what took rows of its own under the
    # bars before.
    param($H, $Panel, $Usage)
    $ws = @($Usage.windows)
    $g = [System.Windows.Controls.Grid]::new()
    $g.Margin = [System.Windows.Thickness]::new(0, 1, 0, 3)
    foreach ($cw in 92, 62, 0, 38, 66) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        $cd.Width = if ($cw) { [System.Windows.GridLength]::new($cw) } else { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
        $g.ColumnDefinitions.Add($cd)
    }
    foreach ($w in $ws) { $g.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) }
    $tone = if ($Usage.stale) { 'faint' } else { 'text' }
    $who = [System.Windows.Controls.StackPanel]::new()
    [void]$who.Children.Add((New-ChatOverlayText ([string]$Usage.provider) $tone -Bold))
    if ($Usage.status) { [void]$who.Children.Add((New-ChatOverlayText ([string]$Usage.status) 'faint' 10.5 -Trim)) }
    [System.Windows.Controls.Grid]::SetRowSpan($who, [Math]::Max(1, $ws.Count))
    [void]$g.Children.Add($who)
    $row = 0
    foreach ($w in $ws) {
        $cells = @((New-ChatOverlayText $w.label 'dim' -Trim))
        $pct = [Math]::Max(0.0, [Math]::Min(100.0, [double]$w.percent))
        $bar = [System.Windows.Controls.Grid]::new()
        $bar.Height = 5
        $bar.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $bar.Margin = [System.Windows.Thickness]::new(2, 1, 8, 0)
        foreach ($share in $pct, (100 - $pct)) {
            $cd = [System.Windows.Controls.ColumnDefinition]::new()
            $cd.Width = [System.Windows.GridLength]::new($share, [System.Windows.GridUnitType]::Star)
            $bar.ColumnDefinitions.Add($cd)
        }
        $track = [System.Windows.Controls.Border]::new()
        $track.CornerRadius = [System.Windows.CornerRadius]::new(2.5)
        $track.Background = Get-ChatOverlayBrush 'track'
        [System.Windows.Controls.Grid]::SetColumnSpan($track, 2)
        $fill = [System.Windows.Controls.Border]::new()
        $fill.CornerRadius = [System.Windows.CornerRadius]::new(2.5)
        $fill.Background = Get-ChatOverlayBrush $(if ($Usage.stale) { 'faint' } else { [string]$w.severity })
        [void]$bar.Children.Add($track)
        [void]$bar.Children.Add($fill)
        $cells += $bar
        $p = New-ChatOverlayText "$($w.percent)%" $(if ($w.limited) { 'critical' } else { $tone }) -Bold
        $p.TextAlignment = [System.Windows.TextAlignment]::Right
        $cells += $p
        $r = New-ChatOverlayText (Format-ChatOverlayReset $w.resetsAt) 'dim' 11
        $r.TextAlignment = [System.Windows.TextAlignment]::Right
        $r.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $cells += $r
        if ($w.resetsAt) { $H.Clocks.Add(@{ Block = $r; At = $w.resetsAt }) }
        for ($i = 0; $i -lt $cells.Count; $i++) {
            [System.Windows.Controls.Grid]::SetColumn($cells[$i], $i + 1)
            [System.Windows.Controls.Grid]::SetRow($cells[$i], $row)
            [void]$g.Children.Add($cells[$i])
        }
        $row++
    }
    [void]$Panel.Children.Add($g)
}

function Add-ChatOverlayUsageLine {
    # Usage as one line a provider, as the collapsed panel has it: the name,
    # each window and its percent - in the server's colour for it, now there
    # is no bar to carry that - and at the end when the figure is from.
    # After one window's percent, when it resets (Get-ChatOverlayResetWindow:
    # the latest reset of a window at its limit, else the 5h one's), as a
    # clock that goes once the time has passed. It wraps rather than trims,
    # so a narrow panel shows a second line rather than hiding a window.
    param($H, $Panel, $Usage)
    $line = [System.Windows.Controls.DockPanel]::new()
    $line.LastChildFill = $true
    $line.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
    $tone = if ($Usage.stale) { 'faint' } else { 'text' }
    $name = New-ChatOverlayText ([string]$Usage.provider) $tone -Bold
    $name.Width = 56
    [System.Windows.Controls.DockPanel]::SetDock($name, [System.Windows.Controls.Dock]::Left)
    $end = New-ChatOverlayText ([string]$Usage.status) 'faint' 11
    $end.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $end.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($end, [System.Windows.Controls.Dock]::Right)
    $mid = [System.Windows.Controls.TextBlock]::new()
    $mid.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $resets = Get-ChatOverlayResetWindow @($Usage.windows)
    $first = $true
    foreach ($w in @($Usage.windows)) {
        if (-not $first) { $sep = [System.Windows.Documents.Run]::new(" $($script:ChatqDot) "); $sep.Foreground = Get-ChatOverlayBrush 'faint'; $mid.Inlines.Add($sep) }
        $first = $false
        $l = [System.Windows.Documents.Run]::new("$($w.label) ")
        $l.Foreground = Get-ChatOverlayBrush 'dim'
        $mid.Inlines.Add($l)
        $p = [System.Windows.Documents.Run]::new("$($w.percent)%")
        $p.FontWeight = [System.Windows.FontWeights]::SemiBold
        # normal reads as plain text; only warning and worse take a colour
        $p.Foreground = Get-ChatOverlayBrush $(if ($Usage.stale) { 'faint' } elseif ($w.limited) { 'critical' } elseif ($w.severity -in 'warning', 'critical') { [string]$w.severity } else { 'text' })
        $mid.Inlines.Add($p)
        if ($resets -and $w.label -eq $resets -and $w.resetsAt) {
            $t = Format-ChatOverlayResetAt $w.resetsAt
            $r = [System.Windows.Documents.Run]::new($(if ($t) { " resets $t" } else { '' }))
            $r.Foreground = Get-ChatOverlayBrush $(if ($w.limited) { 'critical' } else { 'dim' })
            $mid.Inlines.Add($r)
            if ($H -and $null -ne $H.Clocks) { $H.Clocks.Add(@{ Block = $r; At = $w.resetsAt; Kind = 'at' }) }
        }
    }
    [void]$line.Children.Add($name)
    [void]$line.Children.Add($end)
    [void]$line.Children.Add($mid)
    [void]$Panel.Children.Add($line)
}

function New-ChatOverlayWhereGlyph {
    # Where a chat runs, drawn small after its dot: a window's outline for a
    # VS Code panel, >_ for a terminal; $null for anything else. Bare - the
    # panel lets clicks through, so nothing to point at - and in the dim
    # colour, so it reads as a mark, not a state.
    param([string]$Where)
    $d = switch ($Where) {
        # the frame and its title bar
        'vscode' { 'M0.5,0.5 L9.5,0.5 L9.5,8.5 L0.5,8.5 Z M0.5,2.8 L9.5,2.8' }
        'terminal' { 'M0.5,1.5 L3.5,4.5 L0.5,7.5 M5,8 L9.5,8' }
    }
    if (-not $d) { return $null }
    $p = [System.Windows.Shapes.Path]::new()
    $p.Data = [System.Windows.Media.Geometry]::Parse($d)
    $p.Width = 10
    $p.Height = 9
    $p.Stroke = Get-ChatOverlayBrush 'dim'
    $p.StrokeThickness = 1
    $p.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
    $p.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    $p.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $p.Margin = [System.Windows.Thickness]::new(0, 1, 6, 0)
    # which one, for the tests
    $p.Tag = $Where
    return $p
}

function Add-ChatOverlayRow {
    <#
    A dot in the state's colour, where the chat runs, project and title,
    what it is doing at the right, and its newest prompt beneath. Compact
    (prompts off): no prompt line, and tighter margins, so each chat is one
    line. The first line is the DockPanel tagged 'line': its marks docked
    left or right, then the title, last, filling what is left. A chat that
    finished a turn while you were elsewhere, since you last opened it from
    the overlay (unread), has a small dot in the accent colour before its
    state. A Recent line (kind recent) is
    always compact, and fainter: no state, and not open.
    #>
    param($Panel, $Row, $Cfg)
    $recent = [string](Get-ChatField $Row 'kind') -eq 'recent'
    $wrap = [System.Windows.Controls.StackPanel]::new()
    $wrap.Margin = if ($Cfg.prompts -and -not $recent) { [System.Windows.Thickness]::new(0, 3, 0, 3) } else { [System.Windows.Thickness]::new(0, 1, 0, 1) }
    # the row it draws, for the open chip to find under the pointer
    $wrap.Tag = $Row
    $line = [System.Windows.Controls.DockPanel]::new()
    $line.Tag = 'line'
    $line.LastChildFill = $true
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8
    $dot.Height = 8
    $dot.Margin = [System.Windows.Thickness]::new(0, 1, 7, 0)
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $c = Get-ChatOverlayBrush ([string]$Row.status)
    if ($Row.status -eq 'queued') { $dot.Stroke = $c; $dot.StrokeThickness = 1.5 } else { $dot.Fill = $c }
    [System.Windows.Controls.DockPanel]::SetDock($dot, [System.Windows.Controls.Dock]::Left)
    $right = New-ChatOverlayText ([string]$Row.stateText) $(if ($Row.rank -eq 0) { 'warn' } elseif ($recent) { 'faint' } else { 'dim' }) 11
    $right.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $right.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($right, [System.Windows.Controls.Dock]::Right)
    # which it is, for the chip to keep clear of; and a cut-off's words in
    # full, where a tooltip can show (the console draws rows with this too)
    $right.Tag = 'state'
    $au = Get-ChatField $Row 'auto'
    if ($au -and (Get-ChatField $au 'long')) { $right.ToolTip = "$($au.long)$(if (Get-ChatField $au 'why') { " - $($au.why)" })" }
    $main = [System.Windows.Controls.TextBlock]::new()
    $main.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    if ($Row.project) {
        $run = [System.Windows.Documents.Run]::new([string]$Row.project + '  ')
        $run.Foreground = Get-ChatOverlayBrush 'project'
        $run.FontWeight = [System.Windows.FontWeights]::SemiBold
        $main.Inlines.Add($run)
    }
    $run = [System.Windows.Documents.Run]::new([string]$Row.title)
    $run.Foreground = Get-ChatOverlayBrush $(if ($recent) { 'dim' } else { 'text' })
    $main.Inlines.Add($run)
    [void]$line.Children.Add($dot)
    # a chat's own rows only: a job or a cut-off chat runs nowhere yet
    $mark = if ([string](Get-ChatField $Row 'kind') -eq 'session') { New-ChatOverlayWhereGlyph ([string](Get-ChatField $Row 'where')) } else { $null }
    if ($mark) {
        [System.Windows.Controls.DockPanel]::SetDock($mark, [System.Windows.Controls.Dock]::Left)
        [void]$line.Children.Add($mark)
    }
    elseif (-not $recent) {
        # the mark's room, empty: every title starts at one column, where a
        # chat runs known or not (a cut-off or a job has none)
        $slot = [System.Windows.Controls.Border]::new()
        $slot.Width = 10
        $slot.Margin = [System.Windows.Thickness]::new(0, 1, 6, 0)
        $slot.Tag = 'slot'
        [System.Windows.Controls.DockPanel]::SetDock($slot, [System.Windows.Controls.Dock]::Left)
        [void]$line.Children.Add($slot)
    }
    [void]$line.Children.Add($right)
    # docked right after the state, so it sits just before it
    if (Get-ChatField $Row 'unread') {
        $new = [System.Windows.Shapes.Ellipse]::new()
        $new.Width = 6
        $new.Height = 6
        $new.Fill = Get-ChatOverlayBrush 'accent'
        $new.Margin = [System.Windows.Thickness]::new(8, 1, 0, 0)
        $new.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        # which it is, for the tests; bare, as the where mark is
        $new.Tag = 'unread'
        [System.Windows.Controls.DockPanel]::SetDock($new, [System.Windows.Controls.Dock]::Right)
        [void]$line.Children.Add($new)
    }
    [void]$line.Children.Add($main)
    [void]$wrap.Children.Add($line)
    if ($Cfg.prompts -and $Row.prompt -and -not $recent) {
        $p = New-ChatOverlayText ([string]$Row.prompt) 'dim' 11 -Trim
        $p.Margin = [System.Windows.Thickness]::new(15, 1, 0, 0)
        [void]$wrap.Children.Add($p)
    }
    [void]$Panel.Children.Add($wrap)
}

function Add-ChatOverlayAsk {
    <#
    The banner saying the limit is over and how many chats it cut off can
    continue (the snapshot's header.ask), last in the header - in place of
    the ask's note, which the Windows panel skips. Drawn as a row's first
    line: a dot in the cut-off colour, the words, and "continue?" at the
    right. Tagged like a row, kind ask, so the chip rests on it with the
    two answers (Get-ChatOverlayChipActions); the tag carries the keys the
    answer acts on - what the user saw. No row count takes it for a row.
    #>
    param($H, $Panel, $Ask)
    $n = [int](Get-ChatField $Ask 'count')
    $keys = @(@(Get-ChatField $Ask 'keys') | Where-Object { $_ })
    $titles = @(@(Get-ChatField $Ask 'titles') | Where-Object { $_ })
    $left = @(@(Get-ChatField $Ask 'left') | Where-Object { $_ })
    $at = Format-ChatOverlayAskAt (Get-ChatField $Ask 'resetsAt')
    $wrap = [System.Windows.Controls.StackPanel]::new()
    $wrap.Margin = [System.Windows.Thickness]::new(0, 3, 0, 1)
    $wrap.Tag = [pscustomobject]@{ key = 'ask'; kind = 'ask'; provider = ''; sessionId = ''; cwd = ''; count = $n; keys = $keys; titles = $titles }
    $line = [System.Windows.Controls.DockPanel]::new()
    $line.Tag = 'line'
    $line.LastChildFill = $true
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8
    $dot.Height = 8
    $dot.Margin = [System.Windows.Thickness]::new(0, 1, 7, 0)
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $dot.Fill = Get-ChatOverlayBrush 'cutoff'
    [System.Windows.Controls.DockPanel]::SetDock($dot, [System.Windows.Controls.Dock]::Left)
    $right = New-ChatOverlayText 'continue?' 'faint' 11
    $right.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $right.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($right, [System.Windows.Controls.Dock]::Right)
    $head = if ($at) { "limit over at $at" } else { 'limit over' }
    $main = New-ChatOverlayText "$head $($script:ChatqDot) $n chat$(if ($n -ne 1) { 's' }) it cut off can continue" 'warn' -Trim
    [void]$line.Children.Add($dot)
    [void]$line.Children.Add($right)
    [void]$line.Children.Add($main)
    [void]$wrap.Children.Add($line)
    $tip = @($titles) + @($left)
    if ($tip.Count) { $wrap.ToolTip = $tip -join "`n" }
    [void]$Panel.Children.Add($wrap)
}

function Update-ChatOverlayView {
    <#
    Redraw the panel from a snapshot, but only when what it shows changed -
    the rows carry their ages, so at least once a minute. In between, only
    the reset countdowns move. Rows stop at maxRows, or sooner where the
    screen's foot does (Update-ChatOverlayMaxHeight); a line says how
    many more there are. The recent chats not open go under that
    (Add-ChatOverlayRecent).
    #>
    param($H, $Snap)
    $H.Snap = $Snap
    # The console's mode: the snapshot kept, for the console, and nothing
    # drawn - the window shows the console's content, and the rows are
    # drawn afresh as it goes back to the panel.
    if ($H.Mode -eq 'console') { $H.ViewKey = $null; return }
    Update-ChatOverlayMaxHeight $H
    # ViewSig is the snapshot's JSON, every row's field in it - a chat's
    # where and unread among them - and the recent list whole; prompts is
    # compact rows or full
    $key = "$($H.Ctx.ViewSig)|$($H.Locked)|$($H.Ctx.Config.width)|$($H.Ctx.Config.prompts)|$($H.Collapsed)|$($H.Ctx.Config.maxRows)|$($H.Win.MaxHeight)"
    if ($key -eq $H.ViewKey) { Update-ChatOverlayClock $H; return }
    $H.ViewKey = $key
    $cfg = $H.Ctx.Config
    $P = $H.Stack
    $P.Children.Clear()
    $H.Clocks = [System.Collections.Generic.List[object]]::new()
    if ($H.Collapsed) { Hide-ChatOverlayChip $H; Add-ChatOverlayCompact $P $Snap; Add-ChatOverlayUnlockedHint $H $P; return }
    foreach ($u in @($Snap.header.usage)) {
        if (-not $u) { continue }
        if ($cfg.usageView -eq 'bars') { Add-ChatOverlayUsage $H $P $u } else { Add-ChatOverlayUsageLine $H $P $u }
    }
    foreach ($n in @($Snap.header.notes)) {
        # the ask's note is the banner here, drawn below
        if (-not $n -or [string](Get-ChatField $n 'kind') -eq 'ask') { continue }
        $t = New-ChatOverlayText ([string]$n.text) $(if ($n.tone -eq 'dim') { 'faint' } else { [string]$n.tone }) 11 -Trim
        $t.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        [void]$P.Children.Add($t)
    }
    $ask = Get-ChatField $Snap.header 'ask'
    if ($ask) { Add-ChatOverlayAsk $H $P $ask }
    $rows = @($Snap.rows)
    if (@($Snap.header.usage).Count -or @($Snap.header.notes).Count -or $ask) {
        $sep = [System.Windows.Controls.Border]::new()
        $sep.Height = 1
        $sep.Background = Get-ChatOverlayBrush 'edge'
        $sep.Margin = [System.Windows.Thickness]::new(0, 6, 0, 4)
        [void]$P.Children.Add($sep)
    }
    $shown = @($rows | Select-Object -First $cfg.maxRows)
    foreach ($r in $shown) { Add-ChatOverlayRow $P $r $cfg }
    $n = Limit-ChatOverlayRows $H ($rows.Count -gt $shown.Count)
    if ($n -lt $shown.Count) { $shown = @($shown | Select-Object -First $n) }
    if ($rows.Count -gt $shown.Count) {
        $rest = @($rows | Select-Object -Skip $shown.Count)
        $bits = @()
        $idle = @($rest | Where-Object { $_.status -eq 'idle' }).Count
        $q = @($rest | Where-Object { $_.status -eq 'queued' }).Count
        if ($idle) { $bits += "$idle idle" }
        if ($q) { $bits += "$q queued" }
        $more = "+$($rest.Count) more" + $(if ($bits) { " $($script:ChatqDot) " + ($bits -join ', ') } else { '' })
        [void]$P.Children.Add((New-ChatOverlayText $more 'faint' 11))
    }
    if (-not $rows) { [void]$P.Children.Add((New-ChatOverlayText 'no chats open' 'faint' 11)) }
    Add-ChatOverlayRecent $H $P @(Get-ChatField $Snap 'recent') $cfg
    # the chip goes with its row, open or recent; one still drawn keeps the
    # row's new data
    if ($H.ChipKey) {
        $still = @(@($P.Children) | ForEach-Object { $_.Tag } | Where-Object { $_ -and $_ -isnot [string] -and [string](Get-ChatField $_ 'key') -eq $H.ChipKey }) | Select-Object -First 1
        if ($still) { $H.ChipRow = $still } else { Hide-ChatOverlayChip $H }
    }
    Add-ChatOverlayUnlockedHint $H $P
}

function Add-ChatOverlayRecent {
    <#
    The newest chats not open (the snapshot's recent), under the open rows
    and the "+N more" line: a faint Recent header, then one compact line
    each - project and title, how long ago at the right. Each is a row the
    open chip takes, as an open one is, to open it as a tab. Only as many
    as fit under the panel's MaxHeight, room left for the unlocked hint;
    none, and the header goes too.
    #>
    param($H, $Panel, [object[]]$Recent, $Cfg)
    $items = @($Recent | Where-Object { $_ })
    if (-not $items.Count) { return }
    $head = New-ChatOverlayText 'Recent' 'faint' 11
    $head.Margin = [System.Windows.Thickness]::new(0, 6, 0, 1)
    # a string, so no count of rows takes it for one
    $head.Tag = 'recent'
    [void]$Panel.Children.Add($head)
    foreach ($r in $items) { Add-ChatOverlayRow $Panel $r $Cfg }
    $under = if ($H.Locked) { 0 } else { 18 }
    $n = $items.Count
    while ($n -gt 0 -and -not (Test-ChatOverlayFits $H $under)) { $Panel.Children.RemoveAt($Panel.Children.Count - 1); $n-- }
    if (-not $n) { $Panel.Children.Remove($head) }
}

function Test-ChatOverlayFits {
    # whether what the stack holds now, and -Extra WPF units under it, fit
    # the panel's MaxHeight - with its frame's padding and edge; always, when
    # there is no cap yet
    param($H, [double]$Extra = 0)
    $cap = [double]$H.Win.MaxHeight
    if ([double]::IsInfinity($cap) -or $cap -le 0) { return $true }
    $f = $H.Frame
    $chrome = $f.Padding.Top + $f.Padding.Bottom + $f.BorderThickness.Top + $f.BorderThickness.Bottom
    $wide = [Math]::Max(1.0, $H.Win.Width - $f.Padding.Left - $f.Padding.Right - $f.BorderThickness.Left - $f.BorderThickness.Right)
    $H.Stack.Measure([System.Windows.Size]::new($wide, [double]::PositiveInfinity))
    return ($H.Stack.DesiredSize.Height + $chrome + $Extra -le $cap)
}

function Limit-ChatOverlayRows {
    <#
    The rows just drawn - the stack's last children - cut from the end
    until the panel fits its MaxHeight, with room under them for the "+N
    more" line and, unlocked, the hint. -More: rows were left out already,
    so that line comes whatever. Returns how many rows are left, one at
    least: a screen too short for even that clips it instead.
    #>
    param($H, [bool]$More)
    $n = Get-ChatOverlayDrawnRows $H
    $cap = [double]$H.Win.MaxHeight
    if ($n -le 1 -or [double]::IsInfinity($cap) -or $cap -le 0) { return $n }
    $P = $H.Stack
    $line = 18
    $under = if ($H.Locked) { 0 } else { $line }
    if (Test-ChatOverlayFits $H ($under + $(if ($More) { $line } else { 0 }))) { return $n }
    while ($n -gt 1 -and -not (Test-ChatOverlayFits $H ($under + $line))) { $P.Children.RemoveAt($P.Children.Count - 1); $n-- }
    return $n
}

function Add-ChatOverlayUnlockedHint {
    param($H, $Panel)
    if ($H.Locked) { return }
    $keyName = if ($H.Hotkey) { $H.HotkeyText } else { 'the tray menu' }
    $hint = New-ChatOverlayText "unlocked - drag to move $($script:ChatqDot) $keyName locks it" 'unlocked' 11 -Trim
    $hint.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    [void]$Panel.Children.Add($hint)
}

function Add-ChatOverlayCompact {
    # Collapsed: one line - a dot in the most urgent chat's colour, how many
    # chats are in each state, and Claude's usage at the right, with when
    # its reset window resets as the lines view has it. The chats the limit
    # cut off that can continue now are counted apart, as the tray's
    # tooltip counts them.
    param($Panel, $Snap)
    $c = $Snap.counts
    $need = [int]$c.waiting + [int]$c.needsInput
    $bits = @()
    $cut = if ($c -and $c.PSObject.Properties['cutOff']) { [int]$c.cutOff } else { 0 }
    $can = [int](Get-ChatField (Get-ChatField $Snap.header 'ask') 'count')
    if ($need) { $bits += "$need waiting" }
    # finished a turn while you were elsewhere, since you last opened it
    # from the overlay: the dot a row would carry
    $new = if ($c -and $c.PSObject.Properties['unread']) { [int]$c.unread } else { 0 }
    if ($new) { $bits += "$new new" }
    if ($can) { $bits += "$can can continue" }
    $cut = [Math]::Max(0, $cut - $can)
    # of those, how many auto-continue will continue by itself
    $auto = if ($c -and $c.PSObject.Properties['auto']) { [int]$c.auto } else { 0 }
    if ($cut) { $bits += "$cut cut off$(if ($auto) { " ($auto auto)" })" }
    if ([int]$c.busy) { $bits += "$([int]$c.busy) working" }
    if ([int]$c.running) { $bits += "$([int]$c.running) running" }
    if ([int]$c.idle) { $bits += "$([int]$c.idle) idle" }
    if ([int]$c.queued) { $bits += "$([int]$c.queued) queued" }
    $state = if ($need) { 'waiting' } elseif ($cut -or $can) { 'cutoff' } elseif ([int]$c.busy) { 'busy' } elseif ([int]$c.running) { 'running' } else { 'idle' }
    $line = [System.Windows.Controls.DockPanel]::new()
    $line.LastChildFill = $true
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8
    $dot.Height = 8
    $dot.Margin = [System.Windows.Thickness]::new(0, 1, 7, 0)
    $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $dot.Fill = Get-ChatOverlayBrush $state
    [System.Windows.Controls.DockPanel]::SetDock($dot, [System.Windows.Controls.Dock]::Left)
    $u = @($Snap.header.usage | Where-Object { $_ -and $_.provider -eq 'Claude' })[0]
    $use = ''
    if ($u) {
        $resets = Get-ChatOverlayResetWindow @($u.windows)
        $use = (@($u.windows | Select-Object -First 2 | ForEach-Object {
                    $t = if ($resets -and $_.label -eq $resets) { Format-ChatOverlayResetAt $_.resetsAt } else { '' }
                    "$($_.label) $($_.percent)%$(if ($t) { " resets $t" })"
                }) -join " $($script:ChatqDot) ")
    }
    $right = New-ChatOverlayText $use $(if ($u -and $u.stale) { 'faint' } else { 'dim' }) 11
    $right.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $right.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($right, [System.Windows.Controls.Dock]::Right)
    $main = New-ChatOverlayText $(if ($bits) { $bits -join " $($script:ChatqDot) " } else { 'no chats open' }) 'text' -Trim
    [void]$line.Children.Add($dot)
    [void]$line.Children.Add($right)
    [void]$line.Children.Add($main)
    [void]$Panel.Children.Add($line)
}

function Update-ChatOverlayClock {
    # The bars' countdowns, and the lines view's reset time (Kind at), which
    # goes once that time has passed.
    param($H)
    $now = Get-Date
    foreach ($c in @($H.Clocks)) {
        if ($c.Kind -eq 'at') {
            $t = Format-ChatOverlayResetAt $c.At -Now $now
            $c.Block.Text = if ($t) { " resets $t" } else { '' }
        }
        else { $c.Block.Text = Format-ChatOverlayReset $c.At $now }
    }
}

function Get-ChatOverlayPlacement {
    <#
    Where the panel goes: where it was left, as long as a 48 x 24 corner of it
    still shows on some screen - a monitor unplugged or a resolution changed
    can leave it nowhere - and otherwise the main screen's top-right corner.
    Screens are working areas in physical pixels. Pure, for the tests.
    #>
    param($X, $Y, [int]$Width, [int]$Height, [object[]]$Screens)
    if ($null -ne $X -and $null -ne $Y) {
        foreach ($s in @($Screens)) {
            $vw = [Math]::Min([int]$X + $Width, $s.X + $s.Width) - [Math]::Max([int]$X, $s.X)
            $vh = [Math]::Min([int]$Y + $Height, $s.Y + $s.Height) - [Math]::Max([int]$Y, $s.Y)
            if ($vw -ge 48 -and $vh -ge 24) { return [pscustomobject]@{ X = [int]$X; Y = [int]$Y; Moved = $false } }
        }
    }
    $p = @($Screens | Where-Object { $_.Primary })[0]
    if (-not $p) { $p = @($Screens)[0] }
    if (-not $p) { return [pscustomobject]@{ X = 0; Y = 0; Moved = $true } }
    # room above it for the row of buttons, even at 200%
    return [pscustomobject]@{ X = [int]($p.X + $p.Width - $Width - 16); Y = [int]($p.Y + 56); Moved = $true }
}

function Set-ChatOverlayPlacement {
    param($H, [switch]$Corner)
    if ($H.Hwnd -eq [IntPtr]::Zero) { return }
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    $wide = if ($r) { $r[2] } else { 380 }
    $tall = if ($r) { [Math]::Max($r[3], 24) } else { 120 }
    $screens = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            $a = $_.WorkingArea
            [pscustomobject]@{ X = $a.X; Y = $a.Y; Width = $a.Width; Height = $a.Height; Primary = $_.Primary }
        })
    $x = if ($Corner) { $null } else { $H.State.x }
    $y = if ($Corner) { $null } else { $H.State.y }
    $p = Get-ChatOverlayPlacement $x $y $wide $tall $screens
    if ($p.Moved -and $null -ne $x) { Write-ChatOverlayLog "moved back onto a screen from $x,$y" }
    [ChatOverlayNative]::MoveTo($H.Hwnd, $p.X, $p.Y)
    $H.Placed = $true
    if ($p.X -ne $H.State.x -or $p.Y -ne $H.State.y) {
        $H.State.x = $p.X
        $H.State.y = $p.Y
        Save-ChatOverlayState $H.State
    }
    Sync-ChatOverlayHeightCap $H
}

function Invoke-ChatOverlayDrag {
    # Unlocked, a press anywhere on the panel drags it (the grip has its own,
    # Start-ChatOverlayGripDrag). Passes wait meanwhile: DragMove runs its
    # own message loop, and the timer would fire inside it.
    $H = $script:ChatOverlayHost
    if (-not $H -or $H.Locked) { return }
    $H.Dragging = $true
    try { $H.Win.DragMove() } catch {}
    $H.Dragging = $false
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    if ($r) { $H.State.x = $r[0]; $H.State.y = $r[1]; Save-ChatOverlayState $H.State }
    Sync-ChatOverlayHeightCap $H
}

function Set-ChatOverlayLocked {
    # Locked: clicks go through to whatever is under it. Unlocked: it takes the
    # mouse so it can be dragged, shows a blue edge, and locks itself again
    # 2 minutes after the pointer leaves - a forgotten unlock would otherwise
    # go on swallowing clicks over that corner of the screen.
    param($H, [bool]$Locked)
    $H.Locked = $Locked
    Hide-ChatOverlayChip $H
    if ($H.Hwnd -ne [IntPtr]::Zero) { [ChatOverlayNative]::ApplyExStyle($H.Hwnd, $Locked) }
    $H.Frame.BorderBrush = Get-ChatOverlayBrush $(if ($Locked) { 'edge' } else { 'unlocked' })
    $H.PointerIn = $false
    $H.LeftAt = if ($Locked) { $null } else { Get-Date }
    $H.State.locked = $Locked
    Save-ChatOverlayState $H.State
    $H.ViewKey = $null
    if ($H.Snap) { Update-ChatOverlayView $H $H.Snap }
    Update-ChatOverlayMenu $H
}

function Set-ChatOverlayHidden {
    param($H, [bool]$Hidden)
    $H.Hidden = $Hidden
    if ($Hidden) {
        $H.Win.Hide()
        Show-ChatOverlayControls $H $false
        # the pointer check stops while hidden, so nothing else would
        Hide-ChatOverlayChip $H
    }
    else {
        $H.Win.Show()
        [ChatOverlayNative]::ApplyExStyle($H.Hwnd, $H.Locked)
        # one that started hidden still sits where it was made, off every screen
        if (-not $H.Placed) { Set-ChatOverlayPlacement $H }
        [ChatOverlayNative]::KeepTopmost($H.Hwnd)
    }
    $H.State.hidden = $Hidden
    Save-ChatOverlayState $H.State
    Update-ChatOverlayMenu $H
}

function Enter-ChatOverlayConsoleMode {
    <#
    The console, in the panel's own window ($H.Mode console): grown from
    the panel's top-right corner - its right edge and top held, on the
    panel's screen (Get-ChatConsolePlacement) - at the size it was last
    left, else 980 x 680. While it shows, the window is one like any other:
    it takes clicks and focus, is on the taskbar and in Alt+Tab, and is not
    kept on top, so other windows can cover it and files can be dragged in
    from Explorer; its grip resizes it. The buttons, the open chip, the
    pointer check and the panel's rows rest meanwhile. Where the panel was,
    its width, rows, fold and height cap are kept for
    Exit-ChatOverlayConsoleMode to put back exactly. Shown hidden and back
    around the switch: the taskbar notices a window's new styles only as it
    shows. -Activate: brought forward with the prompt box ready, when the
    user asked for it - already in this mode, only that.
    #>
    param($H, [switch]$Activate)
    if (-not $H -or -not $H.Win -or $H.ShuttingDown) { return }
    $w = $H.Win
    $front = {
        if ($w.WindowState -eq [System.Windows.WindowState]::Minimized) { $w.WindowState = [System.Windows.WindowState]::Normal }
        if ($script:ChatConsoleFrontSeam) { & $script:ChatConsoleFrontSeam $w } else { [void]$w.Activate() }
        [void]$H.Con.Prompt.Focus()
    }
    if ($H.Mode -eq 'console') { if ($Activate) { & $front }; return }
    # Not mid-drag: DragMove's loop, and a grip or size drag, still take the
    # hotkeys, and the window swapped under one would be moved on as the
    # panel - and its place, the console's, kept as the panel's.
    if ($H.Dragging -or $H.GripDrag -or $H.SizeDrag) { return }
    if (-not $H.Con) { New-ChatConsole $H }
    $C = $H.Con
    # one that started hidden still sits where it was made, off every screen
    if (-not $H.Placed) { Set-ChatOverlayPlacement $H }
    # A slider not yet at rest is kept now, while the window is still the
    # panel: the pointer check that would keep it rests in the console's
    # mode, and keeping it later would take the console's place for the
    # panel's (Get-ChatOverlayPending).
    if ($null -ne $H.PendingOpacity -or $null -ne $H.PendingWidth -or $null -ne $H.PendingRows) { Save-ChatOverlaySetting $H @{} }
    $r = [ChatOverlayNative]::GetRect($H.Hwnd)
    if (-not $r) { return }
    $H.PanelWas = @{
        Rect = $r; Width = $w.Width; WidthWas = $w.Width; MaxHeight = $w.MaxHeight; MinWidth = $w.MinWidth; MinHeight = $w.MinHeight
        Opacity = $w.Opacity; Title = $w.Title; Rows = $H.Ctx.Config.maxRows; Collapsed = $H.Collapsed; Hidden = $H.Hidden
    }
    $H.Mode = 'console'
    Hide-ChatOverlayChip $H
    Show-ChatOverlayControls $H $false
    $H.EnterAt = $null
    $H.PointerIn = $false
    $a = Get-ChatOverlayWorkArea $r
    $px = Get-ChatOverlayScale $H $r -Device
    # its least size, in units, as the window enforces it - no bigger than
    # the screen, so the size placed below is the size it keeps
    $minW = [Math]::Min(640, $a.Width / $px)
    $minH = [Math]::Min(420, $a.Height / $px)
    $at = Get-ChatConsolePlacement $r $C.State ([pscustomobject]@{ X = $a.X; Y = $a.Y; Width = $a.Width; Height = $a.Height }) (980 * $px) (680 * $px) ([Math]::Ceiling($minW * $px)) ([Math]::Ceiling($minH * $px))
    $mode = $script:ChatOverlayModeNative
    $w.Hide()
    # shown now whatever the panel was; hidden to the tray, it goes back there
    $H.Hidden = $false
    $w.Content = $C.Root
    $w.SizeToContent = [System.Windows.SizeToContent]::Manual
    $w.MaxHeight = [double]::PositiveInfinity
    $w.MinWidth = $minW
    $w.MinHeight = $minH
    $w.Width = $at.W / $px
    $w.Height = $at.H / $px
    $w.ResizeMode = [System.Windows.ResizeMode]::CanResizeWithGrip
    $w.Opacity = 1
    $w.Title = 'chatq console'
    $w.Topmost = $false
    # shown activated only for real: the seam's tests never take the keyboard
    $w.ShowActivated = $Activate -and -not $script:ChatConsoleFrontSeam
    $mode::ApplyInteractiveStyle($H.Hwnd)
    [ChatOverlayNative]::Place($H.Hwnd, $at.X, $at.Y, $at.W, $at.H)
    $w.Show()
    # WPF sets styles of its own again as it shows a window
    $mode::ApplyInteractiveStyle($H.Hwnd)
    $mode::DropTopmost($H.Hwnd)
    [ChatOverlayNative]::Place($H.Hwnd, $at.X, $at.Y, $at.W, $at.H)
    Update-ChatOverlayMenu $H
    # a fresh look at what the limit cut off, and at the chats
    $H.Ctx.CutAt = [datetime]::MinValue
    $C.Sigs = @{}
    Update-ChatConsole $H
    if ($Activate) { & $front }
}

function Exit-ChatOverlayConsoleMode {
    <#
    Back to the panel: the draft and the console's size saved, then the
    window passive, click-through while locked and on top again, exactly
    where it was, as wide, with the rows and fold it had - hidden, if it
    was in the tray. A width a reload set meanwhile keeps the right edge,
    as the panel's width always does, never past the left of its screen,
    and where that leaves the panel is kept for the next start.
    #>
    param($H)
    if (-not $H -or $H.Mode -ne 'console') { return }
    $w = $H.Win
    $P = $H.PanelWas
    Save-ChatConsoleDraft $H
    $H.Mode = 'panel'
    if ($w.WindowState -ne [System.Windows.WindowState]::Normal) { $w.WindowState = [System.Windows.WindowState]::Normal }
    $w.Hide()
    $w.Content = $H.Frame
    $w.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $w.ClearValue([System.Windows.FrameworkElement]::HeightProperty)
    $w.SizeToContent = [System.Windows.SizeToContent]::Height
    $w.MinWidth = $P.MinWidth
    $w.MinHeight = $P.MinHeight
    $w.Width = $P.Width
    $w.MaxHeight = $P.MaxHeight
    $w.Opacity = $P.Opacity
    $w.Title = $P.Title
    $w.Topmost = $true
    $w.ShowActivated = $false
    $H.Ctx.Config.maxRows = $P.Rows
    $H.Collapsed = $P.Collapsed
    [ChatOverlayNative]::ApplyExStyle($H.Hwnd, $H.Locked)
    [ChatOverlayNative]::MoveTo($H.Hwnd, $P.Rect[0], $P.Rect[1])
    $H.ViewKey = $null
    # Its width in pixels as the panel's scale makes it: hidden, WPF's own
    # may still be that of a screen the console was dragged to.
    $wide = [int][Math]::Round($P.Width * $P.Rect[2] / [Math]::Max(1.0, [double]$P.WidthWas))
    if ($P.Hidden) {
        $H.Hidden = $true
        if ($H.Snap) { Update-ChatOverlayView $H $H.Snap }
    }
    else {
        # Shown first, then drawn: back on the panel's screen, WPF has that
        # screen's scale for the height cap, not the one of a screen the
        # console was dragged to.
        $w.Show()
        # WPF sets WS_EX_APPWINDOW again as it shows a window
        [ChatOverlayNative]::ApplyExStyle($H.Hwnd, $H.Locked)
        if ($H.Snap) { Update-ChatOverlayView $H $H.Snap }
        $now = [ChatOverlayNative]::GetRect($H.Hwnd)
        if ($now) { $wide = $now[2] }
    }
    # the right edge where the panel had it, the left never off its screen
    $a = Get-ChatOverlayWorkArea $P.Rect
    $x = [int][Math]::Max([double]$a.X, $P.Rect[0] + $P.Rect[2] - $wide)
    [ChatOverlayNative]::MoveTo($H.Hwnd, $x, $P.Rect[1])
    if (-not $P.Hidden) { [ChatOverlayNative]::KeepTopmost($H.Hwnd) }
    # kept, where it is not where the next start would put it
    if ($H.State -and ($H.State.x -ne $x -or $H.State.y -ne $P.Rect[1])) { Save-ChatOverlayPlace $H }
    # an unlocked panel locks itself 2 minutes from now, not from before
    if (-not $H.Locked) { $H.LeftAt = Get-Date }
    Update-ChatOverlayMenu $H
}

function Set-ChatOverlayTrayColor {
    # the tray dot takes the most urgent state's colour; the old icon handle
    # is destroyed, or every change would leak one
    param($H, [string]$Hex)
    if (-not $H.Tray -or $H.IconColor -eq $Hex) { return }
    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $br = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($Hex))
    $g.FillEllipse($br, 5, 5, 22, 22)
    $br.Dispose()
    $g.Dispose()
    $icon = $bmp.GetHicon()
    $bmp.Dispose()
    $H.Tray.Icon = [System.Drawing.Icon]::FromHandle($icon)
    if ($H.IconHandle -ne [IntPtr]::Zero) { [void][ChatOverlayNative]::DestroyIcon($H.IconHandle) }
    $H.IconHandle = $icon
    $H.IconColor = $Hex
}

function Update-ChatOverlayTray {
    param($H, $Snap)
    if (-not $H.Tray) { return }
    $c = $Snap.counts
    $cut = if ($c -and $c.PSObject.Properties['cutOff']) { [int]$c.cutOff } else { 0 }
    $name = if ([int]$c.waiting + [int]$c.needsInput) { 'waiting' } elseif ($cut) { 'cutoff' } elseif ($c.busy) { 'busy' } elseif ($c.running) { 'running' } else { 'idle' }
    Set-ChatOverlayTrayColor $H $script:ChatOverlayColors[$name]
    $tip = Format-ChatOverlayTooltip $Snap
    if ($H.Tray.Text -ne $tip) { $H.Tray.Text = $tip }
}

function Update-ChatOverlayMenu {
    param($H)
    if (-not $H.Menu.Lock) { return }
    $H.Menu.Lock.Text = if ($H.Locked) { 'Unlock to move' } else { 'Lock' }
    $H.Menu.Hide.Text = if ($H.Hidden) { 'Show' } else { 'Hide' }
    $H.Menu.Fold.Text = if ($H.Collapsed) { 'Expand' } else { 'Collapse to one line' }
    $H.Menu.Hotkey.Text = if ($H.Hotkey) { "hotkey  $($H.HotkeyText)" } elseif ($H.HotkeyText -and $H.HotkeyText -ne 'none') { "hotkey  $($H.HotkeyText) (taken)" } else { 'no hotkey' }
    # auto-continue's item, checked while the switch is on, as the panel
    # has config.json (the settings box and a reload keep that current)
    if ($H.Menu.Auto) { $H.Menu.Auto.Checked = [string]$H.Ctx.Config.autoContinue -eq 'on' }
}

function Update-ChatOverlayAsk {
    <#
    After each pass, what the collector found about the chats the limit cut
    off ($H.Ctx.Ask): the tray's two answers put in step, a new ask said in
    a balloon once, an answer's outcome (AskSaid) said the same way, and a
    watcher an answer asked for followed until it is up.
    #>
    param($H)
    if (-not $H -or -not $H.Ctx) { return }
    $ask = $H.Ctx.Ask
    # Not while the menu is open: its items and their keys stay what it
    # showed, so a click never answers for a chat that joined meanwhile.
    $menuOpen = $H.Tray -and $H.Tray.ContextMenuStrip -and $H.Tray.ContextMenuStrip.Visible
    if ($H.Menu.AskGo -and -not $menuOpen) {
        $on = [bool]$ask
        # Available, not Visible: an item's Visible reads false whenever its
        # menu is closed - which is always, here - so once shown, a check of
        # Visible never hid them again. Available is what Visible sets.
        foreach ($i in $H.Menu.AskGo, $H.Menu.AskLeave, $H.Menu.AskSep) { if ($i.Available -ne $on) { $i.Available = $on } }
        if ($on) {
            $n = [int]$ask.Count
            $H.Menu.AskGo.Text = "Continue $n cut-off chat$(if ($n -ne 1) { 's' })"
            $H.Menu.AskGo.ToolTipText = (@(@($ask.Items) | Select-Object -First 10 | ForEach-Object { Format-ChatTitle ([string]$_.Title) 60 }) -join "`n")
        }
        # @() around the if: an empty array out of a branch would be $null
        $H.AskMenuKeys = @(if ($on) { $ask.Keys })
    }
    $news = $H.Ctx.AskNews
    if ($news) {
        $H.Ctx.AskNews = $null
        $a = $news.Ask
        $n = [int]$a.Count
        $at = Format-ChatOverlayAskAt $a.ResetsAt
        $names = @(@($a.Items) | Select-Object -First 3 | ForEach-Object { Format-ChatTitle ([string]$_.Title) 40 })
        $list = $names -join ', '
        if ($n -gt 3) { $list += " and $($n - 3) more" }
        $title = if ($at) { "chatq - limit over at $at" } else { 'chatq - limit over' }
        Show-ChatOverlayBalloon $H "$n chat$(if ($n -ne 1) { 's' }) it cut off can continue: $list. Click to see them." -Title $title -Ms 10000 -Kind ask -Keys @($a.Keys)
    }
    if ($H.Ctx.AskSaid) {
        $said = [string]$H.Ctx.AskSaid
        $H.Ctx.AskSaid = $null
        Show-ChatOverlayBalloon $H $said
    }
    if ($H.AskRequest) {
        # Ctx.Jobs holds each job with its first line: the state is the job's
        $queued = [bool](@($H.Ctx.Jobs | Where-Object { $_ -and $_.Job -and $_.Job.state -eq 'queued' }).Count)
        switch (Test-ChatqWatcherRequest $H.AskRequest $queued) {
            'up' { $H.AskRequest = $null }
            'none' { $H.AskRequest = $null }
            'failed' { $H.AskRequest = $null; Show-ChatOverlayBalloon $H 'the watcher did not start - chatqrun -Foreground shows why' }
        }
    }
}

function Invoke-ChatOverlayAskAnswer {
    <#
    An answer to the ask about the chats the limit cut off - from the chip,
    the tray or the console: continue or leave the chats of -Keys, those it
    showed (Complete-ChatqResetAsk). Held while a loop of its own runs (the
    folder picker, a drag), and run once it ends (Invoke-ChatOverlayHeldVerbs).
    An ask that changed meanwhile acts on nothing: the panel shows it as it
    is now instead. Otherwise a pass now, so the banner and the tray's items
    go, and what was queued shows at once.
    #>
    param($H, [string]$Answer, [string[]]$Keys)
    if (-not $H -or $H.ShuttingDown) { return }
    if (($H.Con -and $H.Con.Modal) -or $H.Dragging -or $H.GripDrag -or $H.SizeDrag) {
        $H.AskHeld = @{ Answer = $Answer; Keys = @($Keys) }
        return
    }
    try {
        Hide-ChatOverlayChip $H
        $r = Complete-ChatqResetAsk -Ctx $H.Ctx -Answer $Answer -Keys @($Keys) -Source overlay
        if ($r -and $r.Stale) {
            # the console shows the list as it is on its next redraw; the
            # panel is brought up, unfolded, to show the ask as it is now
            if ($H.Mode -ne 'console') {
                Invoke-ChatOverlayVerb 'show'
                if ($H.Collapsed) { Invoke-ChatOverlayVerb 'expand' }
            }
            return
        }
        if ($r -and $r.Request) {
            $H.AskRequest = $r.Request
            if ($H.Con) { $H.Con.Request = $r.Request }
        }
        $H.ViewKey = $null
        Update-ChatOverlayView $H (Invoke-ChatOverlayCycle $H.Ctx -Peek)
        Update-ChatOverlayTray $H $H.Snap
        Update-ChatOverlayAsk $H
        if ($H.Mode -eq 'console' -and $H.Con) {
            $H.Con.JobsSig = $null
            $H.Con.Sigs = @{}
            Update-ChatConsole $H
        }
    }
    catch { Write-ChatOverlayLog "ask: $($_.Exception.Message)" }
}

function New-ChatOverlayTrayIcon {
    # A dot in the notification area: left click shows or hides the panel,
    # right click has the rest. It is the one way to reach a panel that clicks
    # go through.
    param($H)
    $ni = [System.Windows.Forms.NotifyIcon]::new()
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    # The answers to the ask about the chats the limit cut off, at the very
    # top, shown only while there is one (Update-ChatOverlayAsk). A click
    # acts on the keys the menu was last put in step with - what it showed.
    $H.Menu.AskGo = $menu.Items.Add('Continue cut-off chats')
    $H.Menu.AskGo.add_Click({ $X = $script:ChatOverlayHost; Invoke-ChatOverlayAskAnswer $X 'continue' @($X.AskMenuKeys) })
    $H.Menu.AskLeave = $menu.Items.Add('Leave them')
    $H.Menu.AskLeave.ToolTipText = 'Leave them as they are - their rows stay orange; Continue all in the console still continues them'
    $H.Menu.AskLeave.add_Click({ $X = $script:ChatOverlayHost; Invoke-ChatOverlayAskAnswer $X 'leave' @($X.AskMenuKeys) })
    $H.Menu.AskSep = [System.Windows.Forms.ToolStripSeparator]::new()
    [void]$menu.Items.Add($H.Menu.AskSep)
    foreach ($i in $H.Menu.AskGo, $H.Menu.AskLeave, $H.Menu.AskSep) { $i.Available = $false }
    $open = $menu.Items.Add('Open console')
    $open.Font = [System.Drawing.Font]::new($open.Font, [System.Drawing.FontStyle]::Bold)
    $open.add_Click({ Invoke-ChatOverlayVerb 'console' })
    # a menu's own items say nothing on hover unless it is told to
    $menu.ShowItemToolTips = $true
    $open.ToolTipText = 'In the panel''s place, grown from its top-right corner - Esc brings the panel back'
    # the setup window chatnotify -Setup opens, reached from here too: Join,
    # answering alerts from the phone, and which alerts go there
    $phone = $menu.Items.Add('Phone alerts...')
    $phone.ToolTipText = 'Join alerts, and answering them from the phone - a window of its own'
    $phone.add_Click({ Invoke-ChatOverlayVerb 'phone' })
    # auto-continue's automatic mode, checked when on; unchecked goes back to
    # the default, ask. Through the verbs, so a console busy with a loop of
    # its own holds it (src/auto-continue.ps1)
    $H.Menu.Auto = $menu.Items.Add('Auto-continue cut-off chats')
    $H.Menu.Auto.ToolTipText = 'A minute after the limit resets, send "continue" to each chat it cut off - unchecked, the panel asks first'
    $H.Menu.Auto.add_Click({ Invoke-ChatOverlayVerb $(if ($script:ChatOverlayHost.Menu.Auto.Checked) { 'auto-ask' } else { 'auto-on' }) })
    $menu.add_Opening({ Update-ChatOverlayMenu $script:ChatOverlayHost })
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $head = $menu.Items.Add("VS-code-chat-manager $script:ChatVersion")
    $head.Enabled = $false
    $H.Menu.Hotkey = $menu.Items.Add('hotkey')
    $H.Menu.Hotkey.Enabled = $false
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $H.Menu.Lock = $menu.Items.Add('Unlock to move')
    $H.Menu.Lock.add_Click({ Invoke-ChatOverlayVerb 'toggle' })
    $H.Menu.Hide = $menu.Items.Add('Hide')
    $H.Menu.Hide.add_Click({ Invoke-ChatOverlayVerb $(if ($script:ChatOverlayHost.Hidden) { 'show' } else { 'hide' }) })
    $H.Menu.Fold = $menu.Items.Add('Collapse to one line')
    $H.Menu.Fold.add_Click({ Invoke-ChatOverlayVerb $(if ($script:ChatOverlayHost.Collapsed) { 'expand' } else { 'collapse' }) })
    $again = $menu.Items.Add('Refresh usage')
    $again.add_Click({ Invoke-ChatOverlayRefresh })
    $corner = $menu.Items.Add('Move to top right')
    $corner.add_Click({ Invoke-ChatOverlayVerb 'reset' })
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $quit = $menu.Items.Add('Quit')
    $quit.add_Click({ Invoke-ChatOverlayVerb 'stop' })
    $ni.ContextMenuStrip = $menu
    $ni.add_MouseClick({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                Invoke-ChatOverlayVerb $(if ($script:ChatOverlayHost.Hidden) { 'show' } else { 'hide' })
            }
        })
    # A click on the balloon about the chats the limit cut off opens the
    # console, which lists them and answers - never the answer itself:
    # people click a balloon to get rid of it.
    $ni.add_BalloonTipClicked({
            $X = $script:ChatOverlayHost
            if (-not $X) { return }
            $kind = $X.BalloonKind
            $X.BalloonKind = $null
            $X.BalloonKeys = @()
            if ($kind -eq 'ask') { Invoke-ChatOverlayVerb 'console' }
        })
    $ni.add_BalloonTipClosed({
            $X = $script:ChatOverlayHost
            if ($X) { $X.BalloonKind = $null; $X.BalloonKeys = @() }
        })
    $ni.Text = 'chatq'
    $H.Tray = $ni
    Set-ChatOverlayTrayColor $H $script:ChatOverlayColors.idle
    $ni.Visible = $true
    Update-ChatOverlayMenu $H
}

function Register-ChatOverlayHotkey {
    # config hotkey (Ctrl+Alt+Shift+O): shows a hidden panel, else locks or
    # unlocks it. Another program holding the same keys gets one balloon.
    param($H)
    $text = [string]$H.Ctx.Config.hotkey
    if ($H.Hotkey -and $H.HotkeyText -eq $text) { return }
    if ($H.Hotkey) { $H.Hotkey.Dispose(); $H.Hotkey = $null }
    $H.HotkeyText = $text
    $k = try { ConvertFrom-ChatOverlayHotkey $text } catch { Write-ChatOverlayLog "hotkey: $($_.Exception.Message)"; $null }
    if ($k) {
        $hk = [ChatOverlayHotkey]::new()
        $hk.add_Pressed({ Invoke-ChatOverlayVerb 'hotkey' })
        if ($hk.Register([uint32]$k.Mods, [uint32]$k.Vk)) { $H.Hotkey = $hk }
        else {
            $hk.Dispose()
            Write-ChatOverlayLog "hotkey $text is taken by another program"
            Show-ChatOverlayBalloon $H "$text is taken by another program - chatoverlay -Hotkey picks another" -Ms 8000 -Icon Info
        }
    }
    Update-ChatOverlayMenu $H
}

function Invoke-ChatOverlayVerb {
    # what a command, the tray menu or the hotkey asked for
    param([string]$Verb)
    $H = $script:ChatOverlayHost
    if (-not $H) { return }
    # A loop of its own - the folder picker's, which the timer's pass runs
    # in too, or the header's DragMove - still takes the hotkeys, the tray
    # and the commands. The window is not switched under it: the picker's
    # owner would come back as the passive panel, a drag would move it on
    # as the other. What goes back to the panel waits for the loop to end
    # (Invoke-ChatOverlayHeldVerbs); the console asked for again is there
    # already, under the picker or the pointer.
    $busy = ($H.Con -and $H.Con.Modal) -or $H.Dragging -or $H.GripDrag -or $H.SizeDrag
    if ($busy -and $H.Mode -eq 'console') {
        if ($Verb -in 'console', 'console-key') { return }
        if ($Verb -in 'stop', 'restart', 'lock', 'unlock', 'toggle', 'hide', 'collapse', 'expand', 'reset', 'hotkey') { $H.Held += @($Verb); return }
    }
    # The console's mode first goes back to the panel for what acts on the
    # panel - each of those assumes the passive window. The panel's own
    # hotkey only goes back; a show asks for what the window does already.
    if ($H.Mode -eq 'console') {
        if ($Verb -eq 'hotkey') { Exit-ChatOverlayConsoleMode $H; return }
        if ($Verb -eq 'show') { $H.PanelWas.Hidden = $false; return }
        if ($Verb -in 'stop', 'restart', 'lock', 'unlock', 'toggle', 'hide', 'collapse', 'expand', 'reset') { Exit-ChatOverlayConsoleMode $H }
    }
    switch ($Verb) {
        'stop' { $H.Stop = $true; Stop-ChatOverlayDispatcher $H }
        'restart' { $H.Restart = $true; Stop-ChatOverlayDispatcher $H }
        'reload' {
            # A slider not yet at rest is written first, then all read back:
            # else the panel kept what the slider set and config.json the
            # shell's, until the rest wrote the slider's over it anyway. The
            # shell's word on that same setting in those 700 ms loses.
            try { $pend = Get-ChatOverlayPending $H; if ($pend.Count) { Set-ChatOverlayConfig $pend } }
            catch { Write-ChatOverlayLog "settings: $($_.Exception.Message)" }
            $H.Ctx.Config = Get-ChatOverlayConfig
            if ($H.Mode -eq 'console') {
                # the console has the window: the panel takes these as it
                # comes back (Exit-ChatOverlayConsoleMode)
                $H.PanelWas.Width = [double]$H.Ctx.Config.width
                $H.PanelWas.Rows = $H.Ctx.Config.maxRows
                $H.PanelWas.Opacity = $H.Ctx.Config.opacity
            }
            else {
                # the width as the settings box sets it: the right edge held
                # under the buttons, and where that leaves the panel kept; the
                # rows as the redraw below draws them
                Set-ChatOverlayWidth $H $H.Ctx.Config.width
                Save-ChatOverlayPlace $H
                $H.Win.Opacity = $H.Ctx.Config.opacity
            }
            Register-ChatOverlayHotkey $H
            Register-ChatConsoleHotkey $H
            $H.ViewKey = $null
            # made anew, so the settings box shows what a shell just set
            $H.ThemeName = $null
            Update-ChatOverlayTheme $H
        }
        'lock' { Set-ChatOverlayLocked $H $true }
        'unlock' { Set-ChatOverlayLocked $H $false }
        'toggle' { Set-ChatOverlayLocked $H (-not $H.Locked) }
        'show' { if ($H.Hidden) { Set-ChatOverlayHidden $H $false } }
        'hide' { if (-not $H.Hidden) { Set-ChatOverlayHidden $H $true } }
        'reset' { Set-ChatOverlayPlacement $H -Corner }
        'hotkey' { if ($H.Hidden) { Set-ChatOverlayHidden $H $false } else { Set-ChatOverlayLocked $H (-not $H.Locked) } }
        'collapse' { if (-not $H.Collapsed) { Set-ChatOverlayCollapsed $H $true } }
        'expand' { if ($H.Collapsed) { Set-ChatOverlayCollapsed $H $false } }
        # The tray's item, the button, chatconsole and a start with it: the
        # console, or the one open brought forward - never closed, as a
        # command waits up to a pass, by when it may be in front anyway.
        'console' { Enter-ChatOverlayConsoleMode $H -Activate }
        # The console hotkey (Register-ChatConsoleHotkey): again while the
        # console has the keyboard, back to the panel; covered or minimized,
        # it comes forward instead.
        'console-key' {
            $active = if ($script:ChatConsoleActiveSeam) { [bool](& $script:ChatConsoleActiveSeam) } else { $H.Win.IsActive }
            if ($H.Mode -eq 'console' -and $active) { Exit-ChatOverlayConsoleMode $H }
            else { Enter-ChatOverlayConsoleMode $H -Activate }
        }
        # The tray's Phone alerts...: the setup window, a process of its own.
        # -NoWait: this is the window's thread, and a wait for the dialog's
        # lock would freeze the panel for seconds. Held like the rest while
        # the console runs a loop of its own - the dialog would come up over
        # a picker that is still waiting for its answer. Whatever goes wrong
        # is the overlay log's, never thrown into the dispatcher.
        'phone' {
            if ($busy -and $H.Mode -eq 'console') { $H.Held += @($Verb); return }
            try { [void](Start-ChatqPhoneSetup -NoWait) } catch { Write-ChatOverlayLog "phone setup: $($_.Exception.Message)" }
        }
        # The tray's Auto-continue cut-off chats: the settings box's Cut off
        # row by another way in. Held like the phone's while the console
        # runs a loop of its own.
        { $_ -in 'auto-on', 'auto-ask', 'auto-off' } {
            if ($busy -and $H.Mode -eq 'console') { $H.Held += @($Verb); return }
            Set-ChatOverlayAutoChoice $H $(switch ($Verb) { 'auto-on' { 'continue' } 'auto-off' { 'leave' } default { 'ask' } })
        }
    }
}

function Invoke-ChatOverlayHeldVerbs {
    # what Invoke-ChatOverlayVerb held while a loop of its own ran, done now
    # it has ended, in the order asked - then an answer to the ask held the
    # same way (Invoke-ChatOverlayAskAnswer)
    param($H)
    if (-not $H) { return }
    if (@($H.Held).Count) {
        $held = @($H.Held)
        $H.Held = @()
        foreach ($v in $held) { Invoke-ChatOverlayVerb $v }
    }
    if ($H.AskHeld -and -not $H.ShuttingDown) {
        $a = $H.AskHeld
        $H.AskHeld = $null
        Invoke-ChatOverlayAskAnswer $H $a.Answer @($a.Keys)
    }
}

function Stop-ChatOverlayDispatcher {
    param($H)
    if ($H.ShuttingDown) { return }
    $H.ShuttingDown = $true
    if ($H.Timer) { $H.Timer.Stop() }
    if ($H.HoverTimer) { $H.HoverTimer.Stop() }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown([System.Windows.Threading.DispatcherPriority]::Background)
}

function Invoke-ChatOverlayTick {
    # The 1 s timer. Every other tick is a collector pass; the ones between
    # only move the countdowns. Every 5th puts the panel back on top and moves
    # it back onto a screen if the screens changed under it.
    $H = $script:ChatOverlayHost
    if (-not $H -or $H.ShuttingDown) { return }
    try {
        $H.Tick++
        # a key just pressed in the console puts the pass off a tick - twice
        # at most - so typing there never waits behind one
        $C = $H.Con
        $typing = $C -and $C.TypedAt -and ((Get-Date) - $C.TypedAt).TotalMilliseconds -lt 400 -and $C.Skips -lt 2
        if ($H.Tick % 2 -eq 0 -and $typing) { $C.Skips++; $H.Tick-- }
        elseif ($H.Tick % 2 -eq 0 -and -not $H.Dragging) {
            if ($C) { $C.Skips = 0 }
            $snap = Invoke-ChatOverlayCycle $H.Ctx
            foreach ($v in @($H.Ctx.Verbs)) { Invoke-ChatOverlayVerb $v }
            if ($H.ShuttingDown) { return }
            Update-ChatOverlayView $H $snap
            Update-ChatOverlayTray $H $snap
            Update-ChatOverlayAsk $H
            # the first continue auto-continue queued, said in the tray
            Show-ChatOverlayAutoQueued $H
            if ($C -and $H.Mode -eq 'console') { Update-ChatConsole $H }
        }
        else {
            Update-ChatOverlayClock $H
            # a dropped file's copy may have finished
            if ($C -and $H.Mode -eq 'console') { Update-ChatConsoleStaging $H }
        }
        # system: follows Windows' own light or dark setting
        if ($H.Tick % 5 -eq 0 -and -not $H.Hidden -and $H.Ctx.Config.theme -eq 'system') { Update-ChatOverlayTheme $H }
        # The console's mode is kept on top of nothing, and is where the user
        # put it: a screen change is looked at once it goes back to the panel.
        if ($H.Tick % 5 -eq 0 -and -not $H.Hidden -and $H.Mode -ne 'console') {
            [ChatOverlayNative]::KeepTopmost($H.Hwnd)
            if ($H.ControlsShown) { [ChatOverlayNative]::KeepTopmost($H.CtlHwnd) }
            # the chip after the panel, so it stays over its row
            if ($H.ChipKey -and $H.ChipHwnd -ne [IntPtr]::Zero) { [ChatOverlayNative]::KeepTopmost($H.ChipHwnd) }
            $sig = (@([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "$($_.WorkingArea)" }) -join ';')
            if ($sig -ne $H.ScreenSig) {
                if ($H.ScreenSig) { Set-ChatOverlayPlacement $H }
                $H.ScreenSig = $sig
            }
        }
        if (-not $H.Locked -and $H.Mode -ne 'console' -and -not $H.PointerIn -and $H.LeftAt -and ((Get-Date) - $H.LeftAt).TotalSeconds -ge 120) {
            Set-ChatOverlayLocked $H $true
        }
        # an open the chip started may have finished
        if ($H.OpenProc) { Update-ChatOverlayOpen $H }
        # An answer held through a drag: only the console's loops end in
        # Invoke-ChatOverlayHeldVerbs, the panel's drags do not.
        if ($H.AskHeld -and -not (($C -and $C.Modal) -or $H.Dragging -or $H.GripDrag -or $H.SizeDrag)) { Invoke-ChatOverlayHeldVerbs $H }
    }
    catch { Write-ChatOverlayLog "tick: $($_.Exception.Message) @ $(($_.ScriptStackTrace -split "`n")[0])" }
}

function Lock-ChatOverlay {
    # A few tries, not one: an overlay handing over to a newer copy lets go
    # of the lock only as it exits.
    for ($try = 1; $try -le 5; $try++) {
        $l = try { [System.IO.File]::Open($script:ChatOverlayLockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch { $null }
        if ($l) { return $l }
        if ($try -lt 5) { Start-Sleep -Milliseconds 200 }
    }
    return $null
}

function Close-ChatOverlayWindow {
    # everything the panel holds from the OS goes back, whatever ended it
    param($H)
    try { if ($H.Timer) { $H.Timer.Stop() } } catch {}
    try { if ($H.HoverTimer) { $H.HoverTimer.Stop() } } catch {}
    try { if ($H.Hotkey) { $H.Hotkey.Dispose(); $H.Hotkey = $null } } catch {}
    try { if ($H.ConHotkey) { $H.ConHotkey.Dispose(); $H.ConHotkey = $null } } catch {}
    # the console's draft kept - its size too, should it be showing - before
    # the window it shows in closes for good below
    $H.ShuttingDown = $true
    try { if ($H.Con) { Save-ChatConsoleDraft $H } } catch {}
    try { if ($H.Tray) { $H.Tray.Visible = $false; $H.Tray.Dispose(); $H.Tray = $null } } catch {}
    try { if ($H.IconHandle -ne [IntPtr]::Zero) { [void][ChatOverlayNative]::DestroyIcon($H.IconHandle); $H.IconHandle = [IntPtr]::Zero } } catch {}
    try { if ($H.CtlWin) { $H.CtlWin.Close() } } catch {}
    try { if ($H.ChipWin) { $H.ChipWin.Close() } } catch {}
    try { if ($H.Win) { $H.Win.Close() } } catch {}
}

function New-ChatOverlayHostState {
    @{
        Tick = 0; Ctx = $null; Win = $null; Hwnd = [IntPtr]::Zero; Frame = $null; Stack = $null
        State = $null; Locked = $true; Hidden = $false; Collapsed = $false; Dragging = $false; PointerIn = $false; LeftAt = $null
        CtlWin = $null; CtlHwnd = [IntPtr]::Zero; CtlStack = $null; CtlSide = 'above'; CtlButtons = @(); CtlLine = $null; GripDrag = $null; Spin = $null; Spinning = $false
        Placed = $false; EnterAt = $null
        Controls = $null; Settings = $null; ControlsShown = $false; SettingsOpen = $false; OverAt = $null
        HoverTimer = $null; PendingOpacity = $null; PendingAt = $null; OpacityText = $null; ThemeName = $null; HideTold = $false
        # the resize handle's drag, and the width and rows sliders moved but
        # not yet saved (Get-ChatOverlayPending)
        CtlSize = $null; SizeDrag = $null; PendingWidth = $null; PendingRows = $null; WidthText = $null; RowsText = $null
        # the box's sliders, and true while Sync-ChatOverlaySettings sets them
        OpacitySlider = $null; WidthSlider = $null; RowsSlider = $null; SettingsSync = $false
        Tray = $null; IconHandle = [IntPtr]::Zero; IconColor = $null; Hotkey = $null; HotkeyText = $null
        Timer = $null; ViewKey = $null; Clocks = [System.Collections.Generic.List[object]]::new(); Snap = $null
        ScreenSig = $null; Stop = $false; Restart = $false; ShuttingDown = $false; Menu = @{}
        Con = $null; ConHotkey = $null; ConHotkeyText = $null
        # panel, or console while the window shows the console
        # (Enter-ChatOverlayConsoleMode), with what the panel was meanwhile
        Mode = 'panel'; PanelWas = $null
        # the verbs held while a loop of its own runs (Invoke-ChatOverlayHeldVerbs)
        Held = @()
        # the open chip: its window, the row it shows for, and the pointer's
        # rest, arming and leaving (Update-ChatOverlayChip); the child an
        # open runs in (Invoke-ChatOverlayOpen)
        ChipWin = $null; ChipHwnd = [IntPtr]::Zero; ChipText = $null; ChipKey = $null; ChipRow = $null; ChipLine = $null; ChipAt = $null
        ChipUnder = $null; ChipUnderAt = $null; ChipOverAt = $null; ChipLastPos = $null; ChipSpent = $null
        ChipArmed = $false; ChipPressed = $false; OpenProc = $null; OpenAt = $null; OpenSid = $null; OpenSessionId = $null
        # what the chip offers for its row (Get-ChatOverlayChipActions), and
        # which of its chips a press began on
        ChipActions = @(); ChipPressedId = $null
        # its row's state text, which an auto-continue chip keeps clear of
        # (Set-ChatOverlayChipPlacement)
        ChipState = $null
        # what a click on the balloon showing means (Show-ChatOverlayBalloon);
        # the ask about the chats the limit cut off: the watcher an answer
        # asked for, an answer held through a loop of its own, and the keys
        # the tray's items were last put in step with (Update-ChatOverlayAsk)
        BalloonKind = $null; BalloonKeys = @(); AskRequest = $null; AskHeld = $null; AskMenuKeys = @()
    }
}

function Start-ChatOverlayHost {
    <#
    The Windows overlay process: a hidden powershell.exe -STA that draws the
    panel and runs the collector on the same thread, every other tick of a
    1 s timer. One thread is enough - a pass costs tens of milliseconds, and
    nobody clicks a window that clicks go through - and it keeps every
    handler on the thread PowerShell runs on, the only one with a runspace.
    -Open console: chatconsole started it, and the console opens with it.
    #>
    param([string]$Open)
    Set-StrictMode -Off
    if (-not $script:ChatqIsWindows) { Start-ChatOverlayMacHost; return }
    New-ChatqDir $script:ChatqData
    $lock = Lock-ChatOverlay
    if (-not $lock) { Write-ChatOverlayLog "overlay $PID found one already running"; return }
    $H = New-ChatOverlayHostState
    $script:ChatOverlayHost = $H
    try {
        Set-Content -LiteralPath $script:ChatOverlayPidPath -Value $PID -Encoding ASCII
        Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
        Write-ChatOverlayLog "overlay $PID started ($script:ChatVersion)"
        Initialize-ChatOverlayNative
        $H.Ctx = New-ChatOverlayContext
        $H.Ctx.WantPhone = $true
        # this host answers the ask about the chats the limit cut off: the
        # collector announces a new one to it (AskNews)
        $H.Ctx.WantAsk = $true
        # and its passes queue continues while the switch is on (src/auto-continue.ps1)
        $H.Ctx.WantAuto = $true
        # reply.listen always: the phone's board reaches a listening watcher
        # after a sign-in with no shell opened (Start-ChatqReplyStanding)
        try { if (Start-ChatqReplyStanding) { $null = Request-ChatqWatcher } } catch {}
        Restore-ChatOverlayUsage $H.Ctx
        $H.State = Read-ChatOverlayState
        $H.Locked = [bool]$H.State.locked
        $H.Collapsed = [bool]$H.State.collapsed
        New-ChatOverlayWindow $H
        Update-ChatOverlayView $H (Invoke-ChatOverlayCycle $H.Ctx)
        if (-not $H.State.hidden) {
            $H.Win.Show()
            [ChatOverlayNative]::ApplyExStyle($H.Hwnd, $H.Locked)
            Set-ChatOverlayPlacement $H
            [ChatOverlayNative]::KeepTopmost($H.Hwnd)
        }
        else { $H.Hidden = $true }
        if (-not $H.Locked) { Set-ChatOverlayLocked $H $false }
        New-ChatOverlayTrayIcon $H
        Update-ChatOverlayTray $H $H.Snap
        # an ask the first pass found, now there is a tray to say it
        Update-ChatOverlayAsk $H
        # once, with the switch on: what auto-continue does, and where it is changed
        Show-ChatOverlayAutoNotice $H
        Register-ChatOverlayHotkey $H
        Register-ChatConsoleHotkey $H
        $d = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
        $d.add_UnhandledException({
                param($s, $e)
                Write-ChatOverlayLog "ui: $($e.Exception.Message)"
                $e.Handled = $true
            })
        $H.Timer = [System.Windows.Threading.DispatcherTimer]::new()
        $H.Timer.Interval = [TimeSpan]::FromSeconds(1)
        $H.Timer.add_Tick({ Invoke-ChatOverlayTick })
        $H.Timer.Start()
        $H.HoverTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $H.HoverTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $H.HoverTimer.add_Tick({ Update-ChatOverlayHover })
        $H.HoverTimer.Start()
        # what came in while this was starting - a -Stop right after the start,
        # chatinstall's restart - was taken by the first pass above
        foreach ($v in @($H.Ctx.Verbs)) { Invoke-ChatOverlayVerb $v }
        if ($Open -eq 'console') { Enter-ChatOverlayConsoleMode $H -Activate }
        [System.Windows.Threading.Dispatcher]::Run()
    }
    catch { Write-ChatOverlayLog "overlay failed: $($_.Exception.Message) @ $(($_.ScriptStackTrace -split "`n")[0])" }
    finally {
        Close-ChatOverlayWindow $H
        try { $lock.Dispose() } catch {}
        Remove-Item -LiteralPath $script:ChatOverlayPidPath -Force -EA SilentlyContinue
        Write-ChatOverlayLog "overlay $PID stopped$(if ($H.Restart) { ' - restarting on the new copy' })"
    }
    # last, once the lock is released: the new copy takes it on its way up
    if ($H.Restart) { [void](Start-ChatOverlayProcess) }
}

#endregion
