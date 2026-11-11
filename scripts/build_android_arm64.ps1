[CmdletBinding()]
param(
    [switch]$PrintCommand,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraFlutterArgs
)

$ErrorActionPreference = 'Stop'

if ($ExtraFlutterArgs | Where-Object {
        $_ -match '^--target-platform(?:=|$)' -or
        $_ -eq '--split-per-abi' -or
        $_ -in @('--debug', '--profile', '--release', '--jit-release')
    }) {
    throw 'This wrapper fixes release mode and the target ABI to android-arm64.'
}

$localFlutter = Join-Path $PSScriptRoot '..\..\flutter\bin\flutter.bat'
$flutter = if (Test-Path $localFlutter) {
    (Resolve-Path $localFlutter).Path
} elseif ($env:FLUTTER_ROOT -and
    (Test-Path (Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'))) {
    Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
} else {
    (Get-Command flutter -ErrorAction Stop).Source
}

# sodium 4.x needs a real Windows bash for an uncached Android native build.
$gitBashDirectory = 'C:\Program Files\Git\bin'
if (Test-Path (Join-Path $gitBashDirectory 'bash.exe')) {
    $pathEntries = $env:Path -split ';'
    if ($gitBashDirectory -notin $pathEntries) {
        $env:Path = "$gitBashDirectory;$env:Path"
    }
}

if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    $localProperties = Join-Path $PSScriptRoot '..\android\local.properties'
    if (Test-Path $localProperties) {
        $sdkProperty = Get-Content $localProperties |
            Where-Object { $_ -match '^sdk\.dir=' } |
            Select-Object -First 1
        if ($sdkProperty) {
            $sdkRoots += ($sdkProperty.Substring('sdk.dir='.Length) -replace '\\\\', '\')
        }
    }

    $ndkMake = $sdkRoots |
        Where-Object { $_ -and (Test-Path $_) } |
        Select-Object -Unique |
        ForEach-Object {
            Get-ChildItem (Join-Path $_ 'ndk\*\prebuilt\windows-x86_64\bin\make.exe') `
                -ErrorAction SilentlyContinue
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($ndkMake) {
        $env:Path = "$($ndkMake.DirectoryName);$env:Path"
    }
}

if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
    throw 'GNU make is required for a clean sodium Android build. Install it via Scoop, Chocolatey, or MSYS2 and add it to PATH.'
}

$arguments = @(
    'build'
    'apk'
    '--release'
    '--target-platform'
    'android-arm64'
) + $ExtraFlutterArgs

Write-Host "Running: $flutter $($arguments -join ' ')"
if ($PrintCommand) {
    exit 0
}

& $flutter @arguments
exit $LASTEXITCODE
