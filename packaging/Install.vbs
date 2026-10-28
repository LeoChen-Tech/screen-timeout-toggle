Option Explicit
Dim shell, fs, script, command, result
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
If MsgBox("Install Screen Timeout Toggle for this user?" & vbCrLf & vbCrLf & "This creates a desktop shortcut, enables sign-in startup and assigns plain F12 to the screen/mute toggle." & vbCrLf & "Power and sound settings are not changed during installation.", vbYesNo + vbQuestion, "Screen Timeout Toggle") <> vbYes Then WScript.Quit
script = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "Install.ps1")
command = Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe" & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Chr(34) & script & Chr(34)
result = shell.Run(command, 0, True)
If result = 0 Then
    MsgBox "Installed. Use F12 or the desktop shortcut. Uninstall.vbs is in %LOCALAPPDATA%\Programs\ScreenTimeoutToggle.", vbInformation, "Screen Timeout Toggle"
Else
    MsgBox "Installation failed. See install-error.txt beside Install.vbs.", vbExclamation, "Screen Timeout Toggle"
End If
