# Case 1 only: POST to token URL with gcc-high-combined.pem. Expect 400 invalid_grant (SSL OK).
# Put gcc-high-combined.pem in same folder as this script. Run: powershell -ExecutionPolicy Bypass -File ".\test_request_certificate.ps1"

param([string]$BundlePath)

$ErrorActionPreference = 'Stop'
$TOKEN_URL = 'https://login.microsoftonline.us/common/oauth2/v2.0/token'
$POST_DATA = 'client_id=afe874d8-9c70-4f3e-9d36-dc4f934f10d9&client_secret=kj8Q~atNSIJsSEeCO6AHr-.EPcuZC2.NVeaRaZa&grant_type=authorization_code&code=sample-auth-code-from-redirect&redirect_uri=http://localhost:8000/callback&scope=User.Read'

if (-not $BundlePath) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $BundlePath = Join-Path $scriptDir 'gcc-high-combined.pem'
}

Write-Host 'Case 1: Good CA bundle (expect 400 invalid_grant)...'
if (-not (Test-Path -LiteralPath $BundlePath)) {
    Write-Host ('Bundle not found: ' + $BundlePath) -ForegroundColor Red
    exit 1
}

$bodyFile = [System.IO.Path]::GetTempFileName()
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $stdout = curl.exe -s -S -X POST -d $POST_DATA --connect-timeout 15 --max-time 30 --cacert $BundlePath -o $bodyFile -w '%{http_code}' $TOKEN_URL 2>&1
    $ErrorActionPreference = 'Stop'
    $code = [string]$stdout
    if ($code.Length -gt 3) { $code = $code.Trim().Split("`n")[-1] }
    $body = Get-Content -Raw -Path $bodyFile -ErrorAction SilentlyContinue
} finally {
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force }
}

Write-Host ('  Status: ' + $code)
$preview = if ($body) { $body.Substring(0, [Math]::Min(300, $body.Length)) } else { '(empty)' }
Write-Host ('  Response: ' + $preview)
if ($code -eq '400' -and $body -match 'invalid_grant') {
    Write-Host '  -> SSL OK, Azure rejected placeholder code.' -ForegroundColor Green
} else {
    Write-Host ('  -> Unexpected. ExitCode from curl: ' + $LASTEXITCODE) -ForegroundColor Red
}
