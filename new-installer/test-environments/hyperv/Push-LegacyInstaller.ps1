# Copies the OLD Inno-era installer scripts (repo root: download_and_install.ps1,
# setup_database_auto.ps1) into the VM over PowerShell Direct, for building the
# 'existing-legacy-installer' checkpoint (see README.md, Scenario 3).
#
# Does NOT run them - download_and_install.ps1 needs a real GitHub PAT and AWS key/secret to
# pull the release, which you should type directly into the vmconnect.exe console session, not
# pass as plaintext script parameters that could end up logged or committed. This script only
# stages the files; the actual invocation is a manual step in the README.

param(
    [string]$VMName = "RFQ-Test-Base",
    [Parameter(Mandatory)] [pscredential] $Credential,
    [string]$RepoRoot = "$PSScriptRoot\..\..\..",
    [string]$GuestDest = "C:\LegacyInstaller"
)

$ErrorActionPreference = "Stop"

$files = @("download_and_install.ps1", "setup_database_auto.ps1")
foreach ($f in $files) {
    if (-not (Test-Path (Join-Path $RepoRoot $f))) {
        throw "Expected '$f' at repo root ('$RepoRoot') - not found."
    }
}

$session = New-PSSession -VMName $VMName -Credential $Credential

Invoke-Command -Session $session -ScriptBlock {
    param($dest)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
} -ArgumentList $GuestDest

foreach ($f in $files) {
    Copy-Item -ToSession $session -Path (Join-Path $RepoRoot $f) `
        -Destination (Join-Path $GuestDest $f) -Force
}

Remove-PSSession $session

Write-Host "Legacy installer scripts copied to '$GuestDest' on '$VMName'."
Write-Host "Next: vmconnect.exe localhost $VMName, then follow README.md Scenario 3 to run them by hand."
