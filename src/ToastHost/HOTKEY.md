# F12 screen-timeout toggle

The existing `ScreenModeToast.exe --server` process handles unmodified F12
from either keyboard using a low-level keyboard hook. F12 cannot be reliably
registered with RegisterHotKey because Windows reserves it for debuggers.

- A held key triggers once, until release.
- Ctrl, Alt, Shift and Win combinations pass through.
- Normal mode ignores injected keyboard events.
- An additional 600 ms interval and a running-launch guard prevent rapid repeats.
- The hook callback queues work and never performs process or file operations.
- The F12 action starts the existing PowerShell script directly, with no console.
- The desktop shortcut retains its hidden VBS launcher.
- Power, audio and rollback code remain in the original PowerShell script.

Current-user sign-in startup uses the registry value
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\ScreenTimeoutToggleHotkey`.
The desktop shortcut still starts the same VBS launcher.

Status is written once at startup to `hotkey-status.json` next to the executable.
It contains the mode, process ID and hook initialization result, not typed keys.

## Safe verification

Publish to `outputs\ScreenModeToast.F12-build` before running
`tests\Test-F12Preview.ps1 -Workspace <workspace>` in STA Windows PowerShell.
The integration test temporarily stops the installed renderer, starts the new
renderer with `--server --hotkey-preview`, directs synthetic keys to its own
test window and restores the installed renderer in a finally block.

`--hotkey-preview` branches directly to the toast UI and cannot launch the VBS
or PowerShell business script. Only this mode accepts injected F12 events.
The test reads power/mute settings without setting them and compares before/after.

`--hotkey-self-test --diagnostics <json-path>` checks twelve key-state transitions
without installing a hook or changing settings.

Fn-layer behavior is controlled by the keyboard firmware/FnLock. The hook acts
when Windows receives F12; it does not change brightness or media-key mappings.

## Reliability and response

The keyboard hook has a dedicated native message-loop thread, independent of WinUI.
An idle timer recovers stale key state after two seconds without F12 events, when
F12 is no longer down. Every 30 seconds while idle it renews the hook, because
Windows can silently remove timed-out low-level hooks. This cannot recover a
terminated host or keys intercepted by firmware before they reach Windows.

An accepted F12 press immediately shows a pending notification. The unchanged
power/audio operation then sends its verified result to the same card. A visible
card updates in place instead of replaying its entrance animation. The pending
message is not a claim that settings have already changed. PowerShell startup and
audio-interface compilation still contribute to the time until the final result.

Notification requests and acknowledgements have bounded waits so a stalled pipe
client/server cannot hold subsequent F12 actions indefinitely. Preview diagnostics
include hook renewal count and input-to-UI dispatch time (not pixel presentation
or total power-operation time). The integration test uses a fresh status path and
checks the actual preview process ID, avoiding stale test results.
