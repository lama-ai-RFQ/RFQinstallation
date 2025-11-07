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
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
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
  GitHubTokenPage: TInputQueryWizardPage;
  AWSKeyPage: TInputQueryWizardPage;
  AWSSecretPage: TInputQueryWizardPage;
  AWSRegionPage: TInputQueryWizardPage;
  ModelDownloadPage: TInputOptionWizardPage;
  ModelPathPage: TInputDirWizardPage;
  SettingsPasswordPage: TInputQueryWizardPage;
  SuperUserPasswordPage: TInputQueryWizardPage;
  RFQUserPasswordPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
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
  
  // Create database password pages
  SettingsPasswordPage := CreateInputQueryPage(ModelPathPage.ID,
    'Database Configuration', 'Settings Password',
    'Enter a password for the application settings database access:');
  SettingsPasswordPage.Add('Settings Password:', True);  // True = password field (masked)
  
  SuperUserPasswordPage := CreateInputQueryPage(SettingsPasswordPage.ID,
    'Database Configuration', 'PostgreSQL Super User Password',
    'Enter the PostgreSQL super user password (for database setup):');
  SuperUserPasswordPage.Add('PostgreSQL Super User Password:', True);  // True = password field (masked)
  
  RFQUserPasswordPage := CreateInputQueryPage(SuperUserPasswordPage.ID,
    'Database Configuration', 'RFQ User Password',
    'Enter the password for the RFQ database user:');
  RFQUserPasswordPage.Add('RFQ User Password:', True);  // True = password field (masked)
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
  
  // Store database passwords when on the last password page
  if CurPageID = RFQUserPasswordPage.ID then
  begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPassword', SettingsPasswordPage.Values[0]);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPassword', SuperUserPasswordPage.Values[0]);
    RegWriteStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPassword', RFQUserPasswordPage.Values[0]);
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  
  // Skip model path page if not downloading model
  if PageID = ModelPathPage.ID then
    Result := ModelDownloadPage.SelectedValueIndex <> 0;
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
  ModelDownloadStr: String;
  Params: String;
begin
  // Get installation path
  InstallPath := ExpandConstant('{app}');
  
  // Try to get values from pages first, fallback to registry
  try
    GitHubToken := GitHubTokenPage.Values[0];
    AWSKey := AWSKeyPage.Values[0];
    AWSSecret := AWSSecretPage.Values[0];
    AWSRegion := AWSRegionPage.Values[0];
    ModelDownload := ModelDownloadPage.SelectedValueIndex = 0;
    ModelPath := ModelPathPage.Values[0];
    SettingsPassword := SettingsPasswordPage.Values[0];
    SuperUserPassword := SuperUserPasswordPage.Values[0];
    RFQUserPassword := RFQUserPasswordPage.Values[0];
  except
    // Fallback to registry if pages not available
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'GitHubToken', GitHubToken);
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSKey', AWSKey);
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSSecret', AWSSecret);
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'AWSRegion', AWSRegion);
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelPath', ModelPath);
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SettingsPassword', SettingsPassword);
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'SuperUserPassword', SuperUserPassword);
    RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'RFQUserPassword', RFQUserPassword);
  end;
  
  // Read ModelDownload from registry if not set from pages
  if not ModelDownload then
  begin
    if RegQueryStringValue(HKEY_CURRENT_USER, 'Software\RFQApplication\Installer', 'ModelDownload', ModelDownloadStr) then
      ModelDownload := (ModelDownloadStr = 'True')
    else
      ModelDownload := False;
  end;
  
  // If ModelPath is empty, use default
  if ModelPath = '' then
    ModelPath := ExpandConstant('{userdocs}\RFQ_Models');
  
  // If AWSRegion is empty, use default
  if AWSRegion = '' then
    AWSRegion := 'us-east-1';
  
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
  
  // Add AWS credentials and model path if downloading
  if ModelDownload then
  begin
    Params := Params + ' -ModelPath "' + ModelPath + '"';
    if AWSKey <> '' then
      Params := Params + ' -AWSKey "' + AWSKey + '"';
    if AWSSecret <> '' then
      Params := Params + ' -AWSSecret "' + AWSSecret + '"';
    if AWSRegion <> '' then
      Params := Params + ' -AWSRegion "' + AWSRegion + '"';
  end;
  
  Result := Params;
end;

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

