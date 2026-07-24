$ErrorActionPreference = 'Stop'
$toolchain = (Resolve-Path "$PSScriptRoot\..\..\work\toolchain").Path
$flutter = Join-Path $toolchain 'flutter\bin\flutter.bat'
$env:PATH = "$(Join-Path $toolchain 'git\cmd');$(Join-Path $toolchain 'flutter\bin');$env:PATH"

Set-Location $PSScriptRoot
Write-Host 'Preview URL: http://127.0.0.1:8088'
Write-Host 'Open this URL in Chrome if it does not open automatically.'
$runArgs = @(
    'run', '-d', 'web-server', '--web-hostname', '127.0.0.1', '--web-port', '8088',
    '--dart-define=CAIMASTER_API_BASE_URL=https://api.cclloo.com'
)
Write-Host 'Use Settings > Activate Device to connect live data.'
& $flutter @runArgs
