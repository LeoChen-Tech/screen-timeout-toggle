param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '1.0.0',
    [string]$Dotnet = 'dotnet',
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$name = "ScreenTimeoutToggle-v$Version-win-x64"
$dist = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $root 'dist' }
$package = Join-Path $dist $name
if (Test-Path -LiteralPath $package) { throw "Package already exists: $package. Use a fresh version/output directory." }
$payload = Join-Path $package 'app'
$hostPath = Join-Path $payload 'ScreenModeToast'
New-Item -ItemType Directory -Path $hostPath -Force | Out-Null
& $Dotnet publish (Join-Path $root 'src\ToastHost\ToastHost.csproj') -c Release -r win-x64 --self-contained true '-p:WindowsAppSDKSelfContained=true' '-p:WindowsAppSdkBootstrapInitialize=false' "-p:Version=$Version" '-p:DebugType=None' '-p:DebugSymbols=false' -o $hostPath
if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }
foreach ($required in @('ScreenModeToast.exe', 'coreclr.dll', 'hostfxr.dll', 'Microsoft.UI.Xaml.dll', 'Microsoft.WindowsAppRuntime.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $hostPath $required))) { throw "Self-contained dependency missing: $required" }
}
foreach ($file in @('Toggle-PluggedIn-ScreenTimeout.ps1', 'Run-ScreenTimeoutToggle-Hidden.vbs', 'screen-mode-rounded.ico')) {
    Copy-Item -LiteralPath (Join-Path $root "outputs\$file") -Destination $payload
}
Get-ChildItem -LiteralPath (Join-Path $root 'packaging') -File | Copy-Item -Destination $package
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $package
Copy-Item -LiteralPath (Join-Path $root 'THIRD-PARTY-NOTICES.md') -Destination $package
Copy-Item -LiteralPath (Join-Path $root 'docs') -Destination $package -Recurse
# Embed component notices provided by the NuGet packages without copying their build tooling.
$nuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
$assets = Get-Content (Join-Path $root 'src\ToastHost\obj\project.assets.json') -Raw | ConvertFrom-Json
foreach ($library in $assets.libraries.PSObject.Properties) {
    foreach ($file in $library.Value.files) {
        if ($file -match '(^|/)(LICENSE[^/]*|NOTICE[^/]*|THIRD[-_]?PARTY[^/]*)(\.[^/]*)?$') {
            $source = Join-Path (Join-Path $nuget $library.Value.path) $file
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $noticeDir = Join-Path $package ('licenses\' + ($library.Name -replace '/', '-'))
                New-Item -ItemType Directory -Path $noticeDir -Force | Out-Null
                Copy-Item -LiteralPath $source -Destination (Join-Path $noticeDir (Split-Path $file -Leaf))
            }
        }
    }
}
$runtimeConfig = Get-Content (Join-Path $hostPath 'ScreenModeToast.runtimeconfig.json') -Raw | ConvertFrom-Json
$runtimeVersion = ($runtimeConfig.runtimeOptions.includedFrameworks | Where-Object { $_.name -eq 'Microsoft.NETCore.App' }).version
$runtimeNotices = Join-Path $package 'licenses\dotnet-runtime'
New-Item -ItemType Directory -Path $runtimeNotices -Force | Out-Null
foreach ($file in @('LICENSE.TXT','THIRD-PARTY-NOTICES.TXT')) {
    Copy-Item -LiteralPath (Join-Path $nuget "microsoft.netcore.app.runtime.win-x64\$runtimeVersion\$file") -Destination $runtimeNotices
}
$manifest = @(Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object {
    [ordered]@{ Path=$_.FullName.Substring($payload.Length + 1).Replace('\', '/'); SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $package 'payload-manifest.json') -Encoding UTF8
$zip = Join-Path $dist ($name + '.zip')
Compress-Archive -LiteralPath $package -DestinationPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $name.zip" | Set-Content -LiteralPath (Join-Path $dist ($name + '.sha256')) -Encoding ASCII
Write-Output $zip
