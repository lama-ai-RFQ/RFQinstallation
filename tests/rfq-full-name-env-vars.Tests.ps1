Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:InstallerScript = Join-Path $script:RepoRoot 'download_and_install.ps1'
    $script:DatabaseScript = Join-Path $script:RepoRoot 'setup_database_auto.ps1'
    $script:BatchWrapper = Join-Path $script:RepoRoot 'install.bat'
    $script:RfqNameEnvVars = @(
        'RFQ_APP_SERVICE_NAME',
        'RFQ_APP_SERVICE_DISPLAY_NAME',
        'RFQ_APP_SERVICE_DESCRIPTION',
        'RFQ_UPDATER_SERVICE_NAME',
        'RFQ_UPDATER_SERVICE_DISPLAY_NAME',
        'RFQ_UPDATER_SERVICE_DESCRIPTION',
        'RFQ_INSTALL_DIR',
        'RFQ_SHORTCUT_NAME',
        'RFQ_REGISTRY_HANDOFF_KEY',
        'RFQ_CREDMAN_SQL_SUPER_USER_TARGET',
        'RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET',
        'RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET'
    )

    function Import-ScriptFunctions {
        param(
            [Parameter(Mandatory)]
            [string] $ScriptPath,

            [Parameter(Mandatory)]
            [string[]] $Names
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $ScriptPath,
            [ref] $tokens,
            [ref] $parseErrors
        )

        if ($parseErrors.Count -gt 0) {
            throw "Unable to parse $ScriptPath`: $($parseErrors[0].Message)"
        }

        $functionAsts = @(
            $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        )

        foreach ($name in $Names) {
            $acceptedNames = @($name, "script:$name", "global:$name", "local:$name", "private:$name")
            $matches = @($functionAsts | Where-Object { $acceptedNames -contains $_.Name })
            if ($matches.Count -ne 1) {
                throw "Expected exactly one function definition for '$name' in $ScriptPath, found $($matches.Count)."
            }

            $definition = [regex]::Replace(
                $matches[0].Extent.Text,
                '^\s*function\s+(?:(?:script|global|local|private):)?([A-Za-z0-9_-]+)',
                "function global:$name",
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            . ([scriptblock]::Create($definition))
        }
    }

    function Invoke-WithRfqEnv {
        param(
            [hashtable] $Values = @{},

            [Parameter(Mandatory)]
            [scriptblock] $ScriptBlock
        )

        $previous = @{}
        foreach ($name in $script:RfqNameEnvVars) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }

        try {
            foreach ($entry in $Values.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
            }
            & $ScriptBlock
        }
        finally {
            foreach ($name in $script:RfqNameEnvVars) {
                [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
            }
        }
    }

    function Set-TestLocalAppData {
        param([Parameter(Mandatory)][string] $Value)

        if (Test-Path Env:LOCALAPPDATA) {
            $script:PreviousLocalAppData = $env:LOCALAPPDATA
        } else {
            $script:PreviousLocalAppData = $null
        }
        $env:LOCALAPPDATA = $Value
    }

    function Restore-TestLocalAppData {
        if ($null -eq $script:PreviousLocalAppData) {
            Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
        } else {
            $env:LOCALAPPDATA = $script:PreviousLocalAppData
        }
    }

    function Get-DecodedElevatedCommand {
        param([Parameter(Mandatory)][string[]] $ArgumentList)

        $encodedIndex = [Array]::IndexOf($ArgumentList, '-EncodedCommand')
        if ($encodedIndex -lt 0 -or $encodedIndex -eq ($ArgumentList.Count - 1)) {
            throw "Argument list did not contain an encoded command."
        }

        return [System.Text.Encoding]::Unicode.GetString(
            [Convert]::FromBase64String($ArgumentList[$encodedIndex + 1])
        )
    }

    function Resolve-TestRegistryKeyPath {
        return Get-RfqEnvValueOrDefault `
            -EnvName 'RFQ_REGISTRY_HANDOFF_KEY' `
            -DefaultValue 'Software\RFQApplication\Installer' `
            -Validator { param($Value) Test-RfqRegistryKeyPath $Value } `
            -ValidationMessage 'Use an HKCU-relative registry key path without leading, trailing, duplicate, forward, or drive-root slashes.'
    }

    Import-ScriptFunctions -ScriptPath $script:InstallerScript -Names @(
        'Get-RfqEnvValueOrDefault',
        'Test-RfqTextValue',
        'Test-RfqServiceName',
        'Test-RfqShortcutName',
        'Test-RfqInstallPath',
        'Get-RfqInstallerIdentity',
        'Resolve-RfqInstallPath',
        'ConvertTo-RfqPowerShellSingleQuotedLiteral',
        'New-RfqElevatedPowerShellArgumentList'
    )

    Import-ScriptFunctions -ScriptPath $script:DatabaseScript -Names @(
        'Get-RfqEnvValueOrDefault',
        'Test-RfqRegistryKeyPath'
    )
}

Describe 'download_and_install direct env-var identity contract' {
    It 'keeps literal defaults when direct env vars are absent' {
        Set-TestLocalAppData 'C:\Users\agent\AppData\Local'
        try {
            Invoke-WithRfqEnv @{} {
                $identity = Get-RfqInstallerIdentity

                $identity.ServiceName | Should -BeExactly 'RFQapplication'
                $identity.ServiceDisplayName | Should -BeExactly 'RFQ Application Service'
                $identity.ServiceDescription | Should -BeExactly 'RFQ Application service description'
                $identity.UpdaterServiceName | Should -BeExactly 'RFQUpdaterService'
                $identity.UpdaterServiceDisplayName | Should -BeExactly 'RFQ Application Updater Service'
                $identity.UpdaterServiceDescription | Should -BeExactly 'Polls for update triggers and applies updates to RFQ Application'
                $identity.ShortcutName | Should -BeExactly 'RFQ Application'
                $identity.ShortcutFileName | Should -BeExactly 'RFQ Application.lnk'
                $identity.CredentialTargets['SQL_SUPER_USER'] | Should -BeExactly 'RFQApplication_SQL_SUPER_USER'
                $identity.CredentialTargets['RFQ_USER_PASSWORD'] | Should -BeExactly 'RFQApplication_RFQ_USER_PASSWORD'
                $identity.CredentialTargets['SETTINGS_PASSWORD'] | Should -BeExactly 'RFQApplication_SETTINGS_PASSWORD'

                (Resolve-RfqInstallPath -CurrentInstallPath 'ignored' -InstallPathProvided:$false) |
                    Should -BeExactly 'C:\Users\agent\AppData\Local\RFQApplication'
            }
        }
        finally {
            Restore-TestLocalAppData
        }
    }

    It 'keeps literal defaults when direct env vars are empty' {
        $emptyValues = @{}
        foreach ($name in $script:RfqNameEnvVars) {
            $emptyValues[$name] = ''
        }

        Set-TestLocalAppData 'C:\Users\agent\AppData\Local'
        try {
            Invoke-WithRfqEnv $emptyValues {
                $identity = Get-RfqInstallerIdentity

                $identity.ServiceName | Should -BeExactly 'RFQapplication'
                $identity.UpdaterServiceName | Should -BeExactly 'RFQUpdaterService'
                $identity.ShortcutFileName | Should -BeExactly 'RFQ Application.lnk'
                $identity.CredentialTargets['SQL_SUPER_USER'] | Should -BeExactly 'RFQApplication_SQL_SUPER_USER'
                (Resolve-RfqInstallPath -CurrentInstallPath 'ignored' -InstallPathProvided:$false) |
                    Should -BeExactly 'C:\Users\agent\AppData\Local\RFQApplication'
            }
        }
        finally {
            Restore-TestLocalAppData
        }
    }

    It 'uses explicit full-name env var values independently' {
        Set-TestLocalAppData 'C:\Users\agent\AppData\Local'
        try {
            Invoke-WithRfqEnv @{
                RFQ_APP_SERVICE_NAME = 'RFQapplication_blue'
                RFQ_APP_SERVICE_DISPLAY_NAME = 'RFQ Application Service Blue'
                RFQ_APP_SERVICE_DESCRIPTION = 'Blue service description'
                RFQ_UPDATER_SERVICE_NAME = 'RFQUpdaterService_blue'
                RFQ_UPDATER_SERVICE_DISPLAY_NAME = 'RFQ Application Updater Service Blue'
                RFQ_UPDATER_SERVICE_DESCRIPTION = 'Blue updater description'
                RFQ_INSTALL_DIR = 'D:\Apps\RFQApplicationBlue'
                RFQ_SHORTCUT_NAME = 'RFQ Application Blue'
                RFQ_CREDMAN_SQL_SUPER_USER_TARGET = 'RFQApplicationBlue_SQL_SUPER_USER'
                RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET = 'RFQApplicationBlue_RFQ_USER_PASSWORD'
                RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET = 'RFQApplicationBlue_SETTINGS_PASSWORD'
            } {
                $identity = Get-RfqInstallerIdentity

                $identity.ServiceName | Should -BeExactly 'RFQapplication_blue'
                $identity.ServiceDisplayName | Should -BeExactly 'RFQ Application Service Blue'
                $identity.ServiceDescription | Should -BeExactly 'Blue service description'
                $identity.UpdaterServiceName | Should -BeExactly 'RFQUpdaterService_blue'
                $identity.UpdaterServiceDisplayName | Should -BeExactly 'RFQ Application Updater Service Blue'
                $identity.UpdaterServiceDescription | Should -BeExactly 'Blue updater description'
                $identity.ShortcutFileName | Should -BeExactly 'RFQ Application Blue.lnk'
                $identity.CredentialTargets['SQL_SUPER_USER'] | Should -BeExactly 'RFQApplicationBlue_SQL_SUPER_USER'
                $identity.CredentialTargets['RFQ_USER_PASSWORD'] | Should -BeExactly 'RFQApplicationBlue_RFQ_USER_PASSWORD'
                $identity.CredentialTargets['SETTINGS_PASSWORD'] | Should -BeExactly 'RFQApplicationBlue_SETTINGS_PASSWORD'
                (Resolve-RfqInstallPath -CurrentInstallPath 'ignored' -InstallPathProvided:$false) |
                    Should -BeExactly 'D:\Apps\RFQApplicationBlue'
            }
        }
        finally {
            Restore-TestLocalAppData
        }
    }

    It 'keeps explicit -InstallPath authoritative over RFQ_INSTALL_DIR' {
        Invoke-WithRfqEnv @{ RFQ_INSTALL_DIR = 'D:\Apps\RFQApplicationBlue' } {
            (Resolve-RfqInstallPath -CurrentInstallPath 'C:\custom' -InstallPathProvided:$true) |
                Should -BeExactly 'C:\custom'
        }
    }

    It 'allows two independent installs to resolve distinct service and Credential Manager names' {
        $first = Invoke-WithRfqEnv @{
            RFQ_APP_SERVICE_NAME = 'RFQapplication_blue'
            RFQ_UPDATER_SERVICE_NAME = 'RFQUpdaterService_blue'
            RFQ_CREDMAN_SQL_SUPER_USER_TARGET = 'RFQApplicationBlue_SQL_SUPER_USER'
            RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET = 'RFQApplicationBlue_RFQ_USER_PASSWORD'
            RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET = 'RFQApplicationBlue_SETTINGS_PASSWORD'
        } {
            Get-RfqInstallerIdentity
        }

        $second = Invoke-WithRfqEnv @{
            RFQ_APP_SERVICE_NAME = 'RFQapplication_green'
            RFQ_UPDATER_SERVICE_NAME = 'RFQUpdaterService_green'
            RFQ_CREDMAN_SQL_SUPER_USER_TARGET = 'RFQApplicationGreen_SQL_SUPER_USER'
            RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET = 'RFQApplicationGreen_RFQ_USER_PASSWORD'
            RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET = 'RFQApplicationGreen_SETTINGS_PASSWORD'
        } {
            Get-RfqInstallerIdentity
        }

        $first.ServiceName | Should -Not -BeExactly $second.ServiceName
        $first.UpdaterServiceName | Should -Not -BeExactly $second.UpdaterServiceName
        $first.CredentialTargets['SQL_SUPER_USER'] | Should -Not -BeExactly $second.CredentialTargets['SQL_SUPER_USER']
        $first.CredentialTargets['RFQ_USER_PASSWORD'] | Should -Not -BeExactly $second.CredentialTargets['RFQ_USER_PASSWORD']
        $first.CredentialTargets['SETTINGS_PASSWORD'] | Should -Not -BeExactly $second.CredentialTargets['SETTINGS_PASSWORD']
    }

    It 'fails fast for invalid explicit env var values without sanitizing them' {
        { Invoke-WithRfqEnv @{ RFQ_APP_SERVICE_NAME = 'bad/name' } { Get-RfqInstallerIdentity } } |
            Should -Throw -ExpectedMessage '*Invalid RFQ_APP_SERVICE_NAME*bad/name*'

        { Invoke-WithRfqEnv @{ RFQ_SHORTCUT_NAME = 'bad:name' } { Get-RfqInstallerIdentity } } |
            Should -Throw -ExpectedMessage '*Invalid RFQ_SHORTCUT_NAME*bad:name*'

        { Invoke-WithRfqEnv @{ RFQ_APP_SERVICE_DISPLAY_NAME = "bad`nname" } { Get-RfqInstallerIdentity } } |
            Should -Throw -ExpectedMessage '*Invalid RFQ_APP_SERVICE_DISPLAY_NAME*'
    }

    It 'preserves every direct override env var in the elevated relaunch command' {
        $envValues = @{}
        $index = 0
        foreach ($name in $script:RfqNameEnvVars) {
            $index += 1
            $envValues[$name] = "value-$index"
        }

        Invoke-WithRfqEnv $envValues {
            $boundParameters = @{
                InstallPath = 'C:\custom'
                NonInteractive = [System.Management.Automation.SwitchParameter]::new($true)
                GitHubToken = 'ghp_test'
            }

            $argumentList = New-RfqElevatedPowerShellArgumentList `
                -ScriptPath 'C:\Installers\download_and_install.ps1' `
                -BoundParameters $boundParameters `
                -EnvironmentVariableNames $script:RfqNameEnvVars
            $decodedCommand = Get-DecodedElevatedCommand -ArgumentList $argumentList

            foreach ($name in $script:RfqNameEnvVars) {
                $expected = '$env:' + $name + " = '$($envValues[$name])'"
                $decodedCommand | Should -Match ([regex]::Escape($expected))
            }
            $decodedCommand | Should -Match "& 'C:\\Installers\\download_and_install\.ps1'"
            $decodedCommand | Should -Match "-InstallPath 'C:\\custom'"
            $decodedCommand | Should -Match "-NonInteractive"
        }
    }

    It 'does not leave active hard-coded service or Credential Manager invocation targets' {
        $installerText = Get-Content -LiteralPath $script:InstallerScript -Raw

        $installerText | Should -Not -Match 'Get-Service\s+-Name\s+"RFQapplication"'
        $installerText | Should -Not -Match 'Stop-Service\s+-Name\s+"RFQapplication"'
        $installerText | Should -Not -Match 'sc\.exe\s+(?:create|delete|qc|description)\s+"?RFQapplication'
        $installerText | Should -Not -Match 'nssm(?:\.exe)?\s+(?:install|remove|set|start)\s+"?RFQapplication'
        $installerText | Should -Not -Match 'TargetName\s*=\s*"RFQApplication_(?:SQL_SUPER_USER|RFQ_USER_PASSWORD|SETTINGS_PASSWORD)"'
        $installerText | Should -Not -Match 'Join-Path\s+\$DesktopPath\s+"RFQ Application\.lnk"'
    }
}

Describe 'registry handoff and batch direct env-var propagation contract' {
    It 'reads the registry handoff path from RFQ_REGISTRY_HANDOFF_KEY with the literal default' {
        Invoke-WithRfqEnv @{} {
            (Resolve-TestRegistryKeyPath) | Should -BeExactly 'Software\RFQApplication\Installer'
        }

        Invoke-WithRfqEnv @{ RFQ_REGISTRY_HANDOFF_KEY = 'Software\RFQApplicationBlue\Installer' } {
            (Resolve-TestRegistryKeyPath) | Should -BeExactly 'Software\RFQApplicationBlue\Installer'
        }

        { Invoke-WithRfqEnv @{ RFQ_REGISTRY_HANDOFF_KEY = 'HKCU:\Software\RFQApplication\Installer' } { Resolve-TestRegistryKeyPath } } |
            Should -Throw -ExpectedMessage '*Invalid RFQ_REGISTRY_HANDOFF_KEY*'
    }

    It 'keeps setup_database_auto registry reads on the resolved handoff key path' {
        $databaseText = Get-Content -LiteralPath $script:DatabaseScript -Raw

        $databaseText | Should -Match 'RFQ_REGISTRY_HANDOFF_KEY'
        $databaseText.Contains('-DefaultValue "Software\RFQApplication\Installer"') | Should -BeTrue
        $databaseText.Contains('$script:RfqInstallerRegistryPath = "HKCU:\$script:RfqInstallerRegistryKeyPath"') |
            Should -BeTrue
        $databaseText | Should -Not -Match 'Get-RegistryValue\s+-KeyPath\s+"Software\\RFQApplication\\Installer"'
    }

    It 'keeps install.bat as a direct env-var passthrough wrapper' {
        $batchText = Get-Content -LiteralPath $script:BatchWrapper -Raw

        foreach ($name in $script:RfqNameEnvVars) {
            $batchText | Should -Match ([regex]::Escape($name))
        }
        $batchText | Should -Match 'Start-Process'
        $batchText | Should -Match 'download_and_install\.ps1" %\*'
        $batchText | Should -Not -Match 'RFQ_INSTANCE_PREFIX'
    }

    It 'removes prefix-derivation from product code' {
        $productText = @(
            Get-Content -LiteralPath $script:InstallerScript -Raw
            Get-Content -LiteralPath $script:DatabaseScript -Raw
            Get-Content -LiteralPath $script:BatchWrapper -Raw
        ) -join "`n"

        $productText | Should -Not -Match 'RFQ_INSTANCE_PREFIX'
        $productText | Should -Not -Match 'Get-RfqInstancePrefix'
        $productText | Should -Not -Match 'Join-RfqInstanceIdentity'
        $productText | Should -Not -Match 'RfqInstancePrefix'
    }
}
