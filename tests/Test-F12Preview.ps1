param([Parameter(Mandatory = $true)][string]$Workspace)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $Workspace 'outputs\Toggle-PluggedIn-ScreenTimeout.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Power script parse failed.' }
foreach ($name in @('Initialize-AudioMuteControl', 'Get-SystemMuteState')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $function.Extent.Text
}

function Read-State {
    $root = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    $scheme = (Get-ItemProperty -LiteralPath $root -Name ActivePowerScheme).ActivePowerScheme
    $key = Join-Path $root ($scheme + '\7516b95f-f776-4464-8c53-06167f40cc99\3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e')
    $power = Get-ItemProperty -LiteralPath $key
    $audio = Get-ItemProperty -LiteralPath 'HKCU:\Software\Codex\ScreenTimeoutToggle' -ErrorAction SilentlyContinue
    [ordered]@{
        Scheme = $scheme
        ACSeconds = $power.ACSettingIndex
        DCSeconds = $power.DCSettingIndex
        Muted = Get-SystemMuteState
        SavedMute = $audio.HasSavedMuteState
        OriginalMute = $audio.OriginalMuteState
    }
}

$before = Read-State | ConvertTo-Json -Compress
$exe = Join-Path $Workspace 'outputs\ScreenModeToast.F12-build\ScreenModeToast.exe'
$productionExe = Join-Path $Workspace 'outputs\ScreenModeToast\ScreenModeToast.exe'
$status = Join-Path $Workspace ('work\f12-preview-status-' + [Guid]::NewGuid().ToString('N') + '.json')
$restoreProduction = @(Get-Process -Name ScreenModeToast -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $productionExe }).Count -gt 0
Get-Process -Name ScreenModeToast -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $productionExe -or $_.Path -eq $exe } |
    Stop-Process -Force

$preview = Start-Process -FilePath $exe -ArgumentList @('--server', '--hotkey-preview', '--diagnostics', ('"' + $status + '"')) -WindowStyle Hidden -PassThru
$form = $null
try {
    for ($i = 0; $i -lt 60 -and -not (Test-Path -LiteralPath $status); $i++) { Start-Sleep -Milliseconds 100 }
    $initial = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
    if (-not $initial.Enabled -or $initial.Mode -ne 'PreviewOnly' -or $initial.ProcessId -ne $preview.Id) { throw 'Preview-only hook is not enabled.' }

    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object Windows.Forms.Form
    $form.Text = 'F12 preview verification'
    $form.Width = 340
    $form.Height = 120
    $form.TopMost = $true
    $form.KeyPreview = $true
    $counts = @{ Modified = 0; Plain = 0 }
    $form.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::F12) {
            if ($eventArgs.Modifiers -eq [Windows.Forms.Keys]::None) { $counts.Plain++ } else { $counts.Modified++ }
        }
        $eventArgs.SuppressKeyPress = $true
    })
    $form.Show()
    $form.Activate()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 150

    function Send-PreviewKey([string]$Keys) {
        $form.Activate()
        [Windows.Forms.Application]::DoEvents()
        [Windows.Forms.SendKeys]::SendWait($Keys)
        for ($j = 0; $j -lt 8; $j++) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
    }

    Send-PreviewKey '{F12}'
    $one = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
    if ($one.PreviewTriggerCount -ne 1) { throw 'Plain F12 did not trigger one preview.' }
    Send-PreviewKey '+{F12}'
    Send-PreviewKey '^{F12}'
    Send-PreviewKey '%{F12}'
    $modified = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
    if ($modified.PreviewTriggerCount -ne 1 -or $counts.Modified -ne 3) { throw 'Modified F12 pass-through failed.' }
    Send-PreviewKey '{F12}'
    $two = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
    if ($two.PreviewTriggerCount -ne 2 -or $counts.Plain -ne 0) { throw 'Plain F12 interception failed.' }

    # Leave the listener idle long enough for its renewal, then verify another trigger.
    for ($j = 0; $j -lt 320; $j++) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    Send-PreviewKey '{F12}'
    $renewed = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
    if ($renewed.PreviewTriggerCount -ne 3 -or $renewed.HookRenewals -lt 1 -or $counts.Plain -ne 0) { throw 'Renewed listener failed.' }

    # A connected client that sends nothing must not block all future notifications.
    $stalled = [IO.Pipes.NamedPipeClientStream]::new('.', 'ScreenTimeoutToastHost', [IO.Pipes.PipeDirection]::InOut)
    try { $stalled.Connect(1000); Start-Sleep -Milliseconds 2300 } finally { $stalled.Dispose() }
    function Send-ToastPreview([string]$Title, [string]$Diagnostics) {
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'ScreenTimeoutToastHost', [IO.Pipes.PipeDirection]::InOut)
        try {
            $pipe.Connect(1500)
            $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
            $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
            $writer.AutoFlush = $true
            $writer.WriteLine((@{ Title=$Title; Line1='Preview only'; Line2='No settings changed'; Seconds=3; IsError=$false; DiagnosticsPath=$Diagnostics } | ConvertTo-Json -Compress))
            $reply = $reader.ReadLineAsync()
            if (-not $reply.Wait(2000) -or $reply.Result -ne 'OK') { throw 'Preview acknowledgement failed.' }
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $writer) { $writer.Dispose() }
            $pipe.Dispose()
        }
    }
    Start-Sleep -Milliseconds 1200
    $entrancePath = $status + '.entrance.json'
    Send-ToastPreview 'Pending preview' $entrancePath
    Start-Sleep -Milliseconds 500
    $entrance = Get-Content -LiteralPath $entrancePath -Raw | ConvertFrom-Json
    $updatePath = $status + '.update.json'
    Send-ToastPreview 'Result preview' $updatePath
    Start-Sleep -Milliseconds 300
    $update = Get-Content -LiteralPath $updatePath -Raw | ConvertFrom-Json
    if (-not $entrance.Success -or -not $update.Success -or $update.ShowToEntranceCompleteMilliseconds -ge 100) { throw 'In-place preview update failed.' }

    $after = Read-State | ConvertTo-Json -Compress
    if ($before -ne $after) { throw 'Power/audio state changed during preview.' }
    [pscustomobject]@{
        Success = $true
        PreviewTriggers = $renewed.PreviewTriggerCount
        HookRenewals = $renewed.HookRenewals
        DispatchMilliseconds = @($one.DispatchMilliseconds, $two.DispatchMilliseconds, $renewed.DispatchMilliseconds)
        StalledPipeRecovered = $true
        EntranceMilliseconds = $entrance.ShowToEntranceCompleteMilliseconds
        InPlaceUpdateMilliseconds = $update.ShowToEntranceCompleteMilliseconds
        PlainF12LeakedToApp = $counts.Plain
        ModifiedF12PassedToApp = $counts.Modified
        PowerAndAudioPreserved = $true
        Before = $before
        After = $after
    } | ConvertTo-Json -Depth 4
} finally {
    if ($null -ne $form) { $form.Close(); $form.Dispose() }
    if (-not $preview.HasExited) { Stop-Process -Id $preview.Id -Force }
    if ($restoreProduction) { Start-Process -FilePath $productionExe -ArgumentList '--server' -WindowStyle Hidden | Out-Null }
}
