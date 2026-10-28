using System.Diagnostics;
using Microsoft.UI.Xaml;

namespace ScreenTimeoutToast;

public partial class App : Application
{
    private MainWindow? _window;
    private ToastPipeServer? _pipeServer;
    private Mutex? _serverMutex;
    private F12Hotkey? _hotkey;
    private bool _previewHotkey;
    private long _lastTriggerTime;
    private int _launchInProgress;
    private int _previewTriggerCount;
    private string? _hotkeyDiagnostics;
    private double _lastDispatchMs;
    private int _acceptedTriggers;
    private DateTimeOffset? _lastTriggerUtc;
    private double? _lastActionMs;

    public App()
    {
        _ = ToastDiagnostics.Lifetime;
        UnhandledException += OnUnhandledException;
        InitializeComponent();
        RequestedTheme = ApplicationTheme.Light;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var commandLine = Environment.GetCommandLineArgs();
        var diagnosticsIndex = Array.IndexOf(commandLine, "--diagnostics");
        _hotkeyDiagnostics = diagnosticsIndex >= 0 && diagnosticsIndex + 1 < commandLine.Length
            ? commandLine[diagnosticsIndex + 1]
            : null;
        if (commandLine.Contains("--hotkey-self-test"))
        {
            ToastDiagnostics.WriteSuccess(_hotkeyDiagnostics, F12KeyState.SelfTest());
            Exit();
            return;
        }

        _previewHotkey = commandLine.Contains("--hotkey-preview");
        if (commandLine.Any(value => string.Equals(value, "--server", StringComparison.OrdinalIgnoreCase)))
        {
            StartServer();
            return;
        }

        ToastOptions options;
        try
        {
            options = ToastOptions.Parse(commandLine);
        }
        catch (Exception exception)
        {
            ToastDiagnostics.WriteFailure(Environment.GetCommandLineArgs(), exception);
            Exit();
            return;
        }

        _window = new MainWindow(options);
        _window.Closed += (_, _) =>
        {
            _window = null;
            Exit();
        };
        _window.ShowWithoutActivation();
    }

    private void StartServer()
    {
        _serverMutex = new Mutex(true, @"Local\ScreenTimeoutToastHost", out var createdNew);
        if (!createdNew)
        {
            _serverMutex.Dispose();
            _serverMutex = null;
            Exit();
            return;
        }

        _window = new MainWindow(ToastOptions.Default, closeOnDismiss: false);
        _window.Prime();
        _pipeServer = new ToastPipeServer(options =>
        {
            _window.DispatcherQueue.TryEnqueue(() => _window.ShowToast(options));
        });
        _ = _pipeServer.RunAsync();
        try
        {
            // Keep all UI and process work outside the keyboard hook callback.
            _hotkey = new F12Hotkey(
                () =>
                {
                    var received = Stopwatch.GetTimestamp();
                    _window.DispatcherQueue.TryEnqueue(() =>
                    {
                        _lastDispatchMs = Stopwatch.GetElapsedTime(received).TotalMilliseconds;
                        HandleF12();
                    });
                },
                allowInjected: _previewHotkey);
            AppDomain.CurrentDomain.ProcessExit += (_, _) => _hotkey?.Dispose();
            WriteHotkeyStatus(true, null);
        }
        catch (Exception exception)
        {
            WriteHotkeyStatus(false, exception.Message);
        }
    }

    private void HandleF12()
    {
        var now = Environment.TickCount64;
        if (_lastTriggerTime != 0 && now - _lastTriggerTime < 600)
        {
            return;
        }
        _lastTriggerTime = now;

        if (_previewHotkey)
        {
            _previewTriggerCount++;
            _window!.ShowToast(ToastOptions.Default);
            WriteHotkeyStatus(true, null);
            return;
        }

        if (Interlocked.Exchange(ref _launchInProgress, 1) != 0)
        {
            return;
        }

        _acceptedTriggers++;
        _lastTriggerUtc = DateTimeOffset.UtcNow;
        _lastActionMs = null;

        _window!.ShowToast(new ToastOptions(
            "\u6b63\u5728\u5207\u6362\u5173\u5c4f\u65f6\u95f4", "\u6b63\u5728\u5e94\u7528\u7535\u6e90\u548c\u58f0\u97f3\u8bbe\u7f6e", "", 15, false, null));

        _ = Task.Run(async () =>
        {
            var action = Stopwatch.StartNew();
            try
            {
                var launcher = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "Toggle-PluggedIn-ScreenTimeout.ps1"));
                var info = new ProcessStartInfo
                {
                    FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    WorkingDirectory = Path.GetDirectoryName(launcher)!
                };
                foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Sta", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", launcher })
                    info.ArgumentList.Add(argument);
                using var process = Process.Start(info) ?? throw new InvalidOperationException("PowerShell did not start.");
                await process.WaitForExitAsync();
            }
            catch (Exception exception)
            {
                _window!.DispatcherQueue.TryEnqueue(() => _window.ShowToast(new ToastOptions(
                    "\u65e0\u6cd5\u542f\u52a8\u5173\u5c4f\u5207\u6362", "F12", exception.Message, 8, true, null)));
            }
            finally
            {
                Interlocked.Exchange(ref _launchInProgress, 0);
                _window!.DispatcherQueue.TryEnqueue(() =>
                {
                    _lastActionMs = action.Elapsed.TotalMilliseconds;
                    WriteHotkeyStatus(true, null);
                });
            }
        });
    }

    private void WriteHotkeyStatus(bool enabled, string? error)
    {
        var path = _hotkeyDiagnostics ?? Path.Combine(AppContext.BaseDirectory, "hotkey-status.json");
        ToastDiagnostics.WriteSuccess(path, new
        {
            Enabled = enabled,
            Key = "F12",
            Mode = _previewHotkey ? "PreviewOnly" : "Toggle",
            ProcessId = Environment.ProcessId,
            PreviewTriggerCount = _previewTriggerCount,
            DispatchMilliseconds = _lastDispatchMs,
            HookRenewals = _hotkey?.Renewals ?? 0,
            ListenerThread = "Dedicated",
            AcceptedTriggers = _acceptedTriggers,
            LastTriggerUtc = _lastTriggerUtc,
            LastActionMilliseconds = _lastActionMs,
            Error = error
        });
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        ToastDiagnostics.WriteFailure(Environment.GetCommandLineArgs(), args.Exception);
    }
}
