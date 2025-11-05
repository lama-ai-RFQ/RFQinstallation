# RFQ Application - Windows Installation Repository

This is the **public** repository for first-time installation of the RFQ Windows application.

## Purpose

- **First-time installation**: Users download the initial installation package from here
- **Public access**: No GitHub token required to download the installer
- **Bootstrap**: Sets up the application with update capabilities

## Repository Structure

```
lama-ai-RFQ/RFQinstallation/
├── README.md                    # Installation instructions
├── CHANGELOG.md                 # Version history
├── download_and_install.ps1     # PowerShell installer script
├── install.bat                  # Batch file wrapper
└── releases/                    # GitHub releases with installer packages
    └── [version]/
        └── RFQ-windows-installer-[version].zip
```

## Release Structure

Each release should contain a single ZIP file named `RFQ-windows-installer-[version].zip` with:

```
RFQ-windows-installer-v3.0.815.zip
├── RFQ_Application.exe          # Main executable
├── RFQ_Application.bat          # Launcher script
├── backend/                     # Backend Python code
├── frontend/                    # React frontend build
├── _internal/                   # PyInstaller dependencies
├── config.toml                  # Configuration
├── README_Windows.md            # User documentation
├── setup_database_auto.bat      # Database setup script
├── version.txt                  # Version file
└── .env.template                # Environment template
```

## Creating a Release

### Option 1: Upload Existing Build

If you already have a built Windows package:

1. Go to https://github.com/lama-ai-RFQ/RFQinstallation/releases/new
2. Create a new tag (e.g., `v3.0.815`)
3. Set as latest release
4. Upload your `RFQ-windows-installer-v3.0.815.zip`
5. Publish release

### Option 2: Use Preparation Script

Use the provided `prepare_installer_package.ps1` script:

```powershell
# Prepare installer from existing build
.\prepare_installer_package.ps1 -SourcePath ".\dist\RFQ_Application" -Version "3.0.815"

# This creates: RFQ-windows-installer-v3.0.815.zip
# Then upload to GitHub releases
```

## User Installation Flow

1. User goes to https://github.com/lama-ai-RFQ/RFQinstallation/releases/latest
2. Downloads `download_and_install.ps1` (or `install.bat`)
3. Runs the installer:
   ```powershell
   .\download_and_install.ps1 -GitHubToken "ghp_xxxxx"
   ```
4. Script downloads the installer ZIP from this repo
5. Extracts to installation directory
6. Sets up `.env` with GitHub token
7. User launches application
8. Future updates use the built-in update manager (from private `rfqwindowspackages` repo)

## Relationship with Update System

```
┌─────────────────────────────────────────────────────────────┐
│                    First-Time Installation                   │
│                                                               │
│  Public Repo: lama-ai-RFQ/RFQinstallation                   │
│  Purpose: Bootstrap new installations                        │
│  Access: Public (no token needed for download)               │
│  Contents: Complete application package (3-4 GB)             │
│                                                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Installed Application                     │
│                                                               │
│  Location: %LOCALAPPDATA%\RFQApplication                     │
│  Has: Built-in update manager                                │
│  Config: .env with GITHUB_PAT                                │
│                                                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Ongoing Updates                           │
│                                                               │
│  Private Repo: lama-ai-rfq/rfqwindowspackages              │
│  Purpose: Incremental updates                                │
│  Access: Requires GITHUB_PAT                                 │
│  Contents: Component-based packages (manifest.json)          │
│  Method: Built-in update manager (Settings → System Updates) │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## Installation Script Features

- ✅ Downloads latest release automatically
- ✅ Extracts to installation directory
- ✅ Creates `.env` with GitHub token
- ✅ Creates desktop shortcut
- ✅ Validates disk space and prerequisites
- ✅ Progress indicators
- ✅ Error handling

## Requirements

- Windows 10/11 (64-bit)
- PowerShell 5.1 or later
- ~4 GB free disk space
- Internet connection

## Security Notes

- This repo is **PUBLIC** - don't include sensitive data in installer
- GitHub PAT should be provided by user during installation
- PAT is stored locally in `.env` file (not in repo)
- Updates are fetched from **PRIVATE** repo using PAT

## Support

For installation issues:
- Check installation logs
- Verify disk space (4 GB required)
- Ensure PowerShell 5.1+ is installed
- Check internet connection

For application issues after installation:
- See README_Windows.md in installation directory
- Check logs in `logs/` folder
- Use built-in updater for updates

## Development

To test the installer locally:

```powershell
# Download installer script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/lama-ai-RFQ/RFQinstallation/main/download_and_install.ps1" -OutFile "install.ps1"

# Run installer
.\install.ps1 -GitHubToken "ghp_xxxxx"
```

## Version Compatibility

| Installer Version | App Version | Update Manager | Notes |
|------------------|-------------|----------------|-------|
| v3.0.815         | 3.0.815     | Component-based | Current |
| v3.0.810         | 3.0.810     | Component-based | Previous |

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

