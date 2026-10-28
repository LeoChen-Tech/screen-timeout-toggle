param(
    [switch]$PreviewToast,
    [switch]$AudioSelfTest,
    [ValidateRange(1, 15)][int]$PreviewSeconds = 3
)

$ErrorActionPreference = 'Stop'

$powerCfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$powerSchemesKey = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$displaySubgroupGuid = '7516b95f-f776-4464-8c53-06167f40cc99'
$displayTimeoutGuid = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'
$neverSeconds = 0
$tenSeconds = 10
$successPopupSeconds = 3
$errorPopupSeconds = 8
$mutexName = 'Local\TogglePluggedInScreenTimeout'
$toastHostPath = Join-Path $PSScriptRoot 'ScreenModeToast\ScreenModeToast.exe'
$toastPipeName = 'ScreenTimeoutToastHost'
$audioStateKey = 'HKCU:\Software\Codex\ScreenTimeoutToggle'

function Get-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Base64)

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function Initialize-AudioMuteControl {
    if ('ScreenTimeoutAudio' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

internal enum EDataFlow {
    eRender,
    eCapture,
    eAll
}

internal enum ERole {
    eConsole,
    eMultimedia,
    eCommunications
}

[ComImport]
[Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumeratorComObject {
}

[ComImport]
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator {
    [PreserveSig]
    int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, IntPtr devices);

    [PreserveSig]
    int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
}

[ComImport]
[Guid("D666063F-1587-4E43-81F1-B948E807363F")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice {
    [PreserveSig]
    int Activate(
        ref Guid interfaceId,
        uint classContext,
        IntPtr activationParameters,
        [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer
    );
}

[ComImport]
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioEndpointVolume {
    [PreserveSig]
    int RegisterControlChangeNotify(IntPtr notify);

    [PreserveSig]
    int UnregisterControlChangeNotify(IntPtr notify);

    [PreserveSig]
    int GetChannelCount(out uint channelCount);

    [PreserveSig]
    int SetMasterVolumeLevel(float levelDb, ref Guid eventContext);

    [PreserveSig]
    int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);

    [PreserveSig]
    int GetMasterVolumeLevel(out float levelDb);

    [PreserveSig]
    int GetMasterVolumeLevelScalar(out float level);

    [PreserveSig]
    int SetChannelVolumeLevel(uint channelNumber, float levelDb, ref Guid eventContext);

    [PreserveSig]
    int SetChannelVolumeLevelScalar(uint channelNumber, float level, ref Guid eventContext);

    [PreserveSig]
    int GetChannelVolumeLevel(uint channelNumber, out float levelDb);

    [PreserveSig]
    int GetChannelVolumeLevelScalar(uint channelNumber, out float level);

    [PreserveSig]
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool isMuted, ref Guid eventContext);

    [PreserveSig]
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool isMuted);

    [PreserveSig]
    int GetVolumeStepInfo(out uint step, out uint stepCount);

    [PreserveSig]
    int VolumeStepUp(ref Guid eventContext);

    [PreserveSig]
    int VolumeStepDown(ref Guid eventContext);

    [PreserveSig]
    int QueryHardwareSupport(out uint hardwareSupportMask);

    [PreserveSig]
    int GetVolumeRange(out float minimumDb, out float maximumDb, out float incrementDb);
}

public static class ScreenTimeoutAudio {
    private const uint AllClassContexts = 23;

    private static IAudioEndpointVolume GetEndpointVolume(
        out IMMDeviceEnumerator enumerator,
        out IMMDevice device
    ) {
        enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();

        int result = enumerator.GetDefaultAudioEndpoint(
            EDataFlow.eRender,
            ERole.eMultimedia,
            out device
        );
        Marshal.ThrowExceptionForHR(result);

        Guid interfaceId = typeof(IAudioEndpointVolume).GUID;
        object endpointObject;
        result = device.Activate(
            ref interfaceId,
            AllClassContexts,
            IntPtr.Zero,
            out endpointObject
        );
        Marshal.ThrowExceptionForHR(result);

        return (IAudioEndpointVolume)endpointObject;
    }

    public static bool GetMute() {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        IAudioEndpointVolume volume = null;

        try {
            volume = GetEndpointVolume(out enumerator, out device);
            bool isMuted;
            Marshal.ThrowExceptionForHR(volume.GetMute(out isMuted));
            return isMuted;
        } finally {
            if (volume != null) Marshal.ReleaseComObject(volume);
            if (device != null) Marshal.ReleaseComObject(device);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
        }
    }

    public static void SetMute(bool isMuted) {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        IAudioEndpointVolume volume = null;

        try {
            volume = GetEndpointVolume(out enumerator, out device);
            Guid eventContext = Guid.Empty;
            Marshal.ThrowExceptionForHR(volume.SetMute(isMuted, ref eventContext));
        } finally {
            if (volume != null) Marshal.ReleaseComObject(volume);
            if (device != null) Marshal.ReleaseComObject(device);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
        }
    }
}
'@
}

function Get-SystemMuteState {
    Initialize-AudioMuteControl
    return [ScreenTimeoutAudio]::GetMute()
}

function Set-SystemMuteState {
    param([Parameter(Mandatory = $true)][bool]$Muted)

    Initialize-AudioMuteControl
    [ScreenTimeoutAudio]::SetMute($Muted)

    $verifiedState = [ScreenTimeoutAudio]::GetMute()
    if ($verifiedState -ne $Muted) {
        throw "Audio mute verification failed: expected $Muted, got $verifiedState."
    }
}

function Get-SavedMuteState {
    $result = [pscustomobject]@{
        HasValue = $false
        IsMuted = $false
    }

    if (-not (Test-Path -LiteralPath $script:audioStateKey)) {
        return $result
    }

    try {
        $state = Get-ItemProperty -LiteralPath $script:audioStateKey -ErrorAction Stop
        if (
            [int]$state.HasSavedMuteState -eq 1 -and
            $state.PSObject.Properties.Name -contains 'OriginalMuteState'
        ) {
            $result.HasValue = $true
            $result.IsMuted = ([int]$state.OriginalMuteState -eq 1)
        }
    } catch {
        return $result
    }

    return $result
}

function Save-MuteState {
    param([Parameter(Mandatory = $true)][bool]$IsMuted)

    if (-not (Test-Path -LiteralPath $script:audioStateKey)) {
        $null = New-Item -Path $script:audioStateKey -Force
    }

    $null = New-ItemProperty `
        -LiteralPath $script:audioStateKey `
        -Name 'OriginalMuteState' `
        -PropertyType DWord `
        -Value ([int]$IsMuted) `
        -Force
    $null = New-ItemProperty `
        -LiteralPath $script:audioStateKey `
        -Name 'HasSavedMuteState' `
        -PropertyType DWord `
        -Value 1 `
        -Force
}

function Clear-SavedMuteState {
    if (-not (Test-Path -LiteralPath $script:audioStateKey)) {
        return
    }

    $null = New-ItemProperty `
        -LiteralPath $script:audioStateKey `
        -Name 'HasSavedMuteState' `
        -PropertyType DWord `
        -Value 0 `
        -Force
}

function Start-ToastHostServer {
    if (-not (Test-Path -LiteralPath $script:toastHostPath)) {
        throw 'ScreenModeToast.exe was not found.'
    }

    $null = Start-Process `
        -FilePath $script:toastHostPath `
        -ArgumentList '--server' `
        -WindowStyle Hidden `
        -PassThru
}

function Send-ToastHostRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Line1,
        [Parameter(Mandatory = $true)][string]$Line2,
        [Parameter(Mandatory = $true)][int]$Seconds,
        [switch]$ErrorStyle,
        [string]$DiagnosticsPath
    )

    $request = [ordered]@{
        Title = $Title
        Line1 = $Line1
        Line2 = $Line2
        Seconds = $Seconds
        IsError = [bool]$ErrorStyle
        DiagnosticsPath = $DiagnosticsPath
    } | ConvertTo-Json -Compress

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $pipe = $null
        $reader = $null
        $writer = $null
        try {
            $pipe = [IO.Pipes.NamedPipeClientStream]::new(
                '.',
                $script:toastPipeName,
                [IO.Pipes.PipeDirection]::InOut,
                [IO.Pipes.PipeOptions]::None
            )
            $pipe.Connect($(if ($attempt -eq 0) { 180 } else { 3000 }))

            $utf8 = [Text.UTF8Encoding]::new($false)
            $writer = [IO.StreamWriter]::new($pipe, $utf8, 1024, $true)
            $writer.AutoFlush = $true
            $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
            $writer.WriteLine($request)
            $reply = $reader.ReadLineAsync()
            if (-not $reply.Wait(2000)) {
                throw 'Notification acknowledgement timed out.'
            }
            return ($reply.Result -eq 'OK')
        } catch {
            if ($attempt -eq 0) {
                Start-ToastHostServer
                Start-Sleep -Milliseconds 120
                continue
            }

            throw
        } finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $writer) { $writer.Dispose() }
            if ($null -ne $pipe) { $pipe.Dispose() }
        }
    }

    return $false
}

function Show-Toast {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][int]$Seconds,
        [switch]$ErrorStyle
    )

    $messageLines = @($Message -split "`r?`n")
    $line1 = if ($messageLines.Count -ge 1) { $messageLines[0] } else { '' }
    $line2 = if ($messageLines.Count -ge 2) {
        ($messageLines[1..($messageLines.Count - 1)] -join ' ').Trim()
    } else {
        ''
    }

    $diagnosticsPath = $null
    if ($script:PreviewToast) {
        $diagnosticsPath = Join-Path `
            $env:TEMP `
            ("ScreenTimeoutToast-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        $script:lastToastDiagnosticsPath = $diagnosticsPath
    }

    try {
        $sent = Send-ToastHostRequest `
            -Title $Title `
            -Line1 $line1 `
            -Line2 $line2 `
            -Seconds $Seconds `
            -ErrorStyle:$ErrorStyle `
            -DiagnosticsPath $diagnosticsPath
        if ($sent) {
            $script:lastToastRenderer = 'WinUI3.HermesMinimal'
            return
        }
    } catch {
        # Notification failures must not undo a successful power or audio change.
    }

    $script:lastToastRenderer = 'Unavailable'
}

function Get-ActiveSchemeGuid {
    $schemeGuid = (Get-ItemProperty -LiteralPath $script:powerSchemesKey -Name ActivePowerScheme).ActivePowerScheme
    if ([string]::IsNullOrWhiteSpace($schemeGuid)) {
        throw 'Could not determine the active power scheme.'
    }

    return $schemeGuid
}

function Get-AcScreenTimeoutSeconds {
    param([Parameter(Mandatory = $true)][string]$SchemeGuid)

    $subgroupKey = Join-Path (Join-Path $script:powerSchemesKey $SchemeGuid) $script:displaySubgroupGuid
    $settingKey = Join-Path $subgroupKey $script:displayTimeoutGuid
    $setting = Get-ItemProperty -LiteralPath $settingKey -Name ACSettingIndex
    return [int64]$setting.ACSettingIndex
}

if ($AudioSelfTest) {
    $muteStateBefore = Get-SystemMuteState
    Set-SystemMuteState -Muted $muteStateBefore
    $muteStateAfter = Get-SystemMuteState

    [pscustomobject]@{
        MuteStateBefore = $muteStateBefore
        MuteStateAfter = $muteStateAfter
        StatePreserved = ($muteStateBefore -eq $muteStateAfter)
    }
    return
}

if ($PreviewToast) {
    $previewMessage = "{0}`r`n{1}{2}" -f `
        (Get-Utf8Text '5bey5o6l6YCa55S15rqQIMK3IOW3sumdmemfsw=='), `
        (Get-Utf8Text '5bGP5bmV5YWz6Zet77ya'), `
        (Get-Utf8Text 'MTAg56eS')
    $previewTitle = Get-Utf8Text '5YWz5bGP5pe26Ze05bey5YiH5o2i'
    Show-Toast -Message $previewMessage -Title $previewTitle -Seconds $PreviewSeconds
    Write-Output ("Renderer={0}" -f $script:lastToastRenderer)
    if (-not [string]::IsNullOrWhiteSpace($script:lastToastDiagnosticsPath)) {
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if (Test-Path -LiteralPath $script:lastToastDiagnosticsPath) {
                Get-Content -LiteralPath $script:lastToastDiagnosticsPath -Raw
                break
            }
            Start-Sleep -Milliseconds 50
        }
    }
    return
}

$schemeGuid = $null
$currentSeconds = $null
$targetSeconds = $null
$savedMuteState = $null
$powerChangeVerified = $false

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $powerCfg)) {
        throw 'powercfg.exe was not found.'
    }

    $schemeGuid = Get-ActiveSchemeGuid
    $currentSeconds = Get-AcScreenTimeoutSeconds -SchemeGuid $schemeGuid

    if ($currentSeconds -eq $neverSeconds) {
        $targetSeconds = $tenSeconds
        $targetLabel = Get-Utf8Text 'MTAg56eS'
        $savedMuteState = Get-SavedMuteState

        if (-not $savedMuteState.HasValue) {
            $originalMuteState = Get-SystemMuteState
            Save-MuteState -IsMuted $originalMuteState
            $savedMuteState = [pscustomobject]@{
                HasValue = $true
                IsMuted = $originalMuteState
            }
        }

        Set-SystemMuteState -Muted $true
        $audioStatus = Get-Utf8Text '5bey5o6l6YCa55S15rqQIMK3IOW3sumdmemfsw=='
    } else {
        $targetSeconds = $neverSeconds
        $targetLabel = Get-Utf8Text '5LuO5LiN'
        $savedMuteState = Get-SavedMuteState
        $audioStatus = Get-Utf8Text '5bey5o6l6YCa55S15rqQIMK3IOWjsOmfs+acquabtOaUuQ=='
    }

    & $powerCfg /setacvalueindex $schemeGuid $displaySubgroupGuid $displayTimeoutGuid $targetSeconds | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg could not set the AC display timeout (exit code $LASTEXITCODE)."
    }

    & $powerCfg /setactive $schemeGuid | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg could not reactivate the power scheme (exit code $LASTEXITCODE)."
    }

    $verifiedSeconds = Get-AcScreenTimeoutSeconds -SchemeGuid $schemeGuid
    if ($verifiedSeconds -ne $targetSeconds) {
        throw "Verification failed: expected $targetSeconds seconds, got $verifiedSeconds seconds."
    }
    $powerChangeVerified = $true

    if ($targetSeconds -eq $neverSeconds -and $savedMuteState.HasValue) {
        Set-SystemMuteState -Muted $savedMuteState.IsMuted
        Clear-SavedMuteState

        if ($savedMuteState.IsMuted) {
            $audioStatus = Get-Utf8Text '5bey5o6l6YCa55S15rqQIMK3IOS/neaMgemdmemfsw=='
        } else {
            $audioStatus = Get-Utf8Text '5bey5o6l6YCa55S15rqQIMK3IOWjsOmfs+W3suaBouWkjQ=='
        }
    }

    $message = "{0}`r`n{1}{2}" -f `
        $audioStatus, `
        (Get-Utf8Text '5bGP5bmV5YWz6Zet77ya'), `
        $targetLabel
    $title = Get-Utf8Text '5YWz5bGP5pe26Ze05bey5YiH5o2i'
    Show-Toast -Message $message -Title $title -Seconds $successPopupSeconds
} catch {
    $originalError = $_

    if (
        $targetSeconds -eq $tenSeconds -and
        -not $powerChangeVerified -and
        $null -ne $savedMuteState -and
        $savedMuteState.HasValue
    ) {
        try {
            if ($null -ne $schemeGuid -and $null -ne $currentSeconds) {
                & $powerCfg /setacvalueindex `
                    $schemeGuid `
                    $displaySubgroupGuid `
                    $displayTimeoutGuid `
                    $currentSeconds | Out-Null
                & $powerCfg /setactive $schemeGuid | Out-Null
            }

            Set-SystemMuteState -Muted $savedMuteState.IsMuted
            Clear-SavedMuteState
        } catch {
            # Preserve the original error; recovery is best-effort.
        }
    }

    $message = "{0}`r`n{1}" -f `
        (Get-Utf8Text '5peg5rOV5YiH5o2i5YWz5bGP5pe26Ze077ya'), `
        $originalError.Exception.Message
    $title = Get-Utf8Text '5YiH5o2i5aSx6LSl'
    Show-Toast -Message $message -Title $title -Seconds $errorPopupSeconds -ErrorStyle
    exit 1
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
