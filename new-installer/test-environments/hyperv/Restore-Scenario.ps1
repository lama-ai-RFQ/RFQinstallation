# Reverts the VM to a named checkpoint and boots it - this is the "reproduce" step. Run it
# before every test pass so each run starts from the exact same disk state, not whatever the
# previous run left behind.

param(
    [string]$VMName = "RFQ-Test-Base",
    [Parameter(Mandatory)] [string]$CheckpointName,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

$snapshot = Get-VMSnapshot -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue
if (-not $snapshot) {
    $available = (Get-VMSnapshot -VMName $VMName | Select-Object -ExpandProperty Name) -join ", "
    throw "No checkpoint named '$CheckpointName' on '$VMName'. Available: $available"
}

if ((Get-VM -Name $VMName).State -ne "Off") {
    Stop-VM -Name $VMName -TurnOff -Force
}

Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false

if (-not $NoStart) {
    Start-VM -Name $VMName
    Write-Host "'$VMName' restored to '$CheckpointName' and starting."
} else {
    Write-Host "'$VMName' restored to '$CheckpointName' (left off, per -NoStart)."
}
