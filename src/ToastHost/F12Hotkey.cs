using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ScreenTimeoutToast;

internal sealed class F12KeyState
{
    private bool _down;
    private bool _captured;

    internal void Reset() { _down = false; _captured = false; }

    internal (bool Suppress, bool Trigger) Process(bool down, bool modified)
    {
        if (!down)
        {
            var suppress = _captured;
            _down = false;
            _captured = false;
            return (suppress, false);
        }

        if (_down)
        {
            return (_captured, false);
        }

        _down = true;
        _captured = !modified;
        return (_captured, _captured);
    }

    internal static object SelfTest()
    {
        var state = new F12KeyState();
        void Check(bool down, bool modified, bool suppress, bool trigger)
        {
            if (state.Process(down, modified) != (suppress, trigger))
            {
                throw new InvalidOperationException("F12 key state test failed.");
            }
        }

        Check(true, false, true, true);
        Check(true, false, true, false);
        Check(true, true, true, false);
        Check(false, true, true, false);
        Check(true, true, false, false);
        Check(true, false, false, false);
        Check(false, false, false, false);
        Check(true, false, true, true);
        Check(false, false, true, false);
        Check(true, false, true, true);
        state.Reset();
        Check(true, false, true, true);
        Check(false, false, true, false);
        return new { Success = true, Cases = 12, LongPressTriggersOnce = true, ModifiedF12PassesThrough = true, ResetRecoversLostRelease = true };
    }
}

internal sealed class F12Hotkey : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const uint VkF12 = 0x7B;
    private readonly HookProc _callback;
    private readonly Action _trigger;
    private readonly bool _allowInjected;
    private readonly F12KeyState _state = new();
    private nint _hook;
    private readonly Thread _thread;
    private readonly ManualResetEventSlim _ready = new();
    private Exception? _startupError;
    private uint _threadId;
    private long _lastF12Event;
    private long _lastInstall;
    private int _renewals;
    internal int Renewals => Volatile.Read(ref _renewals);

    internal F12Hotkey(Action trigger, bool allowInjected = false)
    {
        _trigger = trigger;
        _allowInjected = allowInjected;
        _callback = OnKeyboard;
        _thread = new Thread(Run) { IsBackground = true, Name = "F12 input" };
        _thread.Start();
        _ready.Wait();
        if (_startupError is not null) throw new InvalidOperationException("F12 listener failed.", _startupError);
    }

    private void Install()
    {
        var replacement = SetWindowsHookEx(WhKeyboardLl, _callback, GetModuleHandle(null), 0);
        if (replacement == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        var previous = _hook;
        _hook = replacement;
        if (previous != 0) UnhookWindowsHookEx(previous);
        _lastInstall = Environment.TickCount64;
    }

    private void Run()
    {
        nuint timer = 0;
        try
        {
            _threadId = GetCurrentThreadId();
            PeekMessage(out _, 0, 0, 0, 0);
            Install();
            timer = SetTimer(0, 0, 250, 0);
            if (timer == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            _ready.Set();
            while (GetMessage(out var message, 0, 0, 0) > 0)
            {
                if (message.Id != 0x113) continue;
                var now = Environment.TickCount64;
                // Do not reset during key-repeat. Recover a release missed across desktop/session changes.
                if (now - _lastF12Event < 2000 || IsDown((int)VkF12)) continue;
                _state.Reset();
                // Windows can silently remove timed-out hooks; renewing also recovers after resume.
                if (now - _lastInstall >= 30000)
                {
                    try { Install(); Interlocked.Increment(ref _renewals); }
                    catch (Win32Exception) { /* Retry on the next timer tick. */ }
                }
            }
        }
        catch (Exception exception)
        {
            _startupError = exception;
        }
        finally
        {
            _ready.Set();
            if (timer != 0) KillTimer(0, timer);
            if (_hook != 0) UnhookWindowsHookEx(_hook);
            _hook = 0;
            GC.KeepAlive(_callback);
        }
    }

    private nint OnKeyboard(int code, nint message, nint data)
    {
        if (code < 0)
        {
            return CallNextHookEx(_hook, code, message, data);
        }

        var key = Marshal.PtrToStructure<KeyboardData>(data);
        var eventType = message.ToInt64();
        if (key.VirtualKey != VkF12 || (!_allowInjected && (key.Flags & 0x10) != 0) ||
            eventType is not (0x100 or 0x101 or 0x104 or 0x105))
        {
            return CallNextHookEx(_hook, code, message, data);
        }

        // The modifiers have already been pressed before this F12 event.
        _lastF12Event = Environment.TickCount64;
        var modified = IsDown(0x10) || IsDown(0x11) || IsDown(0x12) || IsDown(0x5B) || IsDown(0x5C);
        var result = _state.Process(eventType is 0x100 or 0x104, modified);
        if (result.Trigger)
        {
            _trigger();
        }

        return result.Suppress ? 1 : CallNextHookEx(_hook, code, message, data);
    }

    private static bool IsDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    public void Dispose()
    {
        if (_thread.IsAlive) PostThreadMessage(_threadId, 0x12, 0, 0);
        if (Thread.CurrentThread != _thread) _thread.Join(2000);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public nint Window;
        public uint Id;
        public nuint WParam;
        public nint LParam;
        public uint Time;
        public int X, Y;
        public uint Private;
    }

    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool PeekMessage(out Message message, nint window, uint min, uint max, uint remove);
    [DllImport("user32.dll")] private static extern int GetMessage(out Message message, nint window, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern nuint SetTimer(nint window, nuint id, uint interval, nint callback);
    [DllImport("user32.dll")] private static extern bool KillTimer(nint window, nuint id);

    private delegate nint HookProc(int code, nint message, nint data);

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardData
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowsHookEx(int hookType, HookProc callback, nint module, uint threadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(nint hook);

    [DllImport("user32.dll")]
    private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern nint GetModuleHandle(string? moduleName);
}
