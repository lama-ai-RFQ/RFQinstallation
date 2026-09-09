# One-time setup for the "existing install" scenarios. Unlike Windows Sandbox, a Hyper-V VM
# persists disk state between sessions, so it's the only one of the two environments that can
# hold a pre-built "Postgres + DB + key + model already installed" starting point and be
# reverted back to it in seconds instead of rebuilt (including the ~30GB model download) on
# every single test run.
#
# This script only gets you a blank VM booted from your ISO - Windows Setup (OOBE) itself has to
# be clicked through once by hand in the VM Connect window, the same as setting up any other VM.
# Once that's done and Windows Update has run, checkpoint it as "clean" with New-Checkpoint.ps1
# and use Restore-Scenario.ps1 from then on; you should never need to run this script again for
# the same base image.

param(
    [string]$VMName = "RFQ-Test-Base",
    [Parameter(Mandatory)] [string]$IsoPath,
    [string]$VhdPath = "$env:PUBLIC\Documents\Hyper-V\Virtual Hard Disks\$VMName.vhdx",
    [int]$MemoryGB = 8,
    [int]$DiskGB = 120,
    [string]$SwitchName = "Default Switch"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell module not found. Enable Hyper-V first: " +
          "Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first (Remove-VM -Name $VMName -Force, plus " +
          "delete its VHDX) if you really want to recreate it from scratch."
}

if (-not (Test-Path $IsoPath)) {
    throw "IsoPath '$IsoPath' does not exist."
}

New-VHD -Path $VhdPath -SizeBytes ([int64]$DiskGB * 1GB) -Dynamic | Out-Null

New-VM -Name $VMName -MemoryStartupBytes ([int64]$MemoryGB * 1GB) -Generation 2 `
    -VHDPath $VhdPath -SwitchName $SwitchName | Out-Null

Set-VMProcessor -VMName $VMName -Count 4
Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false   # we manage checkpoints explicitly by name
Set-VMDvdDrive -VMName $VMName -Path $IsoPath -ErrorAction SilentlyContinue
if (-not (Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue)) {
    Add-VMDvdDrive -VMName $VMName -Path $IsoPath
}
Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMDvdDrive -VMName $VMName)

# Guest Service Interface is what lets Push-ToGuest.ps1 / Collect-Diagnostics.ps1 use
# PowerShell Direct without needing the guest to have network connectivity configured yet.
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

Start-VM -Name $VMName

Write-Host @"
VM '$VMName' created and starting.

Next steps (one-time, manual):
  1. vmconnect.exe localhost $VMName
  2. Walk through Windows Setup, then run Windows Update until fully patched.
  3. Create a local administrator account you'll reuse for PowerShell Direct
     (Push-ToGuest.ps1 / Collect-Diagnostics.ps1 both take -Credential).
  4. From the host:  .\New-Checkpoint.ps1 -VMName $VMName -CheckpointName clean

From 'clean', see README.md for how to build the 'existing-all' checkpoint
(install an older build, seed a DB + encryption key + model, then checkpoint again).
"@
