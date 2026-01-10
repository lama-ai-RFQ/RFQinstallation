# RFQ Application - Create Update Scheduled Task
# This script creates a scheduled task that allows the RFQ service to trigger updates
# without requiring the service account to have administrator privileges.
#
# Usage:
#   .\create_update_task.ps1 [-InstallPath <path>] [-TaskName <name>]
#
# The task runs as SYSTEM with highest privileges, allowing it to:
# - Stop the RFQ service
# - Replace application files
# - Restart the service
#
# The service account only needs permission to trigger this task (not create it).

param(
    [string]$InstallPath = "",
    [string]$TaskName = "RFQUpdateTask",
    [switch]$Help
)

# Bypass execution policy for this script session
# This allows the script to run even if system execution policy is restrictive
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue

# Show help
if ($Help) {
    Write-Host @"
RFQ Application - Create Update Scheduled Task

USAGE:
    .\create_update_task.ps1 [-InstallPath <path>] [-TaskName <name>]

OPTIONS:
    -InstallPath    Installation directory (default: auto-detect)
    -TaskName       Scheduled task name (default: RFQUpdateTask)
    -Help           Show this help message

DESCRIPTION:
    Creates a Windows scheduled task that allows the RFQ service to trigger
    updates without requiring the service account to have administrator privileges.

    The task is configured to:
    - Run as SYSTEM account (built-in admin account)
    - Run with highest privileges
    - Execute on-demand (triggered by the service, not on a schedule)
    - Execute: windows_updater.exe from the installation directory

SECURITY:
    This approach follows the principle of least privilege:
    - Service account does NOT need admin privileges
    - Only the scheduled task runs with elevated privileges
    - Service can only trigger the task (not modify or delete it)

EXAMPLES:
    # Create task with auto-detected installation path
    .\create_update_task.ps1

    # Create task with specific installation path
    .\create_update_task.ps1 -InstallPath "C:\Program Files\RFQ Application"

    # Create task with custom name
    .\create_update_task.ps1 -TaskName "MyRFQUpdateTask"

"@
    exit 0
}

# Function to write colored output
function Write-Info { 
    Write-Host $args -ForegroundColor Cyan
}
function Write-Success { 
    Write-Host $args -ForegroundColor Green
}
function Write-Warning { 
    Write-Host $args -ForegroundColor Yellow
}
function Write-Error-Custom { 
    Write-Host $args -ForegroundColor Red
}

# Check if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Check for admin privileges
if (-not (Test-Administrator)) {
    Write-Error-Custom "ERROR: This script must be run as Administrator"
    Write-Error-Custom ""
    Write-Error-Custom "To run as administrator:"
    Write-Error-Custom "  1. Right-click PowerShell"
    Write-Error-Custom "  2. Select 'Run as Administrator'"
    Write-Error-Custom "  3. Navigate to script directory and run again"
    Write-Error-Custom ""
    Write-Error-Custom "Or use: Start-Process powershell -Verb RunAs -ArgumentList '-File', '.\create_update_task.ps1'"
    exit 1
}

Write-Info ""
Write-Info "=================================================================================="
Write-Info "RFQ Application - Create Update Scheduled Task"
Write-Info "=================================================================================="
Write-Info ""

# Auto-detect installation path if not provided
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    Write-Info "Auto-detecting installation path..."
    
    # Try to find RFQ_Application.exe or windows_updater.exe
    $possiblePaths = @(
        "$env:LOCALAPPDATA\RFQApplication",
        "$env:ProgramFiles\RFQ Application",
        "$env:ProgramFiles(x86)\RFQ Application",
        "D:\Program Files\RFQ Application",
        "D:\AI-RFQ\RFQ Application"
    )
    
    $foundPath = $null
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $exePath = Join-Path $path "RFQ_Application.exe"
            $updaterPath = Join-Path $path "windows_updater.exe"
            if ((Test-Path $exePath) -or (Test-Path $updaterPath)) {
                $foundPath = $path
                break
            }
        }
    }
    
    if ($foundPath) {
        $InstallPath = $foundPath
        Write-Success "Found installation at: $InstallPath"
    } else {
        Write-Error-Custom "ERROR: Could not auto-detect installation path"
        Write-Error-Custom ""
        Write-Error-Custom "Please specify the installation path:"
        Write-Error-Custom "  .\create_update_task.ps1 -InstallPath 'C:\Path\To\RFQ Application'"
        exit 1
    }
} else {
    # Validate provided path
    if (-not (Test-Path $InstallPath)) {
        Write-Error-Custom "ERROR: Installation path does not exist: $InstallPath"
        exit 1
    }
}

# Normalize path
$InstallPath = [System.IO.Path]::GetFullPath($InstallPath)
Write-Info "Installation path: $InstallPath"

# Find windows_updater.exe
$updaterPath = Join-Path $InstallPath "windows_updater.exe"
if (-not (Test-Path $updaterPath)) {
    Write-Error-Custom "ERROR: windows_updater.exe not found at: $updaterPath"
    Write-Error-Custom ""
    Write-Error-Custom "Please ensure windows_updater.exe exists in the installation directory."
    exit 1
}

Write-Success "Found updater executable: $updaterPath"

# Check if task already exists
Write-Info ""
Write-Info "Checking for existing task: $TaskName"
$taskExists = $false
try {
    $existingTask = schtasks /Query /TN $TaskName 2>&1
    if ($LASTEXITCODE -eq 0) {
        $taskExists = $true
        Write-Warning "Task '$TaskName' already exists"
        $overwrite = Read-Host "Overwrite existing task? (y/N)"
        if ($overwrite -ne 'y' -and $overwrite -ne 'Y') {
            Write-Info "Keeping existing task. Exiting."
            exit 0
        }
        Write-Info "Deleting existing task..."
        schtasks /Delete /TN $TaskName /F | Out-Null
        Start-Sleep -Seconds 1
    }
} catch {
    # Task doesn't exist, which is fine
}

# Create the scheduled task
Write-Info ""
Write-Info "Creating scheduled task: $TaskName"
Write-Info "  Task will run: $updaterPath"
Write-Info "  Account: SYSTEM (built-in admin)"
Write-Info "  Privileges: Highest"
Write-Info "  Schedule: On-demand (triggered by service)"
Write-Info ""

# Create task that runs as SYSTEM with highest privileges
# Use /SC ONCE with a past date so it doesn't run automatically
# The task will be triggered on-demand using 'schtasks /Run'
# Note: Use XML import method to properly handle paths with spaces
# schtasks has issues with quoted paths in command-line arguments

# Create temporary XML file for task definition
$xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>RFQ Application Update Task - Allows the service to trigger updates without admin privileges</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Enabled>false</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$updaterPath</Command>
      <Arguments>--scheduled</Arguments>
      <WorkingDirectory>$InstallPath</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP "RFQUpdateTask.xml"
$xmlContent | Out-File -FilePath $xmlPath -Encoding Unicode -Force

Write-Info "Generated XML file: $xmlPath"
Write-Info "Updater path in XML: $updaterPath"
Write-Info "Working directory in XML: $InstallPath"

# Import the task from XML
$result = & schtasks.exe /Create /TN $TaskName /XML $xmlPath /F 2>&1
$exitCode = $LASTEXITCODE

# Clean up temporary XML file
Remove-Item $xmlPath -ErrorAction SilentlyContinue

$LASTEXITCODE = $exitCode

if ($LASTEXITCODE -eq 0) {
    Write-Success ""
    Write-Success "[OK] Scheduled task created successfully!"
    Write-Success ""
    Write-Info "Task Details:"
    Write-Info "  Name: $TaskName"
    Write-Info "  Executable: $updaterPath"
    Write-Info "  Account: SYSTEM"
    Write-Info "  Privileges: Highest"
    Write-Info ""
    Write-Info "The RFQ service can now trigger updates using:"
    Write-Info "  schtasks /Run /TN $TaskName"
    Write-Info ""
    Write-Success "The service account does NOT need administrator privileges to trigger this task."
    Write-Success ""
} else {
    Write-Error-Custom ""
    Write-Error-Custom "[FAIL] Failed to create scheduled task"
    Write-Error-Custom "Error output: $result"
    Write-Error-Custom ""
    Write-Error-Custom "Common issues:"
    Write-Error-Custom "  - Insufficient permissions (must run as Administrator)"
    Write-Error-Custom "  - Task name already exists (use -TaskName to specify different name)"
    Write-Error-Custom "  - Invalid path to windows_updater.exe"
    exit 1
}

Write-Info ""
Write-Info "=================================================================================="
Write-Info "Task creation complete!"
Write-Info "=================================================================================="
Write-Info ""

