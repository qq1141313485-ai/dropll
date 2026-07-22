$ErrorActionPreference = 'Stop'
$toolchain = (Resolve-Path "$PSScriptRoot\..\..\work\toolchain").Path
$flutter = Join-Path $toolchain 'flutter\bin\flutter.bat'
$env:PATH = "$(Join-Path $toolchain 'git\cmd');$(Join-Path $toolchain 'flutter\bin');$env:PATH"

Set-Location $PSScriptRoot
Write-Host 'Preview URL: http://127.0.0.1:8088'
Write-Host 'Open this URL in Chrome if it does not open automatically.'
$runArgs = @('run', '-d', 'web-server', '--web-hostname', '127.0.0.1', '--web-port', '8088')
$tokenFile = Join-Path $PSScriptRoot '.dev-api-token'
if (Test-Path $tokenFile) {
    $token = (Get-Content $tokenFile -Raw).Trim()
    if ($token.StartsWith('CAIMASTER_API_TOKEN=')) {
        $token = $token.Substring('CAIMASTER_API_TOKEN='.Length).Trim()
    }
    $runArgs += '--dart-define=API_BASE_URL=http://8.137.124.99:8787'
    $runArgs += "--dart-define=API_TOKEN=$token"
    Write-Host 'Live server data enabled.'
} else {
    Write-Host 'Development token not found; using preview data.'
}
& $flutter @runArgs
