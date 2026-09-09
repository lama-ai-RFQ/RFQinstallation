# Thin wrapper around Checkpoint-VM so scenario checkpoints get a consistent, greppable naming
# scheme instead of the default "VMName - date" snapshot names.

param(
    [string]$VMName = "RFQ-Test-Base",
    [Parameter(Mandatory)] [string]$CheckpointName
)

$ErrorActionPreference = "Stop"

Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName

Write-Host "Checkpoint '$CheckpointName' created on '$VMName'. Existing checkpoints:"
Get-VMSnapshot -VMName $VMName | Select-Object Name, CreationTime | Format-Table -AutoSize
