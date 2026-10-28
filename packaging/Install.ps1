param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\ScreenTimeoutToggle'),
    [switch]$NoIntegration,
    [switch]$NoStart,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
try {
    if ([Environment]::OSVersion.Version.Build -lt 22000 -or -not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
        throw 'Windows 11 x64 is required.'
    }
    $root = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $source = Join-Path $PSScriptRoot 'app'
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'payload-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Count -lt 5) { throw 'Invalid package manifest.' }
    foreach ($entry in $manifest) {
        $path = [IO.Path]::GetFullPath((Join-Path $source $entry.Path))
        if (-not $path.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package path.' }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) { throw "Package checksum mismatch: $($entry.Path)" }
    }
    $exe = Join-Path $root 'ScreenModeToast\ScreenModeToast.exe'
    $launcher = Join-Path $root 'Run-ScreenTimeoutToggle-Hidden.vbs'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runName = 'ScreenTimeoutToggleHotkey'
    $runValue = '"' + $exe + '" --server'
    $name = -join ([char[]](0x5173,0x5C4F,0x5207,0x6362))
    $desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) ($name + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    if (-not $NoIntegration) {
        $existing = (Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).$runName
        if ($existing -and $existing -ne $runValue) { throw 'Another installation owns the F12 startup entry. Uninstall that installation first.' }
        if (Test-Path -LiteralPath $desktopLink) {
            if ($shell.CreateShortcut($desktopLink).Arguments -ne ('"' + $launcher + '"')) { throw 'The desktop shortcut belongs to another installation.' }
        }
    }
    $markerPath = Join-Path $root 'installation.json'
    if (Test-Path -LiteralPath $root) {
        if (-not (Test-Path -LiteralPath $markerPath)) { throw 'Destination exists without an installation marker. Choose an empty destination.' }
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($marker.Product -ne 'ScreenTimeoutToggle' -or $marker.InstallDirectory -ne $root) { throw 'Invalid installation marker.' }
        if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation directory must not be a link.' }
    }
    if ($CheckOnly) { Write-Output 'Package integrity and installation checks passed.'; return }
    $running = @(Get-Process -Name ScreenModeToast -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
    foreach ($process in $running) { $process.Kill(); if (-not $process.WaitForExit(10000)) { throw 'Unable to stop the installed host.' } }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($entry in $manifest) {
        $target = Join-Path $root $entry.Path
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source $entry.Path) -Destination $target -Force
        Unblock-File -LiteralPath $target
    }
    foreach ($file in @('Uninstall.ps1','Uninstall.vbs','README.md','THIRD-PARTY-NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $root -Force
    }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'licenses')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'licenses') -Destination $root -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs') -Destination $root -Recurse -Force
    [ordered]@{ Product='ScreenTimeoutToggle'; InstallDirectory=$root; Integrated=(-not $NoIntegration); DesktopShortcut=$desktopLink } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8
    if (-not $NoIntegration) {
        $shortcut = $shell.CreateShortcut($desktopLink)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $shortcut.Arguments = '"' + $launcher + '"'
        $shortcut.WorkingDirectory = $root
        $shortcut.IconLocation = (Join-Path $root 'screen-mode-rounded.ico') + ',0'
        $shortcut.Description = 'Screen timeout and mute toggle'
        $shortcut.Save()
        New-Item -Path $runKey -Force | Out-Null
        New-ItemProperty -LiteralPath $runKey -Name $runName -Value $runValue -PropertyType String -Force | Out-Null
    }
    if (-not $NoStart) {
        $process = Start-Process -FilePath $exe -ArgumentList '--server' -WindowStyle Hidden -PassThru
        $statusPath = Join-Path $root 'ScreenModeToast\hotkey-status.json'
        $ready = $false
        for ($i=0; $i -lt 80; $i++) {
            Start-Sleep -Milliseconds 100
            if ($process.HasExited) { break }
            try {
                $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                if ($status.ProcessId -eq $process.Id -and $status.Enabled -and $status.Mode -eq 'Toggle') { $ready=$true; break }
            } catch {}
        }
        if (-not $ready) { throw 'Files installed, but F12 listener could not start. Check for another running installation or missing Windows components.' }
    }
    Write-Output "Installed: $root"
} catch {
    $_.Exception.Message | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'install-error.txt') -Encoding UTF8
    Write-Error $_
    exit 1
}
