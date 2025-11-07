# RFQ Application - Windows Installer (Developer Guide)

This directory contains the Inno Setup installer script for creating the Windows installer.

## 📁 Directory Contents

| File | Purpose |
|------|---------|
| `setup.iss` | Inno Setup installer script - compiles to `RFQ_Application_Setup.exe` |
| `download_and_install.ps1` | PowerShell script used by the installer to download and install components |
| `USER_QUICK_START.md` | End-user installation guide |

## 🚀 Creating the Installer

### Prerequisites

- Inno Setup 6.x installed
- Built Windows application (from PyInstaller or your build process)
- GitHub Personal Access Token (for downloading from private repo)

### Build Process

1. **Build your Windows application** (using PyInstaller or your build process)

2. **Compile the installer**:
   - Open `setup.iss` in Inno Setup Compiler
   - Or use command line:
     ```powershell
     "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" setup.iss
     ```

3. **Output**: `installer_output\RFQ_Application_Setup.exe`

4. **Upload to GitHub releases**:
   - Go to your GitHub releases page
   - Create a new release with version tag
   - Upload `RFQ_Application_Setup.exe`
   - Publish release

### Installer Features

The Inno Setup installer (`setup.iss`) provides:
- ✅ Directory selection page
- ✅ GitHub token input (mandatory)
- ✅ AWS credentials input (for model download)
- ✅ Model download option and path selection
- ✅ Database password configuration (Settings, Super User, RFQ User)
- ✅ Automatic component download from private GitHub repo
- ✅ Model download from AWS S3 (optional, ~30 GB)
- ✅ Desktop shortcut creation
- ✅ Progress display during installation

### For End Users

Users download `RFQ_Application_Setup.exe` from GitHub releases and run it. See `USER_QUICK_START.md` for detailed end-user instructions.

## 📋 Workflow

### Creating a Release

```powershell
# 1. Build Windows application
cd windows
.\build_windows_exe.ps1

# 2. Compile installer
cd installation
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" setup.iss

# 3. Upload to GitHub releases
# - Go to your GitHub releases page
# - Create new release with version tag
# - Upload installer_output\RFQ_Application_Setup.exe
# - Publish release
```

### User Installation Flow

```
User downloads → RFQ_Application_Setup.exe
       ↓
Runs installer → Collects configuration (GitHub token, AWS creds, passwords)
       ↓
Installer runs → download_and_install.ps1 script
       ↓
Downloads components → From private GitHub repo (component-based)
       ↓
Extracts to → Selected installation directory
       ↓
Creates .env → With all provided credentials
       ↓
Downloads model → From AWS S3 (optional, ~30 GB)
       ↓
User launches → RFQ_Application.exe
       ↓
Future updates → Via built-in update manager (from private repo)
```

## 🔧 Script Details

### setup.iss

**Purpose**: Inno Setup installer script that creates the Windows installer.

**Features**:
- Directory selection
- GitHub token input (mandatory)
- AWS credentials input
- Model download option and path selection
- Database password configuration
- Calls `download_and_install.ps1` to perform actual installation
- Creates desktop shortcut

**Compilation**:
```powershell
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" setup.iss
```

### download_and_install.ps1

**Purpose**: PowerShell script that performs the actual installation (called by the installer).

**Features**:
- Downloads components from private GitHub repo
- Validates prerequisites (PowerShell version, disk space)
- Extracts components to installation directory
- Configures .env with all provided credentials
- Downloads model from AWS S3 (optional)
- Creates desktop shortcut
- Provides progress indicators

**Parameters**:
- `-InstallPath`: Installation directory
- `-GitHubToken`: GitHub Personal Access Token (mandatory)
- `-OverwriteExisting`: Skip overwrite prompt
- `-ModelPath`: Model download directory (optional)
- `-AWSKey`, `-AWSSecret`, `-AWSRegion`: AWS credentials (optional)
- `-SettingsPassword`, `-SuperUserPassword`, `-RFQUserPassword`: Database passwords

## 🔐 Security

- **No secrets in installer**: Never include GitHub PAT or passwords in the installer
- **User-provided**: All credentials (GitHub token, AWS credentials, database passwords) are provided by user during installation
- **Local storage**: Credentials stored in `.env` file locally (not in repo or installer)
- **Private repo access**: Installer downloads from private GitHub repo using user-provided token

## 📚 Documentation

- `USER_QUICK_START.md` - End-user installation guide
- This file - Developer/maintainer reference

## 🆘 Troubleshooting

### Compilation Issues

**Problem**: Inno Setup compiler not found
**Solution**: Install Inno Setup 6.x from https://jrsoftware.org/isdl.php

**Problem**: Compilation errors in setup.iss
**Solution**: 
- Check syntax in setup.iss
- Verify all referenced files exist
- Check Inno Setup compiler output for specific errors

### Installation Issues

**Problem**: Installer fails to download components
**Solution**:
- Verify GitHub token is correct
- Check internet connection
- Ensure private repo access with the token

**Problem**: Model download fails
**Solution**:
- Verify AWS credentials are correct
- Check AWS S3 bucket permissions
- Ensure sufficient disk space (~30 GB for model)

**Problem**: Installation fails
**Solution**:
- Check logs in installation directory
- Verify disk space (4 GB minimum for app, 30 GB for model)
- Ensure PowerShell 5.1+ is installed
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

