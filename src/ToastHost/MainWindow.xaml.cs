using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Text;
using Windows.Graphics;
using Windows.UI;
using Windows.UI.ViewManagement;
using WinRT.Interop;

namespace ScreenTimeoutToast;

public sealed class MainWindow : Window
{
    private const int CardWidthDip = 400;
    private const int CardHeightDip = 96;
    private const int ScreenMarginDip = 16;

    private const int GwlExStyle = -20;
    private const long WsExToolWindow = 0x00000080L;
    private const long WsExNoActivate = 0x08000000L;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private const int SwShownoactivate = 4;
    private const uint MonitorDefaultToNearest = 2;
    private const int MonitorDpiTypeEffective = 0;
    private const int DwmWindowCornerPreference = 33;
    private const int DwmWindowCornerDoNotRound = 1;
    private const int DwmBorderColor = 34;
    private const uint DwmColorNone = 0xFFFFFFFE;

    private static readonly nint HwndTopmost = new(-1);

    private ToastOptions _options;
    private readonly bool _closeOnDismiss;
    private readonly nint _hwnd;
    private readonly UISettings _uiSettings = new();
    private readonly DispatcherQueueTimer _dismissTimer;
    private readonly Stopwatch _showStopwatch = new();

    private Grid WindowRoot = null!;
    private Grid ToastSurface = null!;
    private Border PaperSurface = null!;
    private FontIcon StateIcon = null!;
    private TextBlock TitleText = null!;
    private TextBlock Line1Text = null!;
    private TextBlock Line2Text = null!;
    private Border CloseButton = null!;

    private Storyboard? _entranceStoryboard;
    private Storyboard? _exitStoryboard;
    private bool _closing;
    private bool _entranceCompleted;
    private bool _isLoaded;
    private bool _pendingShow;
    private uint _dpi = 96;

    internal MainWindow(ToastOptions options, bool closeOnDismiss = true)
    {
        _options = options;
        _closeOnDismiss = closeOnDismiss;
        BuildVisualTree();

        _hwnd = WindowNative.GetWindowHandle(this);
        ApplyOptions();
        ConfigureWindow();

        _dismissTimer = DispatcherQueue.CreateTimer();
        _dismissTimer.IsRepeating = false;
        _dismissTimer.Tick += (_, _) => StartExitAnimation();

        CloseButton.Tapped += (_, _) => StartExitAnimation();
        Closed += OnClosed;
        WindowRoot.Loaded += OnLoaded;
    }

    private void BuildVisualTree()
    {
        WindowRoot = new Grid
        {
            Width = CardWidthDip,
            Height = CardHeightDip,
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0))
        };

        ToastSurface = new Grid
        {
            Width = CardWidthDip,
            Height = CardHeightDip,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Opacity = 0
        };

        PaperSurface = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(255, 226, 226, 230)),
            BorderThickness = new Thickness(1),
            IsHitTestVisible = false
        };
        ToastSurface.Children.Add(PaperSurface);

        var contentGrid = new Grid { Padding = new Thickness(22, 14, 16, 14) };
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(32) });
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });

        StateIcon = new FontIcon
        {
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 30,
            Glyph = "\uE7F4",
            Foreground = new SolidColorBrush(Color.FromArgb(255, 0, 20, 255)),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(StateIcon, 0);
        contentGrid.Children.Add(StateIcon);

        TitleText = new TextBlock
        {
            FontFamily = new FontFamily("Microsoft YaHei UI"),
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            CharacterSpacing = 90,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        Line1Text = CreateBodyTextBlock();
        Line2Text = CreateBodyTextBlock();

        var textStack = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center,
            Spacing = 2
        };
        textStack.Children.Add(TitleText);
        textStack.Children.Add(Line1Text);
        textStack.Children.Add(Line2Text);
        Grid.SetColumn(textStack, 2);
        contentGrid.Children.Add(textStack);

        var closeIcon = new FontIcon
        {
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 10,
            Glyph = "\uE711",
            Foreground = new SolidColorBrush(Color.FromArgb(190, 0, 20, 255)),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        CloseButton = new Border
        {
            Width = 24,
            Height = 24,
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Child = closeIcon
        };
        CloseButton.PointerEntered += (_, _) =>
            CloseButton.Background = new SolidColorBrush(Color.FromArgb(18, 0, 20, 255));
        CloseButton.PointerExited += (_, _) =>
            CloseButton.Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(CloseButton, "关闭");
        Grid.SetColumn(CloseButton, 3);
        contentGrid.Children.Add(CloseButton);

        ToastSurface.Children.Add(contentGrid);
        WindowRoot.Children.Add(ToastSurface);
        Content = WindowRoot;
    }

    private static TextBlock CreateBodyTextBlock() => new()
    {
        FontFamily = new FontFamily("Microsoft YaHei UI"),
        FontSize = 12.5,
        FontWeight = FontWeights.Normal,
        CharacterSpacing = 20,
        LineHeight = 18,
        TextTrimming = TextTrimming.CharacterEllipsis
    };

    public void ShowWithoutActivation()
    {
        ShowToast(_options);
    }

    internal void Prime()
    {
        SetWindowPos(_hwnd, HwndTopmost, -32000, -32000, 0, 0, SwpNoActivate | 0x0001);
        Activate();
        ShowWindow(_hwnd, 0);
    }

    internal void ShowToast(ToastOptions options)
    {
        _options = options;
        ApplyOptions();
        if (_entranceCompleted && !_closing)
        {
            // Replace pending text in place, without fading the whole card out and in again.
            _entranceCompleted = false;
            _showStopwatch.Restart();
            CompleteEntrance();
            return;
        }
        _pendingShow = true;

        if (!_isLoaded)
        {
            Activate();
            return;
        }

        BeginShow();
    }

    private void ApplyOptions()
    {
        TitleText.Text = _options.Title;
        Line1Text.Text = _options.Line1;
        Line2Text.Text = _options.Line2;
        _dismissTimer?.Stop();
        if (_dismissTimer is not null)
        {
            _dismissTimer.Interval = TimeSpan.FromSeconds(_options.Seconds);
        }

        var accent = _options.IsError
            ? Color.FromArgb(255, 205, 28, 48)
            : Color.FromArgb(255, 0, 20, 255);
        var secondary = _options.IsError
            ? Color.FromArgb(220, 150, 24, 40)
            : Color.FromArgb(210, 0, 12, 190);
        TitleText.Foreground = new SolidColorBrush(accent);
        Line1Text.Foreground = new SolidColorBrush(secondary);
        Line2Text.Foreground = new SolidColorBrush(secondary);
        PaperSurface.BorderBrush = new SolidColorBrush(_options.IsError
            ? Color.FromArgb(255, 238, 197, 202)
            : Color.FromArgb(255, 226, 226, 230));
        StateIcon.Glyph = _options.IsError ? "\uE783" : "\uE7F4";
        StateIcon.Foreground = new SolidColorBrush(accent);
    }

    private void ConfigureWindow()
    {
        Title = "Screen Timeout Toggle Notification";
        var appWindow = AppWindow;
        var capturePreview = _closeOnDismiss && Environment.GetCommandLineArgs().Contains("--capture-preview");
        appWindow.IsShownInSwitchers = capturePreview;

        if (appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMinimizable = false;
            presenter.IsMaximizable = false;
            presenter.SetBorderAndTitleBar(false, false);
        }

        var extendedStyle = GetWindowLongPointer(_hwnd, GwlExStyle).ToInt64();
        SetWindowLongPointer(_hwnd, GwlExStyle, new nint(extendedStyle | (capturePreview ? 0 : WsExToolWindow) | WsExNoActivate));

        var cornerPreference = DwmWindowCornerDoNotRound;
        DwmSetWindowAttribute(_hwnd, DwmWindowCornerPreference, ref cornerPreference, sizeof(int));
        var borderColor = DwmColorNone;
        DwmSetWindowAttribute(_hwnd, DwmBorderColor, ref borderColor, sizeof(uint));

        PositionOnCursorMonitor();
    }

    private void PositionOnCursorMonitor()
    {
        if (!GetCursorPos(out var cursor))
        {
            return;
        }

        var monitor = MonitorFromPoint(cursor, MonitorDefaultToNearest);
        var monitorInfo = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref monitorInfo))
        {
            return;
        }

        if (GetDpiForMonitor(monitor, MonitorDpiTypeEffective, out var dpiX, out _) == 0 && dpiX > 0)
        {
            _dpi = dpiX;
        }

        var scale = _dpi / 96.0;
        var width = (int)Math.Round(CardWidthDip * scale);
        var height = (int)Math.Round(CardHeightDip * scale);
        var margin = (int)Math.Round(ScreenMarginDip * scale);
        var x = monitorInfo.WorkArea.Right - width - margin;
        var y = monitorInfo.WorkArea.Bottom - height - margin;

        SetWindowPos(_hwnd, HwndTopmost, x, y, width, height, SwpNoActivate);
    }

    private void OnLoaded(object sender, RoutedEventArgs args)
    {
        _isLoaded = true;
        if (_pendingShow)
        {
            BeginShow();
        }
        else
        {
            ShowWindow(_hwnd, 0);
        }
    }

    private void BeginShow()
    {
        _pendingShow = false;
        _closing = false;
        _entranceCompleted = false;
        _showStopwatch.Restart();
        _dismissTimer.Stop();
        _entranceStoryboard?.Stop();
        _exitStoryboard?.Stop();
        ToastSurface.Opacity = 0;

        PositionOnCursorMonitor();
        ShowWindow(_hwnd, SwShownoactivate);
        SetWindowPos(_hwnd, HwndTopmost, 0, 0, 0, 0, SwpNoActivate | 0x0001 | 0x0002 | SwpShowWindow);
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, StartEntranceAnimation);
    }

    private void StartEntranceAnimation()
    {
        if (_closing)
        {
            return;
        }

        if (!_uiSettings.AnimationsEnabled)
        {
            ToastSurface.Opacity = 1;
            CompleteEntrance();
            return;
        }

        var opacity = new DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = new Duration(TimeSpan.FromMilliseconds(160)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        Storyboard.SetTarget(opacity, ToastSurface);
        Storyboard.SetTargetProperty(opacity, nameof(UIElement.Opacity));

        _entranceStoryboard = new Storyboard();
        _entranceStoryboard.Children.Add(opacity);
        _entranceStoryboard.Completed += (_, _) => CompleteEntrance();
        _entranceStoryboard.Begin();
    }

    private void CompleteEntrance()
    {
        if (_entranceCompleted || _closing)
        {
            return;
        }

        _entranceCompleted = true;
        _dismissTimer.Start();
        ToastDiagnostics.WriteSuccess(_options.DiagnosticsPath, new
        {
            Success = true,
            Renderer = "WinUI3.HermesMinimal",
            Surface = "SolidWhite",
            CornerRadiusDip = 0,
            Dpi = _dpi,
            ShowToEntranceCompleteMilliseconds = _showStopwatch.Elapsed.TotalMilliseconds,
            ProcessLifetimeMilliseconds = ToastDiagnostics.Lifetime.Elapsed.TotalMilliseconds,
            AnimationsEnabled = _uiSettings.AnimationsEnabled
        });
    }

    private void StartExitAnimation()
    {
        if (_closing)
        {
            return;
        }

        _closing = true;
        _dismissTimer.Stop();

        if (!_uiSettings.AnimationsEnabled)
        {
            FinishDismiss();
            return;
        }

        var opacity = new DoubleAnimation
        {
            From = ToastSurface.Opacity,
            To = 0,
            Duration = new Duration(TimeSpan.FromMilliseconds(120)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseIn }
        };
        Storyboard.SetTarget(opacity, ToastSurface);
        Storyboard.SetTargetProperty(opacity, nameof(UIElement.Opacity));

        _exitStoryboard = new Storyboard();
        _exitStoryboard.Children.Add(opacity);
        _exitStoryboard.Completed += (_, _) => FinishDismiss();
        _exitStoryboard.Begin();
    }

    private void FinishDismiss()
    {
        if (_closeOnDismiss)
        {
            Close();
            return;
        }

        ShowWindow(_hwnd, 0);
        _entranceStoryboard?.Stop();
        _exitStoryboard?.Stop();
        ToastSurface.Opacity = 0;
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _dismissTimer.Stop();
        _entranceStoryboard?.Stop();
        _exitStoryboard?.Stop();
    }

    private static nint GetWindowLongPointer(nint hwnd, int index) =>
        nint.Size == 8 ? GetWindowLongPtr64(hwnd, index) : new nint(GetWindowLong32(hwnd, index));

    private static nint SetWindowLongPointer(nint hwnd, int index, nint value) =>
        nint.Size == 8 ? SetWindowLongPtr64(hwnd, index, value) : new nint(SetWindowLong32(hwnd, index, value.ToInt32()));

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor;
        public NativeRect WorkArea;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll")]
    private static extern nint MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(nint monitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(nint hwnd, nint insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(nint hwnd, int command);

    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    private static extern int GetWindowLong32(nint hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern nint GetWindowLongPtr64(nint hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
    private static extern int SetWindowLong32(nint hwnd, int index, int value);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern nint SetWindowLongPtr64(nint hwnd, int index, nint value);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref uint value, int size);

}
