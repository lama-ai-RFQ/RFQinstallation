Set-StrictMode -Version Latest

Describe "download_and_install.ps1 .env encryption emission" {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:InstallerPath = Join-Path $script:RepoRoot "download_and_install.ps1"

        function Get-EnvEmissionScriptBlock {
            $installerSource = Get-Content -Path $script:InstallerPath -Raw
            $pattern = "(?s)# Setup \.env file with GitHub token.*?(?=`r?`n# Create version file)"
            $match = [regex]::Match($installerSource, $pattern)

            if (-not $match.Success) {
                throw "Could not locate the .env emission region in $script:InstallerPath"
            }

            return [scriptblock]::Create($match.Value)
        }

        function Invoke-EnvEmissionRegion {
            param(
                [AllowNull()]
                [object]$TemplateContent,
                [string]$AzureKeyCustom = "preserve-this-azure-key",
                [switch]$AzureKeyGenerate
            )

            $InstallPath = Join-Path ([System.IO.Path]::GetTempPath()) ("rfq-env-emission-{0}" -f ([guid]::NewGuid().ToString("N")))
            New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null

            if ($null -ne $TemplateContent) {
                Set-Content -Path (Join-Path $InstallPath ".env.template") -Value ([string]$TemplateContent) -NoNewline -Force
            }

            function Write-Info { param([string]$Message) }
            function Write-Success { param([string]$Message) }
            function Test-CredentialManagerAvailable { return $false }

            $GitHubToken = "ghp_characterization"
            $ModelPath = ""
            $SkipModelDownload = $false
            $AWSKey = ""
            $AWSSecret = ""
            $AWSRegion = "us-east-1"
            $S3ReleaseBucket = "rfq-distribution-us"
            $S3ReleaseRegion = ""
            $SettingsPassword = "settings-password"
            $SuperUserPassword = "super-password"
            $RFQUserPassword = "rfq-password"
            $ServerURL = "https://localhost"
            $CleanReinstall = $false
            $CleanupAfterInstall = $false
            $UpdateChannel = "customer"
            $UseCredentialManager = $false
            $ServiceAccount = "CurrentUser"
            $SettingsPasswordAlreadyStored = $false
            $SuperUserPasswordAlreadyStored = $false
            $RFQUserPasswordAlreadyStored = $false

            $block = Get-EnvEmissionScriptBlock

            try {
                & $block
                return [pscustomobject]@{
                    InstallPath = $InstallPath
                    EnvPath = Join-Path $InstallPath ".env"
                    Content = Get-Content -Path (Join-Path $InstallPath ".env") -Raw
                }
            }
            finally {
                Remove-Item -Path $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    It "replaces an existing Azure encryption key line from a template with the installer Azure key" {
        $result = Invoke-EnvEmissionRegion -TemplateContent @"
RFQ_CONFIG_ENCRYPTION_KEY=existing-rfq-key
AZURE_CONFIG_ENCRYPTION_KEY=your_azure_encryption_key_here
"@ -AzureKeyCustom "custom-azure-key"

        $result.Content | Should -Match "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=custom-azure-key$"
        ([regex]::Matches($result.Content, "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=")).Count | Should -Be 1
    }

    It "appends an Azure encryption key line when the template does not contain one" {
        $result = Invoke-EnvEmissionRegion -TemplateContent @"
RFQ_CONFIG_ENCRYPTION_KEY=existing-rfq-key
"@ -AzureKeyCustom "appended-azure-key"

        $result.Content | Should -Match "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=appended-azure-key$"
        ([regex]::Matches($result.Content, "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=")).Count | Should -Be 1
    }

    It "does not append a duplicate Azure encryption key when the replacement path already handled it" {
        $result = Invoke-EnvEmissionRegion -TemplateContent @"
AZURE_CONFIG_ENCRYPTION_KEY=old-azure-key
RFQ_CONFIG_ENCRYPTION_KEY=existing-rfq-key
"@ -AzureKeyCustom "replacement-azure-key"

        ([regex]::Matches($result.Content, "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=")).Count | Should -Be 1
        $result.Content | Should -Match "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=replacement-azure-key$"
    }

    It "preserves a non-placeholder RFQ encryption key in the template branch" {
        $result = Invoke-EnvEmissionRegion -TemplateContent @"
RFQ_CONFIG_ENCRYPTION_KEY=customer-rfq-key
AZURE_CONFIG_ENCRYPTION_KEY=old-azure-key
"@ -AzureKeyCustom "new-azure-key"

        $result.Content | Should -Match "(?m)^RFQ_CONFIG_ENCRYPTION_KEY=customer-rfq-key$"
        $result.Content | Should -Match "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=new-azure-key$"
    }

    It "writes a syntactically valid Azure encryption key line in the no-template fallback" {
        $result = Invoke-EnvEmissionRegion -TemplateContent $null -AzureKeyCustom "fallback-azure-key"

        $result.Content | Should -Match "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=fallback-azure-key$"
        ([regex]::Matches($result.Content, "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=")).Count | Should -Be 1
    }

    It "emits a generated Azure encryption key as a non-empty base64 value" {
        $result = Invoke-EnvEmissionRegion -TemplateContent @"
RFQ_CONFIG_ENCRYPTION_KEY=existing-rfq-key
AZURE_CONFIG_ENCRYPTION_KEY=placeholder
"@ -AzureKeyGenerate

        $result.Content | Should -Match "(?m)^AZURE_CONFIG_ENCRYPTION_KEY=[A-Za-z0-9+/]{43}=$"
    }
}
