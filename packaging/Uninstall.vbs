Option Explicit
Dim shell, fs, script, command, result
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
If MsgBox("Remove Screen Timeout Toggle, its shortcut and startup entry?" & vbCrLf & vbCrLf & "Switch back to Never before uninstalling if you want sound restored. Uninstall does not change screen/audio settings.", vbYesNo + vbQuestion, "Screen Timeout Toggle") <> vbYes Then WScript.Quit
script = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "Uninstall.ps1")
command = Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe" & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Chr(34) & script & Chr(34)
result = shell.Run(command, 0, True)
If result = 0 Then
    MsgBox "Uninstalled.", vbInformation, "Screen Timeout Toggle"
Else
    MsgBox "Uninstall could not finish. Run Uninstall.ps1 in PowerShell to see the error.", vbExclamation, "Screen Timeout Toggle"
End If
