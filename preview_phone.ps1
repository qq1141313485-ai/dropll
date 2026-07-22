$ErrorActionPreference = 'Stop'

$toolchain = (Resolve-Path "$PSScriptRoot\..\..\work\toolchain").Path
$flutter = Join-Path $toolchain 'flutter\bin\flutter.bat'
$emulator = Join-Path $toolchain 'android-sdk\emulator\emulator.exe'
$adb = Join-Path $toolchain 'android-sdk\platform-tools\adb.exe'
$javaHome = Join-Path $toolchain 'jdk\jdk-17.0.19+10'

$env:JAVA_HOME = $javaHome
$env:ANDROID_SDK_ROOT = Join-Path $toolchain 'android-sdk'
$env:ANDROID_AVD_HOME = 'D:\codex-avd'
$env:PATH = "$(Join-Path $toolchain 'git\cmd');$(Join-Path $toolchain 'flutter\bin');$env:JAVA_HOME\bin;$env:ANDROID_SDK_ROOT\platform-tools;$env:PATH"

Set-Location $PSScriptRoot

if (-not (Test-Path $env:ANDROID_AVD_HOME)) {
    New-Item -ItemType Directory -Force -Path $env:ANDROID_AVD_HOME | Out-Null
}

$deviceList = & $adb devices
$hasEmulator = $deviceList -match 'emulator-5554\s+device'
if (-not $hasEmulator) {
    Write-Host 'Starting Android emulator cai_phone...'
    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList '/c', "set ANDROID_AVD_HOME=$env:ANDROID_AVD_HOME&& `"$emulator`" -avd cai_phone -no-snapshot -no-boot-anim -gpu swiftshader_indirect -no-audio"

    Write-Host 'Waiting for emulator to become ready...'
    & $adb wait-for-device | Out-Null
    for ($i = 0; $i -lt 120; $i++) {
        $boot = & $adb shell getprop sys.boot_completed 2>$null
        if ($boot -and $boot.Trim() -eq '1') {
            break
        }
        Start-Sleep -Seconds 5
    }
}

$tokenFile = Join-Path $PSScriptRoot '.dev-api-token'
$apiBaseUrl = $env:CAIMASTER_API_BASE_URL
if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) {
    $apiBaseUrl = 'http://8.137.124.99:8787'
}
$runArgs = @('run', '-d', 'emulator-5554')
if (Test-Path $tokenFile) {
    $token = (Get-Content $tokenFile -Raw).Trim()
    if ($token.StartsWith('CAIMASTER_API_TOKEN=')) {
        $token = $token.Substring('CAIMASTER_API_TOKEN='.Length).Trim()
    }
    $runArgs += "--dart-define=API_BASE_URL=$apiBaseUrl"
    $runArgs += "--dart-define=API_TOKEN=$token"
    Write-Host "Live server data enabled: $apiBaseUrl"
} else {
    Write-Host 'Development token not found; using preview data.'
}

Write-Host 'Launching Flutter app on the emulator...'
& $flutter @runArgs
