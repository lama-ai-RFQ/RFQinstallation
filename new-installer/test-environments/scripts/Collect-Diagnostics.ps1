# Runs INSIDE the test machine (Sandbox or Hyper-V guest) after an install attempt.
# Gathers everything needed to judge pass/fail without having to inspect the machine by hand,
# and writes it to $OutputRoot so it survives the Sandbox/VM being thrown away.

param(
    [string]$OutputRoot = "C:\RFQTestOutput",
    [string]$InstallPath = "C:\Program Files\RFQ Application"
)

$stamp = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
$dest = Join-Path $OutputRoot $stamp
New-Item -ItemType Directory -Path $dest -Force | Out-Null

$report = Join-Path $dest "report.txt"
function Write-Section($title, $scriptBlock) {
    Add-Content -Path $report -Value "===== $title ====="
    try { & $scriptBlock 2>&1 | Out-String | Add-Content -Path $report }
    catch { Add-Content -Path $report -Value "ERROR: $_" }
    Add-Content -Path $report -Value ""
}

Write-Section "Run info" { "$(Get-Date -Format o)  |  $(whoami)  |  $env:COMPUTERNAME" }

$installerLogDir = Join-Path $env:LOCALAPPDATA "RFQ Application Setup"
$installerLog = Join-Path $installerLogDir "installer.log"
if (Test-Path $installerLog) {
    Copy-Item $installerLog (Join-Path $dest "installer.log") -Force
    Write-Section "installer.log" { "copied ($((Get-Item $installerLog).Length) bytes)" }
} else {
    Write-Section "installer.log" { "NOT FOUND at $installerLog" }
}

$crashLog = Get-ChildItem -Path C:\ -Filter "crash.log" -Recurse -ErrorAction SilentlyContinue -Depth 4 |
    Where-Object { $_.FullName -notmatch '\\Windows\\' } | Select-Object -First 1
if ($crashLog) {
    Copy-Item $crashLog.FullName (Join-Path $dest "crash.log") -Force
    Write-Section "crash.log" { "copied from $($crashLog.FullName)" }
}

Write-Section "Services (RFQapplication / RFQUpdaterService / RFQPostgreSQL)" {
    foreach ($name in @("RFQapplication", "RFQUpdaterService", "RFQPostgreSQL")) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
            "{0,-20} Status={1,-10} StartType={2}" -f $svc.Name, $svc.Status, $svc.StartType
            $wmi = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
            if ($wmi) { "  StartName={0}  PathName={1}" -f $wmi.StartName, $wmi.PathName }
        } else {
            "$name : not registered"
        }
    }
}

Write-Section "Uninstall registry key" {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RFQApplication"
    if (Test-Path $key) { Get-ItemProperty $key | Format-List * }
    else { "NOT FOUND at $key (expected - uninstaller packaging isn't wired up yet)" }
}

Write-Section "Install directory listing" {
    if (Test-Path $InstallPath) {
        Get-ChildItem -Recurse $InstallPath -ErrorAction SilentlyContinue |
            Select-Object FullName, Length, LastWriteTime | Format-Table -AutoSize
    } else {
        "NOT FOUND at $InstallPath"
    }
}

Write-Section "Credential Manager entries (names only, no secret values)" {
    cmdkey /list | Select-String -Pattern "RFQ" -Context 0,2
}

Write-Section ".env file (if that storage mode was chosen)" {
    $envFile = Join-Path $InstallPath "backend\.env"
    if (Test-Path $envFile) {
        (Get-Content $envFile) -replace '(PASSWORD|SECRET|KEY)=.*', '$1=<redacted>'
    } else {
        "NOT FOUND at $envFile"
    }
}

Write-Host "Diagnostics written to $dest"
