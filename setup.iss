; Inno Setup Script for RFQ Application
; This creates a graphical installer that wraps the PowerShell installation script

#define MyAppName "RFQ Application"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "LAMAAI Ventures LLC"
#define MyAppURL "https://github.com/lama-ai-RFQ"
#define MyAppExeName "RFQ_Application.exe"

[Setup]
; NOTE: The value of AppId uniquely identifies this application. Do not use the same AppId value in installers for other applications.
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
; Default installation directory - user can change on directory selection page
; {autopf} expands to "C:\Program Files" on 64-bit systems
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Show directory selection page so user can see and modify install location
DisableDirPage=no
LicenseFile=
InfoBeforeFile=
InfoAfterFile=
OutputDir=installer_output
OutputBaseFilename=RFQ_Application_Setup
SetupIconFile=
Compression=lzma
SolidCompression=yes
WizardStyle=modern
; Slightly larger wizard (130%) so custom pages have enough room on Windows 11 high-DPI/scaled displays
WizardSizePercent=130,130
; Allow user to resize if content is still tight
WizardResizable=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "quicklaunchicon"; Description: "{cm:CreateQuickLaunchIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked; OnlyBelowVersion: 6.1; Check: not IsAdminInstallMode

[Files]
; Include the PowerShell installation script
Source: "download_and_install.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "aws_helpers.py"; DestDir: "{tmp}"; Flags: ignoreversion
; Include any other necessary files
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "USER_QUICK_START.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "env.template"; DestDir: "{app}"; DestName: ".env.template"; Flags: ignoreversion
Source: "setup_database_auto.ps1"; DestDir: "{app}"; Flags: ignoreversion
; Include NSSM for service creation
Source: "nssm.exe"; DestDir: "{pf}\nssm"; Flags: ignoreversion
Source: "nssm.exe"; DestDir: "{app}"; Flags: ignoreversion
; MVP updater bootstrap + v1 logic bundle. The download_and_install.ps1 script
; extracts the bundle into <install>/updater-logic/v1/ and plants
; <install>/state/updater-active-version.txt after creating RFQUpdaterService.
; The migration helper is bundled for future bootstrap-version upgrades
; triggered by a subsequent installer build.
Source: "windows_updater.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "updater_migration.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "updater-logic-v1-bundle.zip"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: quicklaunchicon

[Run]
; Run the PowerShell installation script
; Show PowerShell window so user can see download progress
; Parameters will be built dynamically in CurStepChanged
Filename: "powershell.exe"; \
    Parameters: "{code:GetPowerShellParams}"; \
    StatusMsg: "Installing RFQ Application and creating Windows service..."; \
    Flags: waituntilterminated; \
    Description: "{code:GetInstallDescription}"

[Code]
var
  DependencyCheckPage: TWizardPage;
  DependencyCheckLabel: TLabel;
  PostgreSQLLabel: TLabel;
  PythonLabel: TLabel;
  NSSMLabel: TLabel;
  ServiceInfoPage: TWizardPage;
  ServiceInfoLabel: TLabel;
  CleanReinstallPage: TInputOptionWizardPage;
  CleanupCheckbox: TCheckBox;
  GitHubTokenPage: TInputQueryWizardPage;
  AWSKeyPage: TInputQueryWizardPage;
  AWSSecretPage: TInputQueryWizardPage;
  AWSRegionPage: TInputQueryWizardPage;
  ModelDownloadPage: TInputOptionWizardPage;
  ModelPathPage: TInputDirWizardPage;
  SettingsPasswordPage: TInputQueryWizardPage;
  SuperUserPasswordPage: TInputQueryWizardPage;
  RFQUserPasswordPage: TInputQueryWizardPage;
  ServerURLPage: TInputQueryWizardPage;
  AzureKeyPage: TInputOptionWizardPage;
  AzureKeyInputPage: TInputQueryWizardPage;
  CredentialManagerPage: TInputOptionWizardPage;
  ServiceAccountPage: TInputOptionWizardPage;
  ServiceAccountWarningLabel: TLabel;
  // Password visibility checkboxes
  AWSSecretShowCheck: TNewCheckBox;
  SettingsPasswordShowCheck: TNewCheckBox;
  SuperUserPasswordShowCheck: TNewCheckBox;
  RFQUserPasswordShowCheck: TNewCheckBox;
  // "Already stored in WCM" checkboxes
  SettingsPasswordAlreadyStoredCheck: TNewCheckBox;
  SuperUserPasswordAlreadyStoredCheck: TNewCheckBox;
  RFQUserPasswordAlreadyStoredCheck: TNewCheckBox;

procedure AWSSecretShowCheckClick(Sender: TObject);
begin
  AWSSecretPage.Edits[0].Password := not AWSSecretShowCheck.Checked;
end;

procedure SettingsPasswordShowCheckClick(Sender: TObject);
begin
  SettingsPasswordPage.Edits[0].Password := not SettingsPasswordShowCheck.Checked;
end;

procedure SuperUserPasswordShowCheckClick(Sender: TObject);
begin
  SuperUserPasswordPage.Edits[0].Password := not SuperUserPasswordShowCheck.Checked;
end;

procedure RFQUserPasswordShowCheckClick(Sender: TObject);
begin
  RFQUserPasswordPage.Edits[0].Password := not RFQUserPasswordShowCheck.Checked;
end;

function ReadEnvValue(FilePath: String; Key: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Line: String;
  EqualPos: Integer;
  LineKey: String;
begin
  Result := '';
  
  if not FileExists(FilePath) then
    Exit;
  
  if LoadStringsFromFile(FilePath, Lines) then
  begin
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      Line := Trim(Lines[I]);
      
      // Skip empty lines and comments
      if (Length(Line) = 0) or (Copy(Line, 1, 1) = '#') then
        Continue;
      
      // Find the '=' separator
      EqualPos := Pos('=', Line);
      if EqualPos > 0 then
      begin
        LineKey := Trim(Copy(Line, 1, EqualPos - 1));
        if CompareText(LineKey, Key) = 0 then
        begin
          Result := Trim(Copy(Line, EqualPos + 1, Length(Line)));
          Exit;
        end;
      end;
    end;
  end;
end;

function ValidatePassword(Password: String; PasswordName: String): Boolean;
var
  HasUpper, HasLower, HasDigit, HasSpecial: Boolean;
  i: Integer;
  ch: Char;
begin
  Result := False;
  
  // Check minimum length
  if Length(Password) < 8 then
  begin
    MsgBox(PasswordName + ' must be at least 8 characters long.', mbError, MB_OK);
    Exit;
  end;
  
  // Check for complexity requirements
  HasUpper := False;
  HasLower := False;
  HasDigit := False;
  HasSpecial := False;
  
  for i := 1 to Length(Password) do
  begin
    ch := Password[i];
    if (ch >= 'A') and (ch <= 'Z') then
      HasUpper := True
    else if (ch >= 'a') and (ch <= 'z') then
      HasLower := True
    else if (ch >= '0') and (ch <= '9') then
      HasDigit := True
    else if (ch = '!') or (ch = '@') or (ch = '#') or (ch = '$') or (ch = '%') or 
            (ch = '^') or (ch = '&') or (ch = '*') or (ch = '(') or (ch = ')') or
            (ch = '-') or (ch = '_') or (ch = '=') or (ch = '+') or (ch = '[') or
            (ch = ']') or (ch = '{') or (ch = '}') or (ch = '|') or (ch = '\') or
            (ch = ';') or (ch = ':') or (ch = '"') or (ch = '''') or (ch = '<') or
            (ch = '>') or (ch = ',') or (ch = '.') or (ch = '?') or (ch = '/') then
      HasSpecial := True;
  end;
  
  // Require at least 3 out of 4 character types
  if ((Ord(HasUpper) + Ord(HasLower) + Ord(HasDigit) + Ord(HasSpecial)) < 3) then
  begin
    MsgBox(PasswordName + ' must contain at least 3 of the following:' + #13#10 +
           '  - Uppercase letters (A-Z)' + #13#10 +
           '  - Lowercase letters (a-z)' + #13#10 +
           '  - Numbers (0-9)' + #13#10 +
           '  - Special characters (!@#$%^&*()_+-=[]{}|;:,.<>?/)', 
           mbError, MB_OK);
    Exit;
  end;
  
  Result := True;
end;

function CheckPostgreSQLInPath(): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  
  // Check if psql.exe is in PATH using 'where' command
  if Exec('cmd.exe', '/c where psql >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Result := (ResultCode = 0);
    Exit;
  end;
end;

function CheckPostgreSQLInstalled(): Boolean;
var
  PsqlPath: String;
  RegPath: String;
  RegValue: String;
begin
  Result := False;
  
  // Check PostgreSQL registry keys for installation path
  // PostgreSQL typically stores installation info in registry
  RegPath := 'SOFTWARE\PostgreSQL\Installations';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, RegPath, 'Base Directory', RegValue) then
  begin
    PsqlPath := RegValue + '\bin\psql.exe';
    if FileExists(PsqlPath) then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  // Check common PostgreSQL installation locations
  // Try common version paths
  PsqlPath := ExpandConstant('{pf}\PostgreSQL\16\bin\psql.exe');
  if FileExists(PsqlPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PsqlPath := ExpandConstant('{pf}\PostgreSQL\15\bin\psql.exe');
  if FileExists(PsqlPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PsqlPath := ExpandConstant('{pf}\PostgreSQL\14\bin\psql.exe');
  if FileExists(PsqlPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PsqlPath := ExpandConstant('{pf}\PostgreSQL\13\bin\psql.exe');
  if FileExists(PsqlPath) then
  begin
    Result := True;
    Exit;
  end;
  
  // Check Program Files (x86)
  PsqlPath := ExpandConstant('{pf32}\PostgreSQL\16\bin\psql.exe');
  if FileExists(PsqlPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PsqlPath := ExpandConstant('{pf32}\PostgreSQL\15\bin\psql.exe');
  if FileExists(PsqlPath) then
  begin
    Result := True;
    Exit;
  end;
end;

function CheckNSSMInstalled(): Boolean;
var
  ResultCode: Integer;
  NSSMPath: String;
begin
  Result := False;
  
  // Check if nssm.exe is in PATH using 'where' command
  if Exec('cmd.exe', '/c where nssm >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  // Check common NSSM installation locations
  NSSMPath := ExpandConstant('{pf}\nssm\nssm.exe');
  if FileExists(NSSMPath) then
  begin
    Result := True;
    Exit;
  end;
  
  NSSMPath := ExpandConstant('{pf32}\nssm\nssm.exe');
  if FileExists(NSSMPath) then
  begin
    Result := True;
    Exit;
  end;
end;

function CheckPythonInstalled(): Boolean;
var
  ResultCode: Integer;
  PythonPath: String;
  RegPath: String;
  RegValue: String;
begin
  Result := False;
  
  // Check if python.exe is in PATH using 'where' command
  if Exec('cmd.exe', '/c where python >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  // Check Python registry keys for common versions
  // Python typically stores installation info in registry
  RegPath := 'SOFTWARE\Python\PythonCore\3.12\InstallPath';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, RegPath, '', RegValue) then
  begin
    PythonPath := RegValue + 'python.exe';
    if FileExists(PythonPath) then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  RegPath := 'SOFTWARE\Python\PythonCore\3.11\InstallPath';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, RegPath, '', RegValue) then
  begin
    PythonPath := RegValue + 'python.exe';
    if FileExists(PythonPath) then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  RegPath := 'SOFTWARE\Python\PythonCore\3.10\InstallPath';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, RegPath, '', RegValue) then
  begin
    PythonPath := RegValue + 'python.exe';
    if FileExists(PythonPath) then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  // Check 32-bit registry
  RegPath := 'SOFTWARE\WOW6432Node\Python\PythonCore\3.12\InstallPath';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, RegPath, '', RegValue) then
  begin
    PythonPath := RegValue + 'python.exe';
    if FileExists(PythonPath) then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  RegPath := 'SOFTWARE\WOW6432Node\Python\PythonCore\3.11\InstallPath';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, RegPath, '', RegValue) then
  begin
    PythonPath := RegValue + 'python.exe';
    if FileExists(PythonPath) then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  RegPath := 'SOFTWARE\WOW6432Node\Python\PythonCore\3.10\InstallPath';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, RegPath, '', RegValue) then
  begin
    PythonPath := RegValue + 'python.exe';
    if FileExists(PythonPath) then
    begin
      Result := True;
      Exit;
    end;
  end;
  
  // Check common Python installation locations
  // Try common version paths
  PythonPath := ExpandConstant('{pf}\Python312\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{pf}\Python311\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{pf}\Python310\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{pf}\Python39\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{pf}\Python38\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  // Check Program Files (x86)
  PythonPath := ExpandConstant('{pf32}\Python312\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{pf32}\Python311\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{pf32}\Python310\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  // Check user installation locations
  PythonPath := ExpandConstant('{localappdata}\Programs\Python\Python312\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{localappdata}\Programs\Python\Python311\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  PythonPath := ExpandConstant('{localappdata}\Programs\Python\Python310\python.exe');
  if FileExists(PythonPath) then
  begin
    Result := True;
    Exit;
  end;
  
  // Check common alternative locations
  if FileExists('C:\Python312\python.exe') then
  begin
    Result := True;
    Exit;
  end;
  
  if FileExists('C:\Python311\python.exe') then
  begin
    Result := True;
    Exit;
  end;
  
  if FileExists('C:\Python310\python.exe') then
  begin
    Result := True;
    Exit;
  end;
end;

function DownloadNSSM(): Boolean;
var
  NSSMUrl: String;
  NSSMExe: String;
  NSSMTargetDir: String;
  ResultCode: Integer;
  PowerShellScript: String;
begin
  Result := False;
  
  // NSSM download URL (latest stable release - x64)
  // Check https://nssm.cc/download for the latest version
  NSSMUrl := 'https://nssm.cc/release/nssm-2.24.zip';
  NSSMExe := ExpandConstant('{tmp}\nssm.exe');
  NSSMTargetDir := ExpandConstant('{pf}\nssm');
  
  try
    Log('Downloading NSSM from ' + NSSMUrl);
    
    // Use PowerShell to download NSSM
    // NSSM is distributed as a ZIP file, we need to extract nssm.exe from win64 folder
    PowerShellScript := '-NoProfile -ExecutionPolicy Bypass -Command "' +
      'try { ' +
      '  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ' +
      '  $zipPath = ''' + ExpandConstant('{tmp}\nssm.zip') + '''; ' +
      '  Invoke-WebRequest -Uri ''' + NSSMUrl + ''' -OutFile $zipPath -UseBasicParsing; ' +
      '  Expand-Archive -Path $zipPath -DestinationPath ''' + ExpandConstant('{tmp}\nssm') + ''' -Force; ' +
      '  $nssmExe = Get-ChildItem -Path ''' + ExpandConstant('{tmp}\nssm') + ''' -Recurse -Filter ''nssm.exe'' | Select-Object -First 1; ' +
      '  if ($nssmExe) { Copy-Item $nssmExe.FullName ''' + NSSMExe + ''' -Force; Write-Host ''DOWNLOADED'' } else { Write-Host ''FAILED''; exit 1 } ' +
      '} catch { Write-Host ''FAILED''; exit 1 }"';
    
    if Exec('powershell.exe', PowerShellScript, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    begin
      if ResultCode <> 0 then
      begin
        Log('Failed to download NSSM: PowerShell returned error code ' + IntToStr(ResultCode));
        Exit;
      end;
    end
    else
    begin
      Log('Failed to download NSSM: Could not execute PowerShell');
      Exit;
    end;
    
    if not FileExists(NSSMExe) then
    begin
      Log('NSSM exe file not found after download');
      Exit;
    end;
    
    Log('Downloaded NSSM successfully');
    
    // Create target directory
    if not DirExists(NSSMTargetDir) then
    begin
      if not CreateDir(NSSMTargetDir) then
      begin
        Log('Failed to create NSSM directory: ' + NSSMTargetDir);
        Exit;
      end;
    end;
    
    // Copy nssm.exe to Program Files
    if FileCopy(NSSMExe, NSSMTargetDir + '\nssm.exe', False) then
    begin
      Result := True;
      Log('NSSM downloaded and installed successfully to ' + NSSMTargetDir);
    end
    else
    begin
      Log('Failed to copy nssm.exe to ' + NSSMTargetDir);
    end;
    
    // Cleanup
    DeleteFile(NSSMExe);
    DeleteFile(ExpandConstant('{tmp}\nssm.zip'));
    
  except
    Log('Exception while downloading NSSM: ' + GetExceptionMessage);
    Result := False;
  end;
end;

function InitializeSetup(): Boolean;
begin
  // Dependencies will be checked and shown on the dependency check page
  Result := True;
end;

procedure InitializeWizard;
var
  StatusText: String;
  PostgreSQLStatus: String;
  PythonStatus: String;
  NSSMStatus: String;
begin
  // Create dependency check page - appears FIRST
  DependencyCheckPage := CreateCustomPage(wpWelcome,
    'System Requirements Check', 'Checking for required dependencies...');
  
  // Create header label
  DependencyCheckLabel := TLabel.Create(DependencyCheckPage);
  DependencyCheckLabel.Parent := DependencyCheckPage.Surface;
  DependencyCheckLabel.Left := 0;
  DependencyCheckLabel.Top := 0;
  DependencyCheckLabel.Width := DependencyCheckPage.SurfaceWidth;
  DependencyCheckLabel.Height := ScaleY(30);
  DependencyCheckLabel.AutoSize := False;
  DependencyCheckLabel.WordWrap := True;
  DependencyCheckLabel.Font.Size := 9;
  DependencyCheckLabel.Caption := 'Checking system requirements...' + #13#10;
  
  // Create individual labels for each dependency with individual colors
  PostgreSQLLabel := TLabel.Create(DependencyCheckPage);
  PostgreSQLLabel.Parent := DependencyCheckPage.Surface;
  PostgreSQLLabel.Left := 0;
  PostgreSQLLabel.Top := ScaleY(30);
  PostgreSQLLabel.Width := DependencyCheckPage.SurfaceWidth;
  PostgreSQLLabel.Height := ScaleY(20);
  PostgreSQLLabel.AutoSize := False;
  PostgreSQLLabel.Font.Size := 9;
  if CheckPostgreSQLInPath() then
  begin
    PostgreSQLLabel.Caption := '✓ PostgreSQL: Installed (Found in PATH)';
    PostgreSQLLabel.Font.Color := clGreen;
  end
  else if CheckPostgreSQLInstalled() then
  begin
    PostgreSQLLabel.Caption := '⚠ PostgreSQL: Installed but NOT in PATH (psql not found)';
    PostgreSQLLabel.Font.Color := clRed;
  end
  else
  begin
    PostgreSQLLabel.Caption := '✗ PostgreSQL: Not found';
    PostgreSQLLabel.Font.Color := clRed;
  end;
  
  PythonLabel := TLabel.Create(DependencyCheckPage);
  PythonLabel.Parent := DependencyCheckPage.Surface;
  PythonLabel.Left := 0;
  PythonLabel.Top := ScaleY(50);
  PythonLabel.Width := DependencyCheckPage.SurfaceWidth;
  PythonLabel.Height := ScaleY(20);
  PythonLabel.AutoSize := False;
  PythonLabel.Font.Size := 9;
  if CheckPythonInstalled() then
  begin
    PythonLabel.Caption := '✓ Python: Installed';
    PythonLabel.Font.Color := clGreen;
  end
  else
  begin
    PythonLabel.Caption := '✗ Python: Not found';
    PythonLabel.Font.Color := clRed;
  end;
  
  NSSMLabel := TLabel.Create(DependencyCheckPage);
  NSSMLabel.Parent := DependencyCheckPage.Surface;
  NSSMLabel.Left := 0;
  NSSMLabel.Top := ScaleY(70);
  NSSMLabel.Width := DependencyCheckPage.SurfaceWidth;
  NSSMLabel.Height := ScaleY(20);
  NSSMLabel.AutoSize := False;
  NSSMLabel.Font.Size := 9;
  if CheckNSSMInstalled() then
  begin
    NSSMLabel.Caption := '✓ NSSM: Installed';
    NSSMLabel.Font.Color := clGreen;
  end
  else
  begin
    NSSMLabel.Caption := '⚠ NSSM: Not found (will be installed automatically)';
    NSSMLabel.Font.Color := clWindowText;
  end;
  
  // Build footer text with only missing dependencies
  // Note: NSSM is bundled with the installer, so it's not required to be pre-installed
  StatusText := '';
  if CheckPostgreSQLInPath() and CheckOpenSSLInPath() and CheckPythonInstalled() then
  begin
    StatusText := StatusText + #13#10 + 'All required dependencies are installed.' + #13#10;
    StatusText := StatusText + 'You can proceed with the installation.';
    if not CheckNSSMInstalled() then
    begin
      StatusText := StatusText + #13#10 + #13#10;
      StatusText := StatusText + 'Note: NSSM is bundled with this installer and will be installed automatically.';
    end;
  end
  else
  begin
    StatusText := StatusText + #13#10 + 'Some required dependencies are missing or not available in PATH.' + #13#10;
    StatusText := StatusText + 'You cannot proceed until these commands work in Command Prompt:' + #13#10;
    StatusText := StatusText + '  where psql' + #13#10;
    StatusText := StatusText + '  where openssl' + #13#10 + #13#10;
    StatusText := StatusText + 'Fix instructions:' + #13#10;
    if CheckPostgreSQLInstalled() and (not CheckPostgreSQLInPath()) then
      StatusText := StatusText + 'PostgreSQL is installed but psql.exe is not in PATH. Add PostgreSQL bin (e.g. C:\Program Files\PostgreSQL\16\bin) to PATH.' + #13#10;
    if not CheckPostgreSQLInstalled() then
      StatusText := StatusText + 'Install PostgreSQL: https://www.postgresql.org/download/windows/' + #13#10;
    if CheckOpenSSLInstalled() and (not CheckOpenSSLInPath()) then
      StatusText := StatusText + 'OpenSSL is installed but openssl.exe is not in PATH. Add OpenSSL bin (e.g. C:\Program Files\OpenSSL-Win64\bin) to PATH.' + #13#10;
    if not CheckOpenSSLInstalled() then
      StatusText := StatusText + 'Install OpenSSL: https://slproweb.com/products/Win32OpenSSL.html' + #13#10;
    if not CheckPythonInstalled() then
      StatusText := StatusText + 'Install Python: https://www.python.org/downloads/' + #13#10;
    StatusText := StatusText + #13#10;
    StatusText := StatusText + 'Note: NSSM is bundled with this installer and will be installed automatically.' + #13#10;
    StatusText := StatusText + #13#10;
    StatusText := StatusText + 'After fixing PATH, restart this installer (new processes are required to pick up PATH changes).';
  end;
  
  DependencyCheckLabel.Caption := DependencyCheckLabel.Caption + StatusText;
  
  // Create Windows Service Information page - appears AFTER dependency check
  ServiceInfoPage := CreateCustomPage(DependencyCheckPage.ID,
    'Windows Service Information', 'The installer will create a Windows service');
  
  ServiceInfoLabel := TLabel.Create(ServiceInfoPage);
  ServiceInfoLabel.Parent := ServiceInfoPage.Surface;
  ServiceInfoLabel.Left := 0;
  ServiceInfoLabel.Top := 0;
  ServiceInfoLabel.Width := ServiceInfoPage.SurfaceWidth;
  ServiceInfoLabel.Height := ServiceInfoPage.SurfaceHeight;
  ServiceInfoLabel.AutoSize := False;
  ServiceInfoLabel.WordWrap := True;
  ServiceInfoLabel.Font.Size := 9;
  
  StatusText := 'Windows Service Creation' + #13#10 + #13#10;
  StatusText := StatusText + 'The installer will automatically create a Windows service named:' + #13#10;
  StatusText := StatusText + '  Service Name: RFQapplication' + #13#10;
  StatusText := StatusText + '  Display Name: RFQ Application Service' + #13#10 + #13#10;
  StatusText := StatusText + 'Service Configuration:' + #13#10;
  StatusText := StatusText + '  • The service will be set to start automatically on system boot' + #13#10;
  StatusText := StatusText + '  • The service can be started/stopped manually if needed' + #13#10;
  StatusText := StatusText + '  • Administrator privileges are required to create the service' + #13#10 + #13#10;
  StatusText := StatusText + 'Managing the Service:' + #13#10;
  StatusText := StatusText + '  • Command Line: sc start/stop RFQapplication' + #13#10;
  StatusText := StatusText + '  • GUI: Open Services.msc and look for "RFQ Application Service"' + #13#10 + #13#10;
  StatusText := StatusText + 'Note: If the service fails to start automatically, you may need to' + #13#10;
  StatusText := StatusText + 'install NSSM (Non-Sucking Service Manager) for better compatibility.' + #13#10;
  
  ServiceInfoLabel.Font.Color := clNavy;
  ServiceInfoLabel.Caption := StatusText;
  
  // Create Clean Reinstall page - appears AFTER directory selection
  CleanReinstallPage := CreateInputOptionPage(wpSelectDir,
    'Installation Options', 'Clean Reinstall',
    'Choose whether to perform a clean reinstall (delete existing downloads) or reuse existing downloads.' + #13#10 + #13#10 +
    'Clean reinstall will delete any previously downloaded files and download everything fresh.' + #13#10 +
    'Reusing downloads will skip files that are already downloaded with the correct size.',
    True, False);
  CleanReinstallPage.Add('Clean reinstall (delete existing downloads) - Recommended');
  CleanReinstallPage.Add('Reuse existing downloads (faster if files are already downloaded)');
  CleanReinstallPage.SelectedValueIndex := 0;  // Default to clean reinstall (true)
  
  // Add a separate checkbox for cleanup after installation
  CleanupCheckbox := TCheckBox.Create(CleanReinstallPage);
  CleanupCheckbox.Parent := CleanReinstallPage.Surface;
  CleanupCheckbox.Left := 0;
  CleanupCheckbox.Top := ScaleY(200);
  CleanupCheckbox.Width := CleanReinstallPage.SurfaceWidth;
  CleanupCheckbox.Height := ScaleY(24);
  CleanupCheckbox.Caption := 'Cleanup download directory after extraction (recommended - saves disk space)';
  CleanupCheckbox.Checked := True;  // Default to cleanup enabled
  
  // Create GitHub Token page - appears AFTER service info page
  GitHubTokenPage := CreateInputQueryPage(CleanReinstallPage.ID,
    'GitHub Authentication', 'GitHub Personal Access Token Required',
    'The installation package is in a private repository and requires authentication.' + #13#10 +
    'Please enter your GitHub Personal Access Token:');
  GitHubTokenPage.Add('GitHub Token:', False);

  // Create AWS credentials pages
  AWSKeyPage := CreateInputQueryPage(GitHubTokenPage.ID,
    'AWS Credentials', 'AWS S3 Access Required',
    'The application requires downloading a language model from AWS S3.' + #13#10 +
    'Please enter your AWS credentials:');
  AWSKeyPage.Add('AWS Access Key ID:', False);
  
  // Create AWS Secret page (using TInputQueryWizardPage with password masking)
  AWSSecretPage := CreateInputQueryPage(AWSKeyPage.ID,
    'AWS Secret Key', 'AWS Secret Access Key',
    'Please enter your AWS Secret Access Key:');
  AWSSecretPage.Add('AWS Secret Access Key:', True);  // True = password field (masked)
  
  // Add "Show password" checkbox
  AWSSecretShowCheck := TNewCheckBox.Create(WizardForm);
  AWSSecretShowCheck.Parent := AWSSecretPage.Surface;
  AWSSecretShowCheck.Top := AWSSecretPage.Edits[0].Top + AWSSecretPage.Edits[0].Height + ScaleY(8);
  AWSSecretShowCheck.Left := AWSSecretPage.Edits[0].Left;
  AWSSecretShowCheck.Height := ScaleY(24);
  AWSSecretShowCheck.Caption := '&Show password';
  AWSSecretShowCheck.OnClick := @AWSSecretShowCheckClick;
  
  AWSRegionPage := CreateInputQueryPage(AWSSecretPage.ID,
    'AWS Region', 'AWS Region Configuration',
    'Please enter your AWS Region (default: us-east-1):');
  AWSRegionPage.Add('AWS Region:', False);
  AWSRegionPage.Values[0] := 'us-east-1';

  // Create model download option page
  ModelDownloadPage := CreateInputOptionPage(AWSRegionPage.ID,
    'Model Download', 'Download Language Model',
    'The application requires the LLM (language model).' + #13#10 +
    'This is a LARGE download (~30 GB) and may take 30-60 minutes depending on your internet connection.',
    True, False);
  ModelDownloadPage.Add('Download model now (recommended)');
  ModelDownloadPage.Add('Skip download (download later)');
  ModelDownloadPage.SelectedValueIndex := 0;

  // Create model path page (if downloading)
  ModelPathPage := CreateInputDirPage(ModelDownloadPage.ID,
    'Model Location', 'Where should the model be downloaded?',
    'The model is LARGE (~30 GB). Select the directory where the model should be downloaded:' + #13#10 +
    '(Default: Documents\RFQ_Models)', False, '');
  ModelPathPage.Add('');
  
  // Create password pages
  SettingsPasswordPage := CreateInputQueryPage(ModelPathPage.ID,
    'Application Settings', 'Settings Password',
    'Enter a password used by the application to access its settings.' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  SettingsPasswordPage.Add('Settings Password:', True);  // True = password field (masked)
  
  // Add "Show password" checkbox
  SettingsPasswordShowCheck := TNewCheckBox.Create(WizardForm);
  SettingsPasswordShowCheck.Parent := SettingsPasswordPage.Surface;
  SettingsPasswordShowCheck.Top := SettingsPasswordPage.Edits[0].Top + SettingsPasswordPage.Edits[0].Height + ScaleY(8);
  SettingsPasswordShowCheck.Left := SettingsPasswordPage.Edits[0].Left;
  SettingsPasswordShowCheck.Height := ScaleY(24);
  SettingsPasswordShowCheck.Caption := '&Show password';
  SettingsPasswordShowCheck.OnClick := @SettingsPasswordShowCheckClick;
  
  // Add "Already stored in Windows Credential Manager" checkbox
  SettingsPasswordAlreadyStoredCheck := TNewCheckBox.Create(WizardForm);
  SettingsPasswordAlreadyStoredCheck.Parent := SettingsPasswordPage.Surface;
  SettingsPasswordAlreadyStoredCheck.Top := SettingsPasswordShowCheck.Top + SettingsPasswordShowCheck.Height + ScaleY(8);
  SettingsPasswordAlreadyStoredCheck.Left := SettingsPasswordPage.Edits[0].Left;
  SettingsPasswordAlreadyStoredCheck.Height := ScaleY(24);
  SettingsPasswordAlreadyStoredCheck.Caption := 'Already stored in Windows Credential Manager (skip setting)';
  SettingsPasswordAlreadyStoredCheck.Width := SettingsPasswordPage.SurfaceWidth;
  
  SuperUserPasswordPage := CreateInputQueryPage(SettingsPasswordPage.ID,
    'Database Configuration', 'PostgreSQL Super User Password',
    'Enter the PostgreSQL super user password (for database setup).' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  SuperUserPasswordPage.Add('PostgreSQL Super User Password:', True);  // True = password field (masked)
  
  // Add "Show password" checkbox
  SuperUserPasswordShowCheck := TNewCheckBox.Create(WizardForm);
  SuperUserPasswordShowCheck.Parent := SuperUserPasswordPage.Surface;
  SuperUserPasswordShowCheck.Top := SuperUserPasswordPage.Edits[0].Top + SuperUserPasswordPage.Edits[0].Height + ScaleY(8);
  SuperUserPasswordShowCheck.Left := SuperUserPasswordPage.Edits[0].Left;
  SuperUserPasswordShowCheck.Height := ScaleY(24);
  SuperUserPasswordShowCheck.Caption := '&Show password';
  SuperUserPasswordShowCheck.OnClick := @SuperUserPasswordShowCheckClick;
  
  // Add "Already stored in Windows Credential Manager" checkbox
  SuperUserPasswordAlreadyStoredCheck := TNewCheckBox.Create(WizardForm);
  SuperUserPasswordAlreadyStoredCheck.Parent := SuperUserPasswordPage.Surface;
  SuperUserPasswordAlreadyStoredCheck.Top := SuperUserPasswordShowCheck.Top + SuperUserPasswordShowCheck.Height + ScaleY(8);
  SuperUserPasswordAlreadyStoredCheck.Left := SuperUserPasswordPage.Edits[0].Left;
  SuperUserPasswordAlreadyStoredCheck.Height := ScaleY(24);
  SuperUserPasswordAlreadyStoredCheck.Caption := 'Already stored in Windows Credential Manager (skip setting)';
  SuperUserPasswordAlreadyStoredCheck.Width := SuperUserPasswordPage.SurfaceWidth;
  
  RFQUserPasswordPage := CreateInputQueryPage(SuperUserPasswordPage.ID,
    'Database Configuration', 'RFQ User Password',
    'Enter the password for the RFQ database user.' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  RFQUserPasswordPage.Add('RFQ User Password:', True);  // True = password field (masked)
  
  // Add "Show password" checkbox
  RFQUserPasswordShowCheck := TNewCheckBox.Create(WizardForm);
  RFQUserPasswordShowCheck.Parent := RFQUserPasswordPage.Surface;
  RFQUserPasswordShowCheck.Top := RFQUserPasswordPage.Edits[0].Top + RFQUserPasswordPage.Edits[0].Height + ScaleY(8);
  RFQUserPasswordShowCheck.Left := RFQUserPasswordPage.Edits[0].Left;
  RFQUserPasswordShowCheck.Height := ScaleY(24);
  RFQUserPasswordShowCheck.Caption := '&Show password';
  RFQUserPasswordShowCheck.OnClick := @RFQUserPasswordShowCheckClick;
  
  // Add "Already stored in Windows Credential Manager" checkbox
  RFQUserPasswordAlreadyStoredCheck := TNewCheckBox.Create(WizardForm);
  RFQUserPasswordAlreadyStoredCheck.Parent := RFQUserPasswordPage.Surface;
  RFQUserPasswordAlreadyStoredCheck.Top := RFQUserPasswordShowCheck.Top + RFQUserPasswordShowCheck.Height + ScaleY(8);
  RFQUserPasswordAlreadyStoredCheck.Left := RFQUserPasswordPage.Edits[0].Left;
  RFQUserPasswordAlreadyStoredCheck.Height := ScaleY(24);
  RFQUserPasswordAlreadyStoredCheck.Caption := 'Already stored in Windows Credential Manager (skip setting)';
  RFQUserPasswordAlreadyStoredCheck.Width := RFQUserPasswordPage.SurfaceWidth;
  
  // Create Server URL page
  ServerURLPage := CreateInputQueryPage(RFQUserPasswordPage.ID,
    'Server Configuration', 'Server URL',
    'Enter the server URL for OAuth redirects (default: https://localhost):');
  ServerURLPage.Add('Server URL:', False);
  ServerURLPage.Values[0] := 'https://localhost';
  
  // Create Azure Encryption Key page
  AzureKeyPage := CreateInputOptionPage(ServerURLPage.ID,
    'Azure Configuration', 'Azure Config Encryption Key',
    'The application uses an encryption key for Azure configuration.' + #13#10 +
    'You can generate this automatically or enter your own key manually.',
    True, False);
  AzureKeyPage.Add('Generate automatically (recommended)');
  AzureKeyPage.Add('Enter custom key manually');
  AzureKeyPage.SelectedValueIndex := 0;
  
  // Create Azure Key Input page (shown only if custom key is selected)
  AzureKeyInputPage := CreateInputQueryPage(AzureKeyPage.ID,
    'Azure Configuration', 'Custom Encryption Key',
    'Enter your custom Azure configuration encryption key (base64 encoded):');
  AzureKeyInputPage.Add('Azure Config Encryption Key:', False);
  
  // Create Windows Credential Manager page
  CredentialManagerPage := CreateInputOptionPage(AzureKeyInputPage.ID,
    'Password Storage', 'Windows Credential Manager',
    'Choose how to store critical passwords (Settings, PostgreSQL Super User, RFQ User):' + #13#10 + #13#10 +
    'Windows Credential Manager (Recommended):' + #13#10 +
    '  • Passwords stored securely in Windows Credential Manager' + #13#10 +
    '  • More secure than plain text .env file' + #13#10 +
    '  • Requires Windows Credential Manager to be available' + #13#10 + #13#10 +
    '.env File:' + #13#10 +
    '  • Passwords stored in .env file (plain text)' + #13#10 +
    '  • Less secure but more portable',
    True, False);
  CredentialManagerPage.Add('Use Windows Credential Manager (recommended - more secure)');
  CredentialManagerPage.Add('Store in .env file (less secure but portable)');
  CredentialManagerPage.SelectedValueIndex := 0;  // Default to Credential Manager
  
  // Create Windows Service Account page
  ServiceAccountPage := CreateInputOptionPage(CredentialManagerPage.ID,
    'Windows Service Configuration', 'Service Account Selection',
    'Choose which account the Windows service should run as:' + #13#10 + #13#10 +
    'The service account determines what permissions and resources the service can access.',
    True, False);
  ServiceAccountPage.Add('Current User (for Windows Credential Manager)');
  ServiceAccountPage.Add('Network Service');
  ServiceAccountPage.Add('Local System (SYSTEM)');
  ServiceAccountPage.SelectedValueIndex := 0;  // Default to Current User
  
  // Add warning label about Windows Credential Manager requirement
  // Position it below the option radio buttons (typically around ScaleY(200))
  ServiceAccountWarningLabel := TLabel.Create(ServiceAccountPage);
  ServiceAccountWarningLabel.Parent := ServiceAccountPage.Surface;
  ServiceAccountWarningLabel.Left := 0;
  ServiceAccountWarningLabel.Top := ScaleY(200);
  ServiceAccountWarningLabel.Width := ServiceAccountPage.SurfaceWidth;
  ServiceAccountWarningLabel.Height := ScaleY(60);
  ServiceAccountWarningLabel.AutoSize := False;
  ServiceAccountWarningLabel.WordWrap := True;
  ServiceAccountWarningLabel.Font.Size := 8;
  ServiceAccountWarningLabel.Font.Color := clMaroon;
  ServiceAccountWarningLabel.Caption := '⚠ WARNING: If you selected "Use Windows Credential Manager" on the previous page,' + #13#10 +
    'the service MUST run as "Current User" to access user-specific credentials.' + #13#10 +
    'If you choose Network Service or Local System, you will need to manually' + #13#10 +
    'change the service account to a user account after installation.';
end;

procedure LoadExistingEnvValues();
var
  EnvFilePath: String;
  ExistingGitHubToken: String;
  ExistingAWSKey: String;
  ExistingAWSSecret: String;
  ExistingAWSRegion: String;
  ExistingModelPath: String;
  ExistingServerURL: String;
  ExistingSettingsPassword: String;
  ExistingSuperUserPassword: String;
  ExistingRFQUserPassword: String;
  ExistingAzureKey: String;
  ExistingUpdateChannel: String;
begin
  // Get the installation path
  EnvFilePath := ExpandConstant('{app}\.env');
  
  // If .env file doesn't exist, skip loading
  if not FileExists(EnvFilePath) then
    Exit;
  
  Log('Found existing .env file at: ' + EnvFilePath);
  
  // Read values from existing .env file
  ExistingGitHubToken := ReadEnvValue(EnvFilePath, 'GITHUB_PAT');
  ExistingAWSKey := ReadEnvValue(EnvFilePath, 'AWS_KEY');
  ExistingAWSSecret := ReadEnvValue(EnvFilePath, 'AWS_SECRET');
  ExistingAWSRegion := ReadEnvValue(EnvFilePath, 'AWS_REGION');
  ExistingModelPath := ReadEnvValue(EnvFilePath, 'MODEL_PATH');
  ExistingServerURL := ReadEnvValue(EnvFilePath, 'SERVER_URL');
  ExistingSettingsPassword := ReadEnvValue(EnvFilePath, 'SETTINGS_PASSWORD');
  ExistingSuperUserPassword := ReadEnvValue(EnvFilePath, 'SQL_SUPER_USER');
  ExistingRFQUserPassword := ReadEnvValue(EnvFilePath, 'RFQ_USER_PASSWORD');
  ExistingAzureKey := ReadEnvValue(EnvFilePath, 'AZURE_CONFIG_ENCRYPTION_KEY');
  ExistingUpdateChannel := ReadEnvValue(EnvFilePath, 'RFQ_UPDATE_CHANNEL');
  
  // Store update channel from existing .env if found
  if ExistingUpdateChannel <> '' then
  begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'UpdateChannel', ExistingUpdateChannel);
    Log('Loaded Update Channel from .env: ' + ExistingUpdateChannel);
  end;
  
  // Pre-populate input pages with existing values
  if ExistingGitHubToken <> '' then
  begin
    GitHubTokenPage.Values[0] := ExistingGitHubToken;
    Log('Loaded GitHub token from .env');
  end;
  
  if ExistingAWSKey <> '' then
  begin
    AWSKeyPage.Values[0] := ExistingAWSKey;
    Log('Loaded AWS Key from .env');
  end;
  
  if ExistingAWSSecret <> '' then
  begin
    AWSSecretPage.Values[0] := ExistingAWSSecret;
    Log('Loaded AWS Secret from .env');
  end;
  
  if ExistingAWSRegion <> '' then
  begin
    AWSRegionPage.Values[0] := ExistingAWSRegion;
    Log('Loaded AWS Region from .env');
  end;
  
  if ExistingModelPath <> '' then
  begin
    ModelPathPage.Values[0] := ExistingModelPath;
    Log('Loaded Model Path from .env');
  end;
  
  if ExistingServerURL <> '' then
  begin
    ServerURLPage.Values[0] := ExistingServerURL;
    Log('Loaded Server URL from .env');
  end;
  
  if ExistingSettingsPassword <> '' then
  begin
    SettingsPasswordPage.Values[0] := ExistingSettingsPassword;
    Log('Loaded Settings Password from .env');
  end;
  
  if ExistingSuperUserPassword <> '' then
  begin
    SuperUserPasswordPage.Values[0] := ExistingSuperUserPassword;
    Log('Loaded Super User Password from .env');
  end;
  
  if ExistingRFQUserPassword <> '' then
  begin
    RFQUserPasswordPage.Values[0] := ExistingRFQUserPassword;
    Log('Loaded RFQ User Password from .env');
  end;
  
  if ExistingAzureKey <> '' then
  begin
    AzureKeyInputPage.Values[0] := ExistingAzureKey;
    Log('Loaded Azure Config Encryption Key from .env');
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  InstallPath: String;
  GitHubToken: String;
  AWSKey: String;
  AWSSecret: String;
  AWSRegion: String;
  ModelDownload: Boolean;
  ModelPath: String;
  ScriptPath: String;
  Params: String;
  UpdateChannel: String;
begin
  Result := True;
  
  // Load existing .env values when leaving the directory selection page
  if CurPageID = wpSelectDir then
  begin
    LoadExistingEnvValues();
  end;
  
  // Prevent proceeding from dependency check page if dependencies are missing
  if CurPageID = DependencyCheckPage.ID then
  begin
    if (not CheckPostgreSQLInPath()) or (not CheckOpenSSLInPath()) or (not CheckPythonInstalled()) then
    begin
      MsgBox('Cannot proceed until PostgreSQL and OpenSSL are available in PATH.' + #13#10 + #13#10 +
             'Open Command Prompt and confirm these work:' + #13#10 +
             '  where psql' + #13#10 +
             '  where openssl' + #13#10 + #13#10 +
             'If you just updated PATH, close/re-open Command Prompt, then restart this installer.',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
    
    // NSSM is bundled with the installer, so this check is informational only
    // The Files section will install nssm.exe to {pf}\nssm automatically
  end;
  
  // Store Clean Reinstall setting when leaving the page
  if CurPageID = CleanReinstallPage.ID then
  begin
    if CleanReinstallPage.SelectedValueIndex = 0 then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'CleanReinstall', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'CleanReinstall', 'False');
    
    // Store cleanup checkbox state
    if CleanupCheckbox.Checked then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'CleanupAfterInstall', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'CleanupAfterInstall', 'False');
  end;
  
  // Validate GitHub token is mandatory
  if CurPageID = GitHubTokenPage.ID then
  begin
    GitHubToken := Trim(GitHubTokenPage.Values[0]);
    if (GitHubToken = '') then
    begin
      MsgBox('GitHub Personal Access Token is required to continue.' + #13#10 + #13#10 +
             'Please enter a valid GitHub token (starts with ghp_...).' + #13#10 + #13#10 +
             'The software provider should supply you with a GitHub Personal Access Token.' + #13#10 +
             'Please contact your software provider if you do not have a token.',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
    // Store GitHub token to registry
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'GitHubToken', GitHubToken);
  end;
  
  // Store AWS Key to registry when leaving AWS Key page
  if CurPageID = AWSKeyPage.ID then
  begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSKey', AWSKeyPage.Values[0]);
  end;
  
  // Store AWS Secret to registry when leaving AWS Secret page
  if CurPageID = AWSSecretPage.ID then
  begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSSecret', AWSSecretPage.Values[0]);
  end;
  
  // Store AWS Region to registry when leaving AWS Region page
  if CurPageID = AWSRegionPage.ID then
  begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSRegion', AWSRegionPage.Values[0]);
  end;
  
  // Validate AWS credentials if model download is selected
  if CurPageID = ModelDownloadPage.ID then
  begin
    ModelDownload := ModelDownloadPage.SelectedValueIndex = 0;
    
    // Store ModelDownload flag to registry
    if ModelDownload then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelDownload', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelDownload', 'False');
    
    if ModelDownload then
    begin
      AWSKey := Trim(AWSKeyPage.Values[0]);
      AWSSecret := Trim(AWSSecretPage.Values[0]);
      if (AWSKey = '') or (AWSSecret = '') then
      begin
        MsgBox('AWS credentials are required for model download.' + #13#10 + #13#10 +
               'Please go back and enter your AWS Access Key ID and Secret Access Key.',
               mbError, MB_OK);
        Result := False;
        Exit;
      end;
    end;
  end;
  
  if CurPageID = ModelPathPage.ID then
  begin
    // Prepare installation parameters
    // {app} is now available since directory selection page has been shown
    InstallPath := ExpandConstant('{app}');
    
    GitHubToken := GitHubTokenPage.Values[0];
    AWSKey := AWSKeyPage.Values[0];
    AWSSecret := AWSSecretPage.Values[0];
    AWSRegion := AWSRegionPage.Values[0];
    ModelDownload := ModelDownloadPage.SelectedValueIndex = 0;
    ModelPath := ModelPathPage.Values[0];
    
    if ModelPath = '' then
      ModelPath := ExpandConstant('{userdocs}\RFQ_Models');
    
    // Store values in registry for the PowerShell script to read
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'GitHubToken', GitHubToken);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSKey', AWSKey);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSSecret', AWSSecret);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSRegion', AWSRegion);
    // Convert boolean to string manually
    if ModelDownload then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelDownload', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelDownload', 'False');
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelPath', ModelPath);
  end;
  
  // Validate Settings Password (skip if already stored in WCM)
  if CurPageID = SettingsPasswordPage.ID then
  begin
    // Store "already stored" checkbox state
    if SettingsPasswordAlreadyStoredCheck.Checked then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPasswordAlreadyStored', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPasswordAlreadyStored', 'False');
    
    // Only validate password if not already stored in WCM
    if not SettingsPasswordAlreadyStoredCheck.Checked then
    begin
      if not ValidatePassword(SettingsPasswordPage.Values[0], 'Settings Password') then
      begin
        Result := False;
        Exit;
      end;
    end;
  end;
  
  // Validate PostgreSQL Super User Password (skip if already stored in WCM)
  if CurPageID = SuperUserPasswordPage.ID then
  begin
    // Store "already stored" checkbox state
    if SuperUserPasswordAlreadyStoredCheck.Checked then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPasswordAlreadyStored', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPasswordAlreadyStored', 'False');
    
    // Only validate password if not already stored in WCM
    if not SuperUserPasswordAlreadyStoredCheck.Checked then
    begin
      if not ValidatePassword(SuperUserPasswordPage.Values[0], 'PostgreSQL Super User Password') then
      begin
        Result := False;
        Exit;
      end;
    end;
  end;
  
  // Validate RFQ User Password (skip if already stored in WCM)
  if CurPageID = RFQUserPasswordPage.ID then
  begin
    // Store "already stored" checkbox state
    if RFQUserPasswordAlreadyStoredCheck.Checked then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPasswordAlreadyStored', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPasswordAlreadyStored', 'False');
    
    // Only validate password if not already stored in WCM
    if not RFQUserPasswordAlreadyStoredCheck.Checked then
    begin
      if not ValidatePassword(RFQUserPasswordPage.Values[0], 'RFQ User Password') then
      begin
        Result := False;
        Exit;
      end;
    end;
    
    // Store database passwords when on the last password page (only if not already stored)
    if not SettingsPasswordAlreadyStoredCheck.Checked then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPassword', SettingsPasswordPage.Values[0]);
    if not SuperUserPasswordAlreadyStoredCheck.Checked then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPassword', SuperUserPasswordPage.Values[0]);
    if not RFQUserPasswordAlreadyStoredCheck.Checked then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPassword', RFQUserPasswordPage.Values[0]);
  end;
  
  // Store Server URL when on Server URL page
  if CurPageID = ServerURLPage.ID then
  begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ServerURL', ServerURLPage.Values[0]);
  end;
  
  // Store Azure key settings when on Azure key page
  if CurPageID = AzureKeyPage.ID then
  begin
    if AzureKeyPage.SelectedValueIndex = 0 then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AzureKeyGenerate', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AzureKeyGenerate', 'False');
  end;
  
  // Validate Azure key input if custom key is selected
  if CurPageID = AzureKeyInputPage.ID then
  begin
    if Trim(AzureKeyInputPage.Values[0]) = '' then
    begin
      MsgBox('Azure configuration encryption key is required when using a custom key.' + #13#10 + #13#10 +
             'Please enter a valid base64-encoded encryption key, or go back and select automatic generation.',
             mbError, MB_OK);
      Result := False;
      Exit;
    end;
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AzureKeyCustom', AzureKeyInputPage.Values[0]);
  end;
  
  // Store Credential Manager preference
  if CurPageID = CredentialManagerPage.ID then
  begin
    if CredentialManagerPage.SelectedValueIndex = 0 then
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'UseCredentialManager', 'True')
    else
      RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'UseCredentialManager', 'False');
  end;
  
  // Store Service Account preference
  if CurPageID = ServiceAccountPage.ID then
  begin
    // 0 = Current User, 1 = Network Service, 2 = Local System
    case ServiceAccountPage.SelectedValueIndex of
      0: RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ServiceAccount', 'CurrentUser');
      1: RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ServiceAccount', 'NetworkService');
      2: RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ServiceAccount', 'LocalSystem');
    end;
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  
  // Skip model path page if not downloading model
  if PageID = ModelPathPage.ID then
    Result := ModelDownloadPage.SelectedValueIndex <> 0;
  
  // Skip Azure key input page if auto-generate is selected
  if PageID = AzureKeyInputPage.ID then
    Result := AzureKeyPage.SelectedValueIndex = 0;
end;

function GetInstallDescription(Param: String): String;
begin
  Result := 'Installing application files and creating Windows service ''RFQapplication''...' + #13#10 + #13#10 + \
            'This will:' + #13#10 + \
            '  • Download and extract application files' + #13#10 + \
            '  • Create Windows service ''RFQapplication'' (starts automatically)' + #13#10 + \
            '  • Configure application settings' + #13#10 + \
            '  • Set up database (if selected)' + #13#10 + #13#10 + \
            'This may take several minutes - a PowerShell window will show progress';
end;

function GetPowerShellParams(Param: String): String;
var
  InstallPath: String;
  GitHubToken: String;
  AWSKey: String;
  AWSSecret: String;
  AWSRegion: String;
  ModelDownload: Boolean;
  ModelPath: String;
  SettingsPassword: String;
  SuperUserPassword: String;
  RFQUserPassword: String;
  ServerURL: String;
  AzureKeyGenerate: Boolean;
  AzureKeyCustom: String;
  CleanReinstall: Boolean;
  CleanupAfterInstall: Boolean;
  UpdateChannel: String;
  UseCredentialManager: Boolean;
  ServiceAccount: String;
  ModelDownloadStr: String;
  AzureKeyGenerateStr: String;
  CleanReinstallStr: String;
  CleanupAfterInstallStr: String;
  UseCredentialManagerStr: String;
  SettingsPasswordAlreadyStoredStr: String;
  SuperUserPasswordAlreadyStoredStr: String;
  RFQUserPasswordAlreadyStoredStr: String;
  SettingsPasswordAlreadyStored: Boolean;
  SuperUserPasswordAlreadyStored: Boolean;
  RFQUserPasswordAlreadyStored: Boolean;
  Params: String;
begin
  // Get installation path
  InstallPath := ExpandConstant('{app}');
  
  // Always read from registry since that's where values are stored during wizard
  // Pages may not be accessible during the [Run] section
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'GitHubToken', GitHubToken);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSKey', AWSKey);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSSecret', AWSSecret);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSRegion', AWSRegion);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelPath', ModelPath);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPassword', SettingsPassword);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPassword', SuperUserPassword);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPassword', RFQUserPassword);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ServerURL', ServerURL);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AzureKeyCustom', AzureKeyCustom);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'UpdateChannel', UpdateChannel);
  
  // Read ModelDownload from registry
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelDownload', ModelDownloadStr) then
    ModelDownload := (ModelDownloadStr = 'True')
  else
    ModelDownload := False;
  
  // Read AzureKeyGenerate from registry
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AzureKeyGenerate', AzureKeyGenerateStr) then
    AzureKeyGenerate := (AzureKeyGenerateStr = 'True')
  else
    AzureKeyGenerate := True;
  
  // Read CleanReinstall from registry (default to True if not set)
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'CleanReinstall', CleanReinstallStr) then
    CleanReinstall := (CleanReinstallStr = 'True')
  else
    CleanReinstall := True;  // Default to clean reinstall
  
  // Read CleanupAfterInstall from registry (default to True if not set)
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'CleanupAfterInstall', CleanupAfterInstallStr) then
    CleanupAfterInstall := (CleanupAfterInstallStr = 'True')
  else
    CleanupAfterInstall := True;  // Default to cleanup after install
  
  // Read UseCredentialManager from registry (default to True if not set)
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'UseCredentialManager', UseCredentialManagerStr) then
    UseCredentialManager := (UseCredentialManagerStr = 'True')
  else
    UseCredentialManager := True;  // Default to Credential Manager
  
  // Read ServiceAccount from registry (default to CurrentUser if not set)
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ServiceAccount', ServiceAccount) then
    ServiceAccount := 'CurrentUser';  // Default to Current User
  
  // Read "already stored" flags from registry
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPasswordAlreadyStored', SettingsPasswordAlreadyStoredStr) then
    SettingsPasswordAlreadyStored := (SettingsPasswordAlreadyStoredStr = 'True')
  else
    SettingsPasswordAlreadyStored := False;
  
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPasswordAlreadyStored', SuperUserPasswordAlreadyStoredStr) then
    SuperUserPasswordAlreadyStored := (SuperUserPasswordAlreadyStoredStr = 'True')
  else
    SuperUserPasswordAlreadyStored := False;
  
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPasswordAlreadyStored', RFQUserPasswordAlreadyStoredStr) then
    RFQUserPasswordAlreadyStored := (RFQUserPasswordAlreadyStoredStr = 'True')
  else
    RFQUserPasswordAlreadyStored := False;
  
  // If ModelPath is empty, use default
  if ModelPath = '' then
    ModelPath := ExpandConstant('{userdocs}\RFQ_Models');
  
  // If AWSRegion is empty, use default
  if AWSRegion = '' then
    AWSRegion := 'us-east-1';
  
  // If ServerURL is empty, use default
  if ServerURL = '' then
    ServerURL := 'https://localhost';
  
  // If UpdateChannel is empty, use default
  if UpdateChannel = '' then
    UpdateChannel := 'customer';
  
  // Build PowerShell command parameters
  Params := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "' + ExpandConstant('{tmp}\download_and_install.ps1') + '"';
  Params := Params + ' -InstallPath "' + InstallPath + '"';
  Params := Params + ' -GitHubToken "' + GitHubToken + '"';
  Params := Params + ' -OverwriteExisting';
  
  // Add Clean Reinstall flag
  if CleanReinstall then
    Params := Params + ' -CleanReinstall';
  
  // Add Cleanup After Install flag
  if CleanupAfterInstall then
    Params := Params + ' -CleanupAfterInstall';
  
  // Add Update Channel
  Params := Params + ' -UpdateChannel "' + UpdateChannel + '"';
  
  // Add Credential Manager flag
  if UseCredentialManager then
    Params := Params + ' -UseCredentialManager';
  
  // Add Service Account parameter
  Params := Params + ' -ServiceAccount "' + ServiceAccount + '"';
  
  // Add database passwords (only if not already stored in WCM)
  if not SettingsPasswordAlreadyStored and (SettingsPassword <> '') then
    Params := Params + ' -SettingsPassword "' + SettingsPassword + '"';
  if SettingsPasswordAlreadyStored then
    Params := Params + ' -SettingsPasswordAlreadyStored';
  
  if not SuperUserPasswordAlreadyStored and (SuperUserPassword <> '') then
    Params := Params + ' -SuperUserPassword "' + SuperUserPassword + '"';
  if SuperUserPasswordAlreadyStored then
    Params := Params + ' -SuperUserPasswordAlreadyStored';
  
  if not RFQUserPasswordAlreadyStored and (RFQUserPassword <> '') then
    Params := Params + ' -RFQUserPassword "' + RFQUserPassword + '"';
  if RFQUserPasswordAlreadyStored then
    Params := Params + ' -RFQUserPasswordAlreadyStored';
  
  // Add Server URL
  if ServerURL <> '' then
    Params := Params + ' -ServerURL "' + ServerURL + '"';
  
  // Add Azure key settings
  if AzureKeyGenerate then
    Params := Params + ' -AzureKeyGenerate'
  else if AzureKeyCustom <> '' then
    Params := Params + ' -AzureKeyCustom "' + AzureKeyCustom + '"';
  
  // Always pass AWS credentials to save to .env (even if not downloading model now)
  // Note: Credentials are passed via registry to avoid command-line escaping issues
  // The PowerShell script will read them from registry if command-line params fail
  if AWSKey <> '' then
    Params := Params + ' -AWSKey "' + AWSKey + '"';
  if AWSSecret <> '' then
    Params := Params + ' -AWSSecret "' + AWSSecret + '"';
  if AWSRegion <> '' then
    Params := Params + ' -AWSRegion "' + AWSRegion + '"';
  
  // Add model download options
  if ModelDownload then
  begin
    // User chose to download - pass model path
    Params := Params + ' -ModelPath "' + ModelPath + '"';
  end
  else
  begin
    // User chose to skip download - tell script not to prompt
    Params := Params + ' -SkipModelDownload';
  end;
  
  Result := Params;
end;

function ServiceExists(const ServiceName: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec('cmd.exe', '/c sc query "' + ServiceName + '" >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

function StopDeleteAndWaitForServiceRemoval(const ServiceName: String): Boolean;
var
  ResultCode: Integer;
  Waited: Integer;
begin
  Result := True;

  if not ServiceExists(ServiceName) then
  begin
    Log('Service "' + ServiceName + '" is not present during uninstall.');
    Exit;
  end;

  Log('Stopping service "' + ServiceName + '" before uninstall.');
  if not Exec('cmd.exe', '/c sc stop "' + ServiceName + '" >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('Failed to launch stop command for service "' + ServiceName + '".');

  Log('Deleting service "' + ServiceName + '" before uninstall.');
  if not Exec('cmd.exe', '/c sc delete "' + ServiceName + '" >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Log('Failed to launch delete command for service "' + ServiceName + '".');
    Result := False;
    Exit;
  end;

  Waited := 0;
  while Waited < 30 do
  begin
    if not ServiceExists(ServiceName) then
    begin
      Log('Service "' + ServiceName + '" removed after ' + IntToStr(Waited) + ' seconds.');
      Exit;
    end;

    Sleep(1000);
    Waited := Waited + 1;
  end;

  Result := not ServiceExists(ServiceName);
  if not Result then
    Log('Timed out waiting for service "' + ServiceName + '" to be removed.');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    StopDeleteAndWaitForServiceRemoval('RFQUpdaterService');
    StopDeleteAndWaitForServiceRemoval('RFQapplication');
  end;
end;

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
