param(
    [string] $InstallerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'installer_output\RFQ_Application_Setup.exe'),
    [string[]] $Prefixes = @('e2e-12345-1', 'e2e-12345-2'),
    [switch] $RunInstaller
)

Set-StrictMode -Version Latest

$script:IsWindowsHost = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
$script:AppVersion = '1.0.1'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-PrefixedInstaller {
    param(
        [Parameter(Mandatory)]
        [string] $Prefix
    )

    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        throw "Installer not found: $InstallerPath"
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this coexistence test from an elevated PowerShell session.'
    }

    $previousPrefix = $env:RFQ_INSTANCE_PREFIX
    try {
        $env:RFQ_INSTANCE_PREFIX = $Prefix
        $process = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
            -Wait `
            -PassThru

        if ($process.ExitCode -ne 0) {
            throw "Installer exited with $($process.ExitCode) for prefix '$Prefix'."
        }
    }
    finally {
        if ($null -eq $previousPrefix) {
            Remove-Item Env:\RFQ_INSTANCE_PREFIX -ErrorAction SilentlyContinue
        }
        else {
            $env:RFQ_INSTANCE_PREFIX = $previousPrefix
        }
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

function Get-InstallRoot {
    param(
        [Parameter(Mandatory)]
        [string] $Prefix
    )

    Join-Path $env:ProgramFiles "RFQ Application-$Prefix"
}

function Get-RegistryHandoffPath {
    param(
        [Parameter(Mandatory)]
        [string] $Prefix
    )

    "HKCU:\Software\RFQApplication-$Prefix\Installer"
}

function Get-StartMenuFolder {
    param(
        [Parameter(Mandatory)]
        [string] $Prefix
    )

    $programsRoot = [Environment]::GetFolderPath('CommonPrograms')
    if ([string]::IsNullOrWhiteSpace($programsRoot)) {
        $programsRoot = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    }

    Join-Path $programsRoot "RFQ Application-$Prefix"
}

Describe 'INFA-669 Inno installer identity coexistence' -Skip:(-not $script:IsWindowsHost) {
    BeforeAll {
        if ($RunInstaller) {
            foreach ($prefix in $Prefixes) {
                Invoke-PrefixedInstaller -Prefix $prefix
            }
        }
    }

    It 'creates distinct Add/Remove Programs entries for each prefix' {
        $entries = @(Get-RfqUninstallEntries)
        $matchedEntries = @()

        foreach ($prefix in $Prefixes) {
            $displayName = "RFQ Application-$prefix"
            $matches = @($entries | Where-Object { $_.DisplayName -eq $displayName })

            $matches.Count | Should -Be 1
            $matches[0].DisplayVersion | Should -Be $script:AppVersion
            $matchedEntries += $matches[0]
        }

        @($matchedEntries.PSChildName | Select-Object -Unique).Count | Should -Be $Prefixes.Count
    }

    It 'creates a distinct install root for each prefix' {
        $roots = foreach ($prefix in $Prefixes) {
            Get-InstallRoot -Prefix $prefix
        }

        foreach ($root in $roots) {
            Test-Path -LiteralPath $root | Should -BeTrue
        }

        @($roots | Select-Object -Unique).Count | Should -Be $Prefixes.Count
    }

    It 'creates distinct Start Menu shortcuts for each prefix' {
        foreach ($prefix in $Prefixes) {
            $folder = Get-StartMenuFolder -Prefix $prefix
            $appShortcut = Join-Path $folder "RFQ Application-$prefix.lnk"
            $prefixShortcuts = @(
                Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*RFQ Application-$prefix*.lnk" }
            )

            Test-Path -LiteralPath $folder | Should -BeTrue
            Test-Path -LiteralPath $appShortcut | Should -BeTrue
            $prefixShortcuts.Count | Should -BeGreaterThan 0
        }
    }

    It 'creates distinct registry handoff paths for each prefix' {
        $paths = foreach ($prefix in $Prefixes) {
            Get-RegistryHandoffPath -Prefix $prefix
        }

        foreach ($path in $paths) {
            Test-Path -LiteralPath $path | Should -BeTrue
        }

        @($paths | Select-Object -Unique).Count | Should -Be $Prefixes.Count
    }
}
