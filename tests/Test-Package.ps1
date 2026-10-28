param([Parameter(Mandatory=$true)][string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path $PSScriptRoot -Parent
$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$sandbox = Join-Path $workspace ('work\package test ' + [Guid]::NewGuid().ToString('N'))
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $package 'app\Toggle-PluggedIn-ScreenTimeout.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Business script parse error.' }
foreach ($name in @('Initialize-AudioMuteControl','Get-SystemMuteState')) {
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $definition.Extent.Text
}
function Read-State {
    $powerRoot='Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    $scheme=(Get-ItemProperty -LiteralPath $powerRoot).ActivePowerScheme
    $power=Get-ItemProperty -LiteralPath (Join-Path $powerRoot ($scheme+'\7516b95f-f776-4464-8c53-06167f40cc99\3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'))
    $audio=Get-ItemProperty 'HKCU:\Software\Codex\ScreenTimeoutToggle' -ErrorAction SilentlyContinue
    $startup=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).ScreenTimeoutToggleHotkey
    [ordered]@{ Scheme=$scheme; AC=$power.ACSettingIndex; DC=$power.DCSettingIndex; Muted=(Get-SystemMuteState); Saved=$audio.HasSavedMuteState; Original=$audio.OriginalMuteState; Startup=$startup } | ConvertTo-Json -Compress
}
$before=Read-State
& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $package 'Install.ps1') -InstallDirectory $sandbox -NoIntegration -NoStart -CheckOnly
if ($LASTEXITCODE) { throw 'Package preflight failed.' }
& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $package 'Install.ps1') -InstallDirectory $sandbox -NoIntegration -NoStart
if ($LASTEXITCODE) { throw 'Isolated installation failed.' }
$manifest=Get-Content (Join-Path $package 'payload-manifest.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest) {
    if ((Get-FileHash -LiteralPath (Join-Path $sandbox $entry.Path)).Hash -ne $entry.SHA256) { throw 'Installed file hash mismatch.' }
}
$exe=Join-Path $sandbox 'ScreenModeToast\ScreenModeToast.exe'
$diagnostics=Join-Path $sandbox 'self-test.json'
$p=Start-Process -FilePath $exe -ArgumentList @('--hotkey-self-test','--diagnostics',('"'+$diagnostics+'"')) -WindowStyle Hidden -PassThru
if (-not $p.WaitForExit(20000) -or $p.ExitCode -ne 0) { throw 'Self-contained executable failed.' }
$result=Get-Content -LiteralPath $diagnostics -Raw | ConvertFrom-Json
if (-not $result.Success -or $result.Cases -ne 12) { throw 'Key state self-test failed.' }
# Standalone notification mode has no hook and never calls the power/audio script.
$preview=Join-Path $sandbox 'preview.json'
$p=Start-Process -FilePath $exe -ArgumentList @('--title-b64','5YWz5bGP5pe26Ze05bey5YiH5o2i','--line1-b64','5bey5o6l6YCa55S15rqQIMK3IOW3sumdmemfsw==','--line2-b64','5bGP5bmV5YWz6Zet77yaMTAg56eS','--seconds','3','--diagnostics',('"'+$preview+'"')) -WindowStyle Hidden -PassThru
for ($i=0; $i -lt 100 -and -not (Test-Path -LiteralPath $preview) -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 50 }
$p.Refresh()
foreach ($moduleName in @('coreclr.dll','Microsoft.ui.xaml.dll','Microsoft.WindowsAppRuntime.dll')) {
    $module=@($p.Modules | Where-Object { $_.ModuleName -ieq $moduleName })
    if ($module.Count -ne 1 -or -not $module[0].FileName.StartsWith($sandbox+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Runtime is not app-local: $moduleName" }
}
if (-not $p.WaitForExit(20000) -or $p.ExitCode -ne 0) { throw 'Standalone preview failed.' }
if (-not (Get-Content -LiteralPath $preview -Raw | ConvertFrom-Json).Success) { throw 'Preview did not render.' }
& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $sandbox 'Uninstall.ps1') -KeepFiles
if ($LASTEXITCODE) { throw 'Non-destructive uninstall verification failed.' }
if ((Read-State) -ne $before) { throw 'Power, audio or startup changed during isolated test.' }
[pscustomobject]@{ Success=$true; InstalledFiles=@($manifest).Count; KeyStateCases=$result.Cases; PreviewOnly=$true; AppLocalRuntimes=$true; PowerAudioStartupPreserved=$true; UninstallKeepFiles=$true } | ConvertTo-Json
