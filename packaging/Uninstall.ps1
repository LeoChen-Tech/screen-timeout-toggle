param([switch]$KeepFiles)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$marker = Get-Content -LiteralPath (Join-Path $root 'installation.json') -Raw | ConvertFrom-Json
if ($marker.Product -ne 'ScreenTimeoutToggle' -or $marker.InstallDirectory -ne $root) { throw 'Invalid installation marker.' }
if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to remove a linked directory.' }
if (-not $KeepFiles -and @(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Installation contains links; use -KeepFiles and inspect manually.' }
$exe = Join-Path $root 'ScreenModeToast\ScreenModeToast.exe'
foreach ($process in @(Get-Process -Name ScreenModeToast -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })) {
    $process.Kill()
    if (-not $process.WaitForExit(10000)) { throw 'Unable to stop the host.' }
}
if ($marker.Integrated) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $name = 'ScreenTimeoutToggleHotkey'
    if ((Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).$name -eq ('"' + $exe + '" --server')) {
        Remove-ItemProperty -LiteralPath $runKey -Name $name
    }
    $shortcutPath = $marker.DesktopShortcut
    if (Test-Path -LiteralPath $shortcutPath) {
        $shell = New-Object -ComObject WScript.Shell
        if ($shell.CreateShortcut($shortcutPath).Arguments -eq ('"' + (Join-Path $root 'Run-ScreenTimeoutToggle-Hidden.vbs') + '"')) {
            Remove-Item -LiteralPath $shortcutPath
        }
    }
}
# Deliberately keep power/audio settings and saved restore state unchanged.
if (-not $KeepFiles) { Remove-Item -LiteralPath $root -Recurse -Force }
Write-Output 'Uninstalled. Power/audio settings and saved restore state were not modified.'
