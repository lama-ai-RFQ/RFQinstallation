# Copies a fresh installer build (and the shared diagnostics collector) into the VM over
# PowerShell Direct - works over VMBus, so it doesn't need the guest's network configured.
# Run this after Restore-Scenario.ps1, then open vmconnect.exe to actually click through the
# wizard (there's no silent/unattended install mode to drive this non-interactively yet).

param(
    [string]$VMName = "RFQ-Test-Base",
    [Parameter(Mandatory)] [pscredential] $Credential,
    [string]$BuildSource = "$PSScriptRoot\..\..\RfqInstaller\bin\x64\Release\net8.0-windows\win-x64\publish",
    [string]$GuestDest = "C:\RFQInstaller"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $BuildSource)) {
    throw "Build not found at '$BuildSource' - publish it first (dotnet publish RfqInstaller\RfqInstaller.csproj). " +
        "RfqInstaller.csproj is self-contained/single-file, which only takes effect on publish, not build - these " +
        "VMs don't have the .NET Desktop Runtime preinstalled either, so a plain build output would hit the same " +
        "missing-runtime prompt as the empty Windows Sandbox scenario."
}

$session = New-PSSession -VMName $VMName -Credential $Credential

Invoke-Command -Session $session -ScriptBlock {
    param($dest, $scriptsDest)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    New-Item -ItemType Directory -Path $scriptsDest -Force | Out-Null
} -ArgumentList $GuestDest, "C:\RFQScripts"

Copy-Item -ToSession $session -Path "$BuildSource\*" -Destination $GuestDest -Recurse -Force

Copy-Item -ToSession $session `
    -Path "$PSScriptRoot\..\scripts\Collect-Diagnostics.ps1" `
    -Destination "C:\RFQScripts\Collect-Diagnostics.ps1" -Force

Remove-PSSession $session

Write-Host "Build copied to '$GuestDest' on '$VMName'. Connect with: vmconnect.exe localhost $VMName"
