# Runs the shared Collect-Diagnostics.ps1 inside the guest, then pulls the resulting report
# folder back to the host over PowerShell Direct so it survives the next Restore-Scenario.ps1.

param(
    [string]$VMName = "RFQ-Test-Base",
    [Parameter(Mandatory)] [pscredential] $Credential,
    [string]$LocalOutput = "$PSScriptRoot\..\output"
)

$ErrorActionPreference = "Stop"

$session = New-PSSession -VMName $VMName -Credential $Credential

$guestFolder = Invoke-Command -Session $session -ScriptBlock {
    & "C:\RFQScripts\Collect-Diagnostics.ps1"
    (Get-ChildItem "C:\RFQTestOutput" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

$stamp = Split-Path $guestFolder -Leaf
$dest = Join-Path $LocalOutput "$VMName-$stamp"
New-Item -ItemType Directory -Path $dest -Force | Out-Null

Copy-Item -FromSession $session -Path "$guestFolder\*" -Destination $dest -Recurse -Force

Remove-PSSession $session

Write-Host "Diagnostics pulled to $dest"
Get-Content (Join-Path $dest "report.txt")
