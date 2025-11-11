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
; Include any other necessary files
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "USER_QUICK_START.md"; DestDir: "{app}"; Flags: ignoreversion

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
    StatusMsg: "Installing RFQ Application..."; \
    Flags: waituntilterminated; \
    Description: "Installing application files... (This may take several minutes - a PowerShell window will show progress)"

[Code]
var
  DependencyCheckPage: TWizardPage;
  DependencyCheckLabel: TLabel;
  GitHubTokenPage: TInputQueryWizardPage;
  AWSKeyPage: TInputQueryWizardPage;
  AWSSecretPage: TInputQueryWizardPage;
  AWSRegionPage: TInputQueryWizardPage;
  ModelDownloadPage: TInputOptionWizardPage;
  ModelPathPage: TInputDirWizardPage;
  DatabaseTypePage: TInputOptionWizardPage;
  LocalDBPasswordPage: TInputQueryWizardPage;
  DockerDetailsPage: TInputQueryWizardPage;
  RemoteServerPage: TInputQueryWizardPage;
  RemotePasswordPage: TInputQueryWizardPage;
  SettingsPasswordPage: TInputQueryWizardPage;
  SuperUserPasswordPage: TInputQueryWizardPage;
  RFQUserPasswordPage: TInputQueryWizardPage;
  ServerURLPage: TInputQueryWizardPage;
  AzureKeyPage: TInputOptionWizardPage;
  AzureKeyInputPage: TInputQueryWizardPage;

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

function CheckPostgreSQLInstalled(): Boolean;
var
  ResultCode: Integer;
  PsqlPath: String;
  RegPath: String;
  RegValue: String;
begin
  Result := False;
  
  // Check if psql.exe is in PATH using 'where' command
  if Exec('cmd.exe', '/c where psql >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
  
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

function CheckOpenSSLInstalled(): Boolean;
var
  ResultCode: Integer;
  OpensslPath: String;
begin
  Result := False;

  // Check if openssl.exe is in PATH using 'where' command
  if Exec('cmd.exe', '/c where openssl >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;

  // Check common OpenSSL installation locations
  // OpenSSL is often installed in Program Files
  OpensslPath := ExpandConstant('{pf}\OpenSSL-Win64\bin\openssl.exe');
  if FileExists(OpensslPath) then
  begin
    Result := True;
    Exit;
  end;

  OpensslPath := ExpandConstant('{pf}\OpenSSL\bin\openssl.exe');
  if FileExists(OpensslPath) then
  begin
    Result := True;
    Exit;
  end;

  // Check Program Files (x86)
  OpensslPath := ExpandConstant('{pf32}\OpenSSL-Win32\bin\openssl.exe');
  if FileExists(OpensslPath) then
  begin
    Result := True;
    Exit;
  end;

  OpensslPath := ExpandConstant('{pf32}\OpenSSL\bin\openssl.exe');
  if FileExists(OpensslPath) then
  begin
    Result := True;
    Exit;
  end;

  // Check common alternative locations
  if FileExists('C:\OpenSSL-Win64\bin\openssl.exe') then
  begin
    Result := True;
    Exit;
  end;

  if FileExists('C:\OpenSSL\bin\openssl.exe') then
  begin
    Result := True;
    Exit;
  end;
end;

function CheckDockerInstalled(): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;

  // Check if docker is in PATH using 'where' command
  if Exec('cmd.exe', '/c where docker >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function CheckPostgreSQLRunning(): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;

  // Try to connect to PostgreSQL on localhost:5432 using psql
  // This checks if PostgreSQL service is actually running and accepting connections
  if Exec('cmd.exe', '/c psql -h localhost -p 5432 -U postgres -c "SELECT 1" >nul 2>&1', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;

  // Alternative: Check if port 5432 is listening (using PowerShell)
  if Exec('powershell.exe', '-Command "Test-NetConnection -ComputerName localhost -Port 5432 -InformationLevel Quiet"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      Result := True;
      Exit;
    end;
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
begin
  // Create dependency check page - appears FIRST
  DependencyCheckPage := CreateCustomPage(wpWelcome,
    'System Requirements Check', 'Checking for required dependencies...');
  
  // Create label to show dependency status
  DependencyCheckLabel := TLabel.Create(DependencyCheckPage);
  DependencyCheckLabel.Parent := DependencyCheckPage.Surface;
  DependencyCheckLabel.Left := 0;
  DependencyCheckLabel.Top := 0;
  DependencyCheckLabel.Width := DependencyCheckPage.SurfaceWidth;
  DependencyCheckLabel.Height := DependencyCheckPage.SurfaceHeight;
  DependencyCheckLabel.AutoSize := False;
  DependencyCheckLabel.WordWrap := True;
  DependencyCheckLabel.Font.Size := 9;
  
  // Check all dependencies and build detailed status text
  StatusText := 'System Check (Informational Only - Does Not Block Installation)' + #13#10 + #13#10;
  StatusText := StatusText + 'PostgreSQL Status:' + #13#10;

  // Check 1: PostgreSQL command-line tools
  if CheckPostgreSQLInstalled() then
    StatusText := StatusText + '  ✓ psql command available' + #13#10
  else
    StatusText := StatusText + '  ✗ psql command not found' + #13#10;

  // Check 2: PostgreSQL service running on localhost:5432
  if CheckPostgreSQLRunning() then
    StatusText := StatusText + '  ✓ PostgreSQL service running (localhost:5432)' + #13#10
  else
    StatusText := StatusText + '  ✗ PostgreSQL service not detected on localhost:5432' + #13#10;

  StatusText := StatusText + #13#10 + 'Docker Status:' + #13#10;

  // Check 3: Docker
  if CheckDockerInstalled() then
    StatusText := StatusText + '  ✓ Docker installed and available' + #13#10
  else
    StatusText := StatusText + '  ✗ Docker not found' + #13#10;

  StatusText := StatusText + #13#10 + 'Other Tools:' + #13#10;

  // Check 4: OpenSSL
  if CheckOpenSSLInstalled() then
    StatusText := StatusText + '  ✓ OpenSSL available' + #13#10
  else
    StatusText := StatusText + '  ✗ OpenSSL not found' + #13#10;

  StatusText := StatusText + #13#10;
  StatusText := StatusText + 'NOTE: All checks above are informational only.' + #13#10;
  StatusText := StatusText + 'You can choose any database setup method regardless of these results.' + #13#10;
  StatusText := StatusText + 'The installer will offer multiple options on the next screens.' + #13#10;

  DependencyCheckLabel.Font.Color := clBlue;
  DependencyCheckLabel.Caption := StatusText;
  
  // Create GitHub Token page - appears AFTER directory selection
  GitHubTokenPage := CreateInputQueryPage(wpSelectDir,
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
  
  AWSRegionPage := CreateInputQueryPage(AWSSecretPage.ID,
    'AWS Region', 'AWS Region Configuration',
    'Please enter your AWS Region (default: us-east-1):');
  AWSRegionPage.Add('AWS Region:', False);
  AWSRegionPage.Values[0] := 'us-east-1';

  // Create model download option page
  ModelDownloadPage := CreateInputOptionPage(AWSRegionPage.ID,
    'Model Download', 'Download Language Model',
    'The application requires the Mistral-7B-Instruct-v0.3 language model.' + #13#10 +
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

  // Create database setup type selection page
  DatabaseTypePage := CreateInputOptionPage(ModelPathPage.ID,
    'Database Setup', 'Choose Database Configuration',
    'The application requires a PostgreSQL database. How would you like to set up the database?' + #13#10 + #13#10 +
    'Select the option that matches your environment:',
    True, False);
  DatabaseTypePage.Add('Local PostgreSQL (installed on this computer)');
  DatabaseTypePage.Add('Docker Container (new or existing container)');
  DatabaseTypePage.Add('Remote PostgreSQL Server (external server)');
  DatabaseTypePage.Add('Skip database setup (I will configure manually)');
  DatabaseTypePage.SelectedValueIndex := 0;

  // Create Local PostgreSQL password page
  LocalDBPasswordPage := CreateInputQueryPage(DatabaseTypePage.ID,
    'Local Database Setup', 'PostgreSQL Admin Password',
    'Enter the PostgreSQL superuser (postgres) password for localhost.' + #13#10 + #13#10 +
    'This is the password you set when installing PostgreSQL.' + #13#10 +
    'It will be used to create the RFQ database and user.' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  LocalDBPasswordPage.Add('PostgreSQL Admin Password (localhost):', True);

  // Create Docker details page
  DockerDetailsPage := CreateInputQueryPage(DatabaseTypePage.ID,
    'Docker Database Setup', 'Docker Container Configuration',
    'Configure PostgreSQL Docker container settings:' + #13#10 + #13#10 +
    'Container Name: Leave empty to create a new container named "rfq-postgres"' + #13#10 +
    'Or enter an existing container name to use that container.');
  DockerDetailsPage.Add('Container Name (or leave empty for new):', False);
  DockerDetailsPage.Add('PostgreSQL Port:', False);
  DockerDetailsPage.Add('PostgreSQL Admin Password:', True);
  DockerDetailsPage.Values[1] := '5432';

  // Create Remote Server details page
  RemoteServerPage := CreateInputQueryPage(DatabaseTypePage.ID,
    'Remote Database Setup', 'Remote PostgreSQL Server Configuration',
    'Enter the connection details for your remote PostgreSQL server:' + #13#10 + #13#10 +
    'The installer will connect to this server to create the RFQ database.');
  RemoteServerPage.Add('PostgreSQL Host (IP or hostname):', False);
  RemoteServerPage.Add('PostgreSQL Port:', False);
  RemoteServerPage.Add('Admin Username:', False);
  RemoteServerPage.Values[1] := '5432';
  RemoteServerPage.Values[2] := 'postgres';

  // Create Remote Server password page
  RemotePasswordPage := CreateInputQueryPage(RemoteServerPage.ID,
    'Remote Database Setup', 'Remote PostgreSQL Password',
    'Enter the admin password for the remote PostgreSQL server.' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  RemotePasswordPage.Add('PostgreSQL Admin Password:', True);

  // Create application database password pages
  SettingsPasswordPage := CreateInputQueryPage(LocalDBPasswordPage.ID,
    'Application Configuration', 'Settings Password',
    'Enter a password for the application settings database access.' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  SettingsPasswordPage.Add('Settings Password:', True);

  SuperUserPasswordPage := CreateInputQueryPage(SettingsPasswordPage.ID,
    'Application Configuration', 'SQL Super User Password',
    'Enter a password for the SQL super user (used by the application).' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  SuperUserPasswordPage.Add('SQL Super User Password:', True);

  RFQUserPasswordPage := CreateInputQueryPage(SuperUserPasswordPage.ID,
    'Application Configuration', 'RFQ Database User Password',
    'Enter the password for the RFQ database user (created during setup).' + #13#10 + #13#10 +
    'Password Requirements:' + #13#10 +
    '  - Minimum 8 characters' + #13#10 +
    '  - Must contain at least 3 of: uppercase, lowercase, numbers, special characters');
  RFQUserPasswordPage.Add('RFQ User Password:', True);
  
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
    'You can generate this automatically using OpenSSL, or enter your own key.',
    True, False);
  AzureKeyPage.Add('Generate automatically using OpenSSL (recommended)');
  AzureKeyPage.Add('Enter custom key');
  AzureKeyPage.SelectedValueIndex := 0;
  
  // Create Azure Key Input page (shown only if custom key is selected)
  AzureKeyInputPage := CreateInputQueryPage(AzureKeyPage.ID,
    'Azure Configuration', 'Custom Encryption Key',
    'Enter your custom Azure configuration encryption key (base64 encoded):');
  AzureKeyInputPage.Add('Azure Config Encryption Key:', False);
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
begin
  Result := True;

  // NO BLOCKING on dependency check page - it's informational only

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
  
  // Store and validate database type selection
  if CurPageID = DatabaseTypePage.ID then
  begin
    // Store database type (0=Local, 1=Docker, 2=Remote, 3=Skip)
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseSetupMode', IntToStr(DatabaseTypePage.SelectedValueIndex));
  end;

  // Validate Local PostgreSQL password
  if CurPageID = LocalDBPasswordPage.ID then
  begin
    if not ValidatePassword(LocalDBPasswordPage.Values[0], 'PostgreSQL Admin Password') then
    begin
      Result := False;
      Exit;
    end;
    // Store local database credentials
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseHost', 'localhost');
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabasePort', '5432');
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminUser', 'postgres');
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminPassword', LocalDBPasswordPage.Values[0]);
  end;

  // Validate Docker configuration
  if CurPageID = DockerDetailsPage.ID then
  begin
    if Trim(DockerDetailsPage.Values[2]) = '' then
    begin
      MsgBox('PostgreSQL admin password is required for Docker setup.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not ValidatePassword(DockerDetailsPage.Values[2], 'PostgreSQL Admin Password') then
    begin
      Result := False;
      Exit;
    end;
    // Store Docker configuration
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DockerContainerName', DockerDetailsPage.Values[0]);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseHost', 'localhost');
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabasePort', DockerDetailsPage.Values[1]);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminUser', 'postgres');
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminPassword', DockerDetailsPage.Values[2]);
  end;

  // Validate Remote Server configuration
  if CurPageID = RemoteServerPage.ID then
  begin
    if (Trim(RemoteServerPage.Values[0]) = '') or (Trim(RemoteServerPage.Values[2]) = '') then
    begin
      MsgBox('Host and Admin Username are required for remote server setup.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    // Store Remote Server configuration (password on next page)
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseHost', RemoteServerPage.Values[0]);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabasePort', RemoteServerPage.Values[1]);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminUser', RemoteServerPage.Values[2]);
  end;

  // Validate Remote Server password
  if CurPageID = RemotePasswordPage.ID then
  begin
    if not ValidatePassword(RemotePasswordPage.Values[0], 'PostgreSQL Admin Password') then
    begin
      Result := False;
      Exit;
    end;
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminPassword', RemotePasswordPage.Values[0]);
  end;

  // Validate Settings Password
  if CurPageID = SettingsPasswordPage.ID then
  begin
    if not ValidatePassword(SettingsPasswordPage.Values[0], 'Settings Password') then
    begin
      Result := False;
      Exit;
    end;
  end;

  // Validate PostgreSQL Super User Password
  if CurPageID = SuperUserPasswordPage.ID then
  begin
    if not ValidatePassword(SuperUserPasswordPage.Values[0], 'SQL Super User Password') then
    begin
      Result := False;
      Exit;
    end;
  end;

  // Validate RFQ User Password
  if CurPageID = RFQUserPasswordPage.ID then
  begin
    if not ValidatePassword(RFQUserPasswordPage.Values[0], 'RFQ User Password') then
    begin
      Result := False;
      Exit;
    end;
    // Store application database passwords
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPassword', SettingsPasswordPage.Values[0]);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPassword', SuperUserPasswordPage.Values[0]);
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
end;

function ShouldSkipPage(PageID: Integer): Boolean;
var
  DatabaseType: Integer;
begin
  Result := False;

  // Skip model path page if not downloading model
  if PageID = ModelPathPage.ID then
    Result := ModelDownloadPage.SelectedValueIndex <> 0;

  // Database page logic
  DatabaseType := DatabaseTypePage.SelectedValueIndex;

  // Skip LocalDBPasswordPage unless Local is selected
  if PageID = LocalDBPasswordPage.ID then
    Result := (DatabaseType <> 0);  // 0 = Local PostgreSQL

  // Skip DockerDetailsPage unless Docker is selected
  if PageID = DockerDetailsPage.ID then
    Result := (DatabaseType <> 1);  // 1 = Docker Container

  // Skip RemoteServerPage unless Remote is selected
  if PageID = RemoteServerPage.ID then
    Result := (DatabaseType <> 2);  // 2 = Remote Server

  // Skip RemotePasswordPage unless Remote is selected
  if PageID = RemotePasswordPage.ID then
    Result := (DatabaseType <> 2);

  // Skip SettingsPasswordPage if database setup is skipped
  if PageID = SettingsPasswordPage.ID then
    Result := (DatabaseType = 3);  // 3 = Skip setup

  // Skip SuperUserPasswordPage if database setup is skipped
  if PageID = SuperUserPasswordPage.ID then
    Result := (DatabaseType = 3);

  // Skip RFQUserPasswordPage if database setup is skipped
  if PageID = RFQUserPasswordPage.ID then
    Result := (DatabaseType = 3);

  // Skip Azure key input page if auto-generate is selected
  if PageID = AzureKeyInputPage.ID then
    Result := AzureKeyPage.SelectedValueIndex = 0;
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
  DatabaseSetupMode: String;
  DatabaseHost: String;
  DatabasePort: String;
  DatabaseAdminUser: String;
  DatabaseAdminPassword: String;
  DockerContainerName: String;
  SettingsPassword: String;
  SuperUserPassword: String;
  RFQUserPassword: String;
  ServerURL: String;
  AzureKeyGenerate: Boolean;
  AzureKeyCustom: String;
  ModelDownloadStr: String;
  AzureKeyGenerateStr: String;
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
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseSetupMode', DatabaseSetupMode);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseHost', DatabaseHost);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabasePort', DatabasePort);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminUser', DatabaseAdminUser);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DatabaseAdminPassword', DatabaseAdminPassword);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'DockerContainerName', DockerContainerName);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPassword', SettingsPassword);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPassword', SuperUserPassword);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPassword', RFQUserPassword);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ServerURL', ServerURL);
  RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AzureKeyCustom', AzureKeyCustom);
  
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
  
  // If ModelPath is empty, use default
  if ModelPath = '' then
    ModelPath := ExpandConstant('{userdocs}\RFQ_Models');
  
  // If AWSRegion is empty, use default
  if AWSRegion = '' then
    AWSRegion := 'us-east-1';
  
  // If ServerURL is empty, use default
  if ServerURL = '' then
    ServerURL := 'https://localhost';
  
  // Build PowerShell command parameters
  Params := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "' + ExpandConstant('{tmp}\download_and_install.ps1') + '"';
  Params := Params + ' -InstallPath "' + InstallPath + '"';
  Params := Params + ' -GitHubToken "' + GitHubToken + '"';
  Params := Params + ' -OverwriteExisting';
  
  // Add database passwords
  if SettingsPassword <> '' then
    Params := Params + ' -SettingsPassword "' + SettingsPassword + '"';
  if SuperUserPassword <> '' then
    Params := Params + ' -SuperUserPassword "' + SuperUserPassword + '"';
  if RFQUserPassword <> '' then
    Params := Params + ' -RFQUserPassword "' + RFQUserPassword + '"';
  
  // Add Server URL
  if ServerURL <> '' then
    Params := Params + ' -ServerURL "' + ServerURL + '"';
  
  // Add Azure key settings
  if AzureKeyGenerate then
    Params := Params + ' -AzureKeyGenerate'
  else if AzureKeyCustom <> '' then
    Params := Params + ' -AzureKeyCustom "' + AzureKeyCustom + '"';

  // Add database setup parameters
  if DatabaseSetupMode <> '' then
    Params := Params + ' -DatabaseSetupMode "' + DatabaseSetupMode + '"';
  if DatabaseHost <> '' then
    Params := Params + ' -DatabaseHost "' + DatabaseHost + '"';
  if DatabasePort <> '' then
    Params := Params + ' -DatabasePort "' + DatabasePort + '"';
  if DatabaseAdminUser <> '' then
    Params := Params + ' -DatabaseAdminUser "' + DatabaseAdminUser + '"';
  if DatabaseAdminPassword <> '' then
    Params := Params + ' -DatabaseAdminPassword "' + DatabaseAdminPassword + '"';
  if DockerContainerName <> '' then
    Params := Params + ' -DockerContainerName "' + DockerContainerName + '"';

  // Add model download options
  if ModelDownload then
  begin
    // User chose to download - pass model path and AWS credentials
    Params := Params + ' -ModelPath "' + ModelPath + '"';
    // Always pass AWS credentials if model download is selected (even if empty, so script knows they were provided by installer)
    Params := Params + ' -AWSKey "' + AWSKey + '"';
    Params := Params + ' -AWSSecret "' + AWSSecret + '"';
    Params := Params + ' -AWSRegion "' + AWSRegion + '"';
  end
  else
  begin
    // User chose to skip download - tell script not to prompt
    Params := Params + ' -SkipModelDownload';
  end;

  Result := Params;
end;

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

