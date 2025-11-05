# RFQ Application - Windows Quick Start Guide

## For End Users: Installing RFQ Application

### Prerequisites

- Windows 10 or 11 (64-bit)
- ~4 GB free disk space
- Internet connection
- GitHub Personal Access Token (for updates)

### Step 1: Get GitHub Personal Access Token

1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Give it a name: "RFQ Application"
4. Select scopes: `repo` (Full control of private repositories)
5. Click "Generate token"
6. **Copy the token immediately** (you won't see it again!)
   - Should look like: `ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

### Step 2: Download Installer

Go to: https://github.com/lama-ai-RFQ/RFQinstallation/releases/latest

Download ONE of these files:
- **Option A**: `download_and_install.ps1` (PowerShell script)
- **Option B**: `install.bat` (Batch file)

### Step 3: Run Installer

#### Option A: PowerShell Script

1. Open PowerShell (Right-click Start → Windows PowerShell)
2. Navigate to download folder:
   ```powershell
   cd Downloads
   ```
3. Run installer with your token:
   ```powershell
   .\download_and_install.ps1 -GitHubToken "ghp_your_token_here"
   ```

#### Option B: Batch File

1. Double-click `install.bat`
2. You'll be prompted for GitHub token
3. Follow on-screen instructions

### Step 4: Launch Application

After installation completes:
- Launch from desktop shortcut: **RFQ Application**
- Or run from: `%LOCALAPPDATA%\RFQApplication\RFQ_Application.exe`

### Step 5: First-Time Setup

1. Application will start and open in your browser
2. Follow the setup wizard
3. Database will be created automatically
4. Default credentials will be provided

## Updating the Application

### Automatic Updates (Recommended)

1. Open RFQ Application
2. Go to **Settings** → **System Updates**
3. Click **"Check for Updates"**
4. If updates available, click **"Update"**
5. Wait for download and installation
6. Application will restart automatically

### Manual Update

If automatic update fails, re-run the installer with a newer version.

## Troubleshooting

### Installation Fails

**Problem**: "PowerShell execution policy" error
**Solution**: 
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass
```

**Problem**: "Not enough disk space"
**Solution**: Free up at least 4 GB on your drive

**Problem**: "Failed to download" error
**Solution**: 
- Check internet connection
- Verify GitHub token is correct
- Try again in a few minutes

### Application Won't Start

1. Check logs in: `%LOCALAPPDATA%\RFQApplication\logs\`
2. Try running as Administrator
3. Check antivirus isn't blocking the .exe
4. Reinstall application

### Updates Not Working

**Problem**: "Unknown" version shown
**Solution**: 
1. Open `%LOCALAPPDATA%\RFQApplication\.env`
2. Check `GITHUB_PAT=your_token_here` is correct
3. Restart application

**Problem**: Update download fails
**Solution**:
1. Verify GitHub token hasn't expired
2. Check internet connection
3. Try manual update (re-run installer)

## Uninstalling

1. Close RFQ Application
2. Delete folder: `%LOCALAPPDATA%\RFQApplication`
3. Delete desktop shortcut (if exists)
4. Remove PostgreSQL database (if installed separately):
   ```sql
   DROP DATABASE rfq_db;
   ```

## Support

- Documentation: See `README_Windows.md` in installation folder
- Installation Issues: https://github.com/lama-ai-RFQ/RFQinstallation/issues
- Application Issues: Check application logs

## Advanced Options

### Custom Installation Path

```powershell
.\download_and_install.ps1 -InstallPath "C:\MyApps\RFQ" -GitHubToken "ghp_xxx"
```

### Silent Installation (No Prompts)

```powershell
.\download_and_install.ps1 -GitHubToken "ghp_xxx" -Confirm:$false
```

### Offline Installation

1. Download installer ZIP from: https://github.com/lama-ai-RFQ/RFQinstallation/releases/latest
2. Extract to desired location
3. Create `.env` file with GitHub token
4. Run `RFQ_Application.exe`

## Security Notes

- ✅ GitHub PAT is stored locally on your computer only
- ✅ PAT is never transmitted except to GitHub for updates
- ✅ Keep your PAT private (don't share it)
- ✅ You can revoke PAT anytime at: https://github.com/settings/tokens
- ⚠️ Don't commit `.env` file to any repository

## FAQ

**Q: Do I need a GitHub account?**
A: Yes, you need a GitHub account to generate a Personal Access Token for updates.

**Q: Is this free?**
A: Installation is free. Check application license for usage terms.

**Q: Can I install on multiple computers?**
A: Yes, use the same installer on each computer. You can use the same GitHub PAT or generate separate ones.

**Q: How often are updates released?**
A: Check the updates page or enable automatic update notifications in the application.

**Q: What if I lose my GitHub token?**
A: Generate a new one and update the `.env` file in your installation directory.

