Option Explicit

Function IsToastHostRunning()
    Dim processes
    Set processes = GetObject("winmgmts:\\.\root\cimv2").ExecQuery( _
        "SELECT ProcessId FROM Win32_Process WHERE Name='ScreenModeToast.exe'")
    IsToastHostRunning = (processes.Count > 0)
End Function

Dim shell, fileSystem, scriptDirectory, powershellPath, toggleScript, toastHost, command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
toggleScript = fileSystem.BuildPath(scriptDirectory, "Toggle-PluggedIn-ScreenTimeout.ps1")
toastHost = fileSystem.BuildPath(fileSystem.BuildPath(scriptDirectory, "ScreenModeToast"), "ScreenModeToast.exe")

' Prewarm the WinUI notification host while the power/audio work runs.
If fileSystem.FileExists(toastHost) And Not IsToastHostRunning() Then
    shell.Run Chr(34) & toastHost & Chr(34) & " --server", 0, False
End If

command = Chr(34) & powershellPath & Chr(34) & _
    " -NoLogo -NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & toggleScript & Chr(34)

' Window style 0 keeps the PowerShell console completely hidden.
shell.Run command, 0, True
