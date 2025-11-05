# RFQ Application - Windows Installation Scripts

This directory contains scripts and documentation for creating and distributing the RFQ Application Windows installer.

## 📁 Directory Contents

### For Creating Installation Packages

| File | Purpose |
|------|---------|
| `prepare_installer_package.ps1` | Prepares a ZIP package for the public installation repo |
| `README_RFQinstallation_repo.md` | Documentation for setting up the `lama-ai-RFQ/RFQinstallation` repository |

### For End Users (to be distributed)

| File | Purpose |
|------|---------|
| `download_and_install.ps1` | PowerShell installer script (download from GitHub releases) |
| `install.bat` | Simple batch wrapper for the PowerShell script |
| `USER_QUICK_START.md` | End-user installation guide |

## 🎯 Purpose

This directory supports a **two-repository installation and update system**:

```
┌────────────────────────────────────────────────────────────────┐
│  PUBLIC REPO: lama-ai-RFQ/RFQinstallation                      │
│  Purpose: First-time installation (bootstrap)                   │
│  Contains: Complete application package (~3-4 GB)               │
│  Access: Public (no token required for download)                │
└────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────┐
│  PRIVATE REPO: lama-ai-rfq/rfqwindowspackages                 │
│  Purpose: Ongoing updates (component-based)                     │
│  Contains: Incremental update packages with manifest.json       │
│  Access: Requires GITHUB_PAT token                              │
└────────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### For Developers: Creating an Installation Package

1. **Build your Windows application** (using PyInstaller or your build process)

2. **Prepare the installer package**:
   ```powershell
   cd windows\installation
   .\prepare_installer_package.ps1 -SourcePath "..\..\dist\RFQ_Application" -Version "3.0.815"
   ```

3. **This creates**: `RFQ-windows-installer-v3.0.815.zip`

4. **Upload to GitHub**:
   - Go to https://github.com/lama-ai-RFQ/RFQinstallation/releases/new
   - Create tag: `v3.0.815`
   - Upload the ZIP file
   - Publish as latest release

5. **Also upload the installer scripts**:
   - Upload `download_and_install.ps1` as a release asset
   - Upload `install.bat` as a release asset (optional)

### For End Users: Installing the Application

Users download `download_and_install.ps1` from the releases page and run:

```powershell
.\download_and_install.ps1 -GitHubToken "ghp_xxxxxxxxxxxxx"
```

See `USER_QUICK_START.md` for detailed end-user instructions.

## 📋 Workflow

### 1. Initial Setup (One-Time)

Create the public installation repository:

```bash
# Create new public repository on GitHub
https://github.com/lama-ai-RFQ/RFQinstallation

# Initialize with README_RFQinstallation_repo.md content
```

### 2. Creating a Release

```powershell
# 1. Build Windows application
cd windows
.\build_windows_exe.ps1

# 2. Prepare installer package
cd installation
.\prepare_installer_package.ps1 -SourcePath "..\..\dist\RFQ_Application" -Version "3.0.815"

# 3. Upload to GitHub releases
# - Go to https://github.com/lama-ai-RFQ/RFQinstallation/releases/new
# - Upload RFQ-windows-installer-v3.0.815.zip
# - Upload download_and_install.ps1
# - Upload install.bat
# - Publish release
```

### 3. User Installation Flow

```
User downloads → download_and_install.ps1
       ↓
Script fetches → RFQ-windows-installer-vX.X.XXX.zip from GitHub
       ↓
Extracts to → %LOCALAPPDATA%\RFQApplication
       ↓
Creates .env → with GITHUB_PAT for updates
       ↓
User launches → RFQ_Application.exe
       ↓
Future updates → via built-in update manager (from private repo)
```

## 🔧 Script Details

### prepare_installer_package.ps1

**Purpose**: Packages your built Windows application into a clean ZIP file.

**Features**:
- Copies application files
- Excludes unnecessary files (logs, cache, temp files)
- Creates version.txt
- Creates .env.template
- Produces ZIP ready for GitHub release

**Usage**:
```powershell
.\prepare_installer_package.ps1 -SourcePath "path\to\build" -Version "3.0.815"
```

### download_and_install.ps1

**Purpose**: End-user installer that downloads and installs the application.

**Features**:
- Downloads latest release from GitHub
- Validates prerequisites (PowerShell version, disk space)
- Extracts to installation directory
- Configures .env with GitHub PAT
- Creates desktop shortcut
- Provides progress indicators

**Usage**:
```powershell
.\download_and_install.ps1 -GitHubToken "ghp_xxxxx"
.\download_and_install.ps1 -InstallPath "C:\MyApps\RFQ" -GitHubToken "ghp_xxxxx"
```

### install.bat

**Purpose**: Simple batch wrapper for users uncomfortable with PowerShell.

**Usage**: Double-click to run

## 📝 File Exclusions

When preparing installer packages, these patterns are excluded:

- `*.pyc` - Python bytecode
- `__pycache__` - Python cache directories  
- `logs` - Log files
- `temp*` - Temporary files
- `*.log` - Individual log files
- `local_manifest.json` - Update manager state
- `updates` - Downloaded update files
- `backup` - Backup files
- `email_attachments` - User data
- `quotations` - User data
- `.git` - Git repository
- `.idea` - IDE settings
- `node_modules` - Node dependencies

## 🔐 Security

- **Public repo**: Contains installer scripts and packaged application
- **No secrets**: Never include GitHub PAT or passwords in installer
- **User-provided**: GitHub PAT is provided by user during installation
- **Local storage**: PAT stored in `.env` file locally (not in repo)

## 📚 Documentation

- `README_RFQinstallation_repo.md` - Setup instructions for the public GitHub repo
- `USER_QUICK_START.md` - End-user installation guide
- This file - Developer/maintainer reference

## 🆘 Troubleshooting

### Script execution blocked

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
```

### Package too large for GitHub

- GitHub has 2 GB file limit
- If installer exceeds this, consider:
  - Splitting into multiple parts
  - Hosting on alternative service
  - Using Git LFS for release assets

### Installation fails

- Check logs created by installer
- Verify disk space (4 GB minimum)
- Ensure PowerShell 5.1+
- Check antivirus settings

## 🔗 Related

- Main build script: `../build_windows_exe.ps1`
- Component upload script: `../push_windows_exe_components.ps1`
- Update manager: `../../backend/main/windows_update_manager.py`

## 📞 Support

For issues with:
- **Installation scripts**: Check this directory
- **Build process**: See `windows/README.md`
- **Updates**: See `../../backend/main/windows_update_manager.py`

