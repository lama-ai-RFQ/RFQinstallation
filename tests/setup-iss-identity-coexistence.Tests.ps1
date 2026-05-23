param(
    [string] $SetupScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'setup.iss'),
    [string] $InstallerDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'installer_output'),
    [string] $InnoCompilerPath = 'ISCC.exe',
    [hashtable[]] $Instances = @(
        @{
            Name = 'e2e-a'
            AppId = '11111111-1111-4111-8111-111111111111'
            AppName = 'RFQ Application e2e A'
            OutputBaseFilename = 'RFQ_Application_Setup_e2e_A'
            DefaultDirName = (Join-Path $env:ProgramFiles 'RFQ Application e2e A')
            DefaultGroupName = 'RFQ Application e2e A'
            RegistryHandoffKey = 'Software\RFQApplication-e2e-A\Installer'
            StartMenuShortcutName = '{group}\RFQ Application e2e A'
            UninstallShortcutName = '{group}\Uninstall RFQ Application e2e A'
            DesktopShortcutName = '{autodesktop}\RFQ Application e2e A'
            QuickLaunchShortcutName = '{userappdata}\Microsoft\Internet Explorer\Quick Launch\RFQ Application e2e A'
        },
        @{
            Name = 'e2e-b'
            AppId = '22222222-2222-4222-8222-222222222222'
            AppName = 'RFQ Application e2e B'
            OutputBaseFilename = 'RFQ_Application_Setup_e2e_B'
            DefaultDirName = (Join-Path $env:ProgramFiles 'RFQ Application e2e B')
            DefaultGroupName = 'RFQ Application e2e B'
            RegistryHandoffKey = 'Software\RFQApplication-e2e-B\Installer'
            StartMenuShortcutName = '{group}\RFQ Application e2e B'
            UninstallShortcutName = '{group}\Uninstall RFQ Application e2e B'
            DesktopShortcutName = '{autodesktop}\RFQ Application e2e B'
            QuickLaunchShortcutName = '{userappdata}\Microsoft\Internet Explorer\Quick Launch\RFQ Application e2e B'
        }
    ),
    [switch] $CompileInstallers,
    [switch] $RunInstaller
)

Set-StrictMode -Version Latest

$script:IsWindowsHost = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
$script:AppVersion = '1.0.1'
$script:IdentityEnvMap = [ordered] @{
    RFQ_APP_ID = 'AppId'
    RFQ_APP_NAME = 'AppName'
    RFQ_OUTPUT_BASE_FILENAME = 'OutputBaseFilename'
    RFQ_DEFAULT_DIR_NAME = 'DefaultDirName'
    RFQ_DEFAULT_GROUP_NAME = 'DefaultGroupName'
    RFQ_REGISTRY_HANDOFF_KEY = 'RegistryHandoffKey'
    RFQ_START_MENU_SHORTCUT_NAME = 'StartMenuShortcutName'
    RFQ_UNINSTALL_SHORTCUT_NAME = 'UninstallShortcutName'
    RFQ_DESKTOP_SHORTCUT_NAME = 'DesktopShortcutName'
    RFQ_QUICK_LAUNCH_SHORTCUT_NAME = 'QuickLaunchShortcutName'
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WithIdentityEnvironment {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Instance,
        [Parameter(Mandatory)]
        [scriptblock] $Script
    )

    $previousValues = @{}
    try {
        foreach ($entry in $script:IdentityEnvMap.GetEnumerator()) {
            $previousValues[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable($entry.Key, [string] $Instance[$entry.Value], 'Process')
        }

        & $Script
    }
    finally {
        foreach ($entry in $script:IdentityEnvMap.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $previousValues[$entry.Key], 'Process')
        }
    }
}

function Get-InstallerPath {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Instance
    )

    Join-Path $InstallerDirectory "$($Instance['OutputBaseFilename']).exe"
}

function Invoke-CompileIdentityInstaller {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Instance
    )

    if (-not (Test-Path -LiteralPath $SetupScript)) {
        throw "Setup script not found: $SetupScript"
    }

    Invoke-WithIdentityEnvironment -Instance $Instance -Script {
        & $InnoCompilerPath $SetupScript
        if ($LASTEXITCODE -ne 0) {
            throw "Inno compiler exited with $LASTEXITCODE for '$($Instance['Name'])'."
        }
    }

    $installerPath = Get-InstallerPath -Instance $Instance
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Compiled installer not found for '$($Instance['Name'])': $installerPath"
    }
}

function Invoke-IdentityInstaller {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Instance
    )

    $installerPath = Get-InstallerPath -Instance $Instance
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Installer not found for '$($Instance['Name'])': $installerPath"
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this coexistence test from an elevated PowerShell session.'
    }

    $process = Start-Process `
        -FilePath $installerPath `
        -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Installer exited with $($process.ExitCode) for '$($Instance['Name'])'."
    }
}

function Get-RfqUninstallEntries {
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'RFQ Application*' } |
        Select-Object DisplayName, DisplayVersion, PSChildName, UninstallString
}

function Get-RegistryHandoffPath {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Instance
    )

    "HKCU:\$($Instance['RegistryHandoffKey'])"
}

function Get-StartMenuFolder {
    param(
        [Parameter(Mandatory)]
        [hashtable] $Instance
    )

    $programsRoot = [Environment]::GetFolderPath('CommonPrograms')
    if ([string]::IsNullOrWhiteSpace($programsRoot)) {
        $programsRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    }

    Join-Path $programsRoot $Instance['DefaultGroupName']
}

Describe 'INFA-669 Inno installer identity coexistence' -Skip:(-not $script:IsWindowsHost) {
    BeforeAll {
        if ($CompileInstallers) {
            foreach ($instance in $Instances) {
                Invoke-CompileIdentityInstaller -Instance $instance
            }
        }

        if ($RunInstaller) {
            foreach ($instance in $Instances) {
                Invoke-IdentityInstaller -Instance $instance
            }
        }
    }

    It 'creates distinct Add/Remove Programs entries for each full AppName value' {
        $entries = @(Get-RfqUninstallEntries)
        $matchedEntries = @()

        foreach ($instance in $Instances) {
            $matches = @($entries | Where-Object { $_.DisplayName -eq $instance['AppName'] })

            $matches.Count | Should -Be 1
            $matches[0].DisplayVersion | Should -Be $script:AppVersion
            $matchedEntries += $matches[0]
        }

        @($matchedEntries.PSChildName | Select-Object -Unique).Count | Should -Be $Instances.Count
    }

    It 'creates a distinct install root for each full DefaultDirName value' {
        foreach ($instance in $Instances) {
            Test-Path -LiteralPath $instance['DefaultDirName'] | Should -BeTrue
        }

        $installRoots = foreach ($instance in $Instances) {
            $instance['DefaultDirName']
        }
        @($installRoots | Select-Object -Unique).Count | Should -Be $Instances.Count
    }

    It 'creates distinct Start Menu shortcuts for each full shortcut value' {
        foreach ($instance in $Instances) {
            $folder = Get-StartMenuFolder -Instance $instance
            $appShortcut = Join-Path $folder "$($instance['AppName']).lnk"

            Test-Path -LiteralPath $folder | Should -BeTrue
            Test-Path -LiteralPath $appShortcut | Should -BeTrue
        }
    }

    It 'creates distinct registry handoff paths for each full registry key value' {
        $paths = foreach ($instance in $Instances) {
            Get-RegistryHandoffPath -Instance $instance
        }

        foreach ($path in $paths) {
            Test-Path -LiteralPath $path | Should -BeTrue
        }

        @($paths | Select-Object -Unique).Count | Should -Be $Instances.Count
    }
}
