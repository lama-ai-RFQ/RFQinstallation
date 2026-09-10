# Runs INSIDE Windows Sandbox via the .wsb LogonCommand. Stages the installer build onto a
# writable local path (running straight off the read-only mapped folder risks the installer
# tripping over ACLs when it copies its own bundled files), wires up desktop shortcuts, sets
# the two known-placeholder endpoints if the host passed real values through, and launches the
# installer so the "empty machine" scenario needs zero manual setup once the sandbox opens.
#
# $buildSource must be a `dotnet publish` output (self-contained, single-file win-x64), not a
# plain `dotnet build` output — this machine has no .NET runtime preinstalled by design, and a
# framework-dependent exe would just hit the OS "install .NET Desktop Runtime?" prompt instead
# of actually running the installer.

$ErrorActionPreference = "Stop"

$buildSource = "C:\RFQBuild"
$local = "C:\RFQInstaller"
$scripts = "C:\RFQScripts"

New-Item -ItemType Directory -Path $local -Force | Out-Null
Copy-Item "$buildSource\*" $local -Recurse -Force

# The sandbox's own account (WDAGUtilityAccount) is auto-logged-in with a password Windows
# generates and rotates internally for the container - there's no way to look it up, so if the
# wizard's "Windows Service + Current User" path prompts for it, there's nothing to type. Reset it
# to a known value instead (one UAC consent click, since this account is already a local admin -
# same one-click path already noted below for elevation in general).
$sandboxAccountPassword = "RfqSandboxTest1!"
Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList @(
    "-NoProfile", "-Command", "net user `"$env:USERNAME`" `"$sandboxAccountPassword`""
)

# Optional overrides. A licensed install talks to the stage broker by default and signs
# postgres.windows.binaries from there. Set these only when testing without the broker.
$env:RFQ_LICENSE_BROKER_URL = ""
$env:RFQ_POSTGRES_BINARIES_URL = ""
$env:RFQ_POSTGRES_BINARIES_SHA256 = ""

$exe = Join-Path $local "RfqInstaller.exe"

$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath("Desktop")

$runShortcut = $shell.CreateShortcut((Join-Path $desktop "Run RFQ Installer.lnk"))
$runShortcut.TargetPath = $exe
$runShortcut.WorkingDirectory = $local
$runShortcut.Save()

$collectShortcut = $shell.CreateShortcut((Join-Path $desktop "Collect Diagnostics.lnk"))
$collectShortcut.TargetPath = "powershell.exe"
$collectShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scripts\Collect-Diagnostics.ps1`""
$collectShortcut.Save()

Set-Content -Path (Join-Path $desktop "Account password.txt") `
    -Value "This account's ($env:USERNAME) password was reset to: $sandboxAccountPassword`r`nType this if the wizard's Windows Service + Current User step asks for the account password."

# Note: WDAGUtilityAccount (the sandbox's default user) is a local administrator, so UAC here
# is always the one-click consent prompt - this scenario does not exercise the "standard user,
# full credential prompt" elevation path. Use the Hyper-V VM with a non-admin account for that.
Start-Process -FilePath $exe -WorkingDirectory $local
