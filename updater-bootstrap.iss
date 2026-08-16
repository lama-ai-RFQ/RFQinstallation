; Inno Setup Script for the RFQ Updater Bootstrap (mini-installer)
; ---------------------------------------------------------------
; SEPARATE from setup.iss. An IT admin runs this ONCE on an existing install to
; swap the old windows_updater.exe for the NEW self-update-capable build (see
; UPDATER_BUILD.md). It does NOT install the application, the database, or any
; configuration -- it only carries windows_updater.exe + bootstrap-updater.ps1
; and runs the swap.
;
; Code-signing-ready: sign the compiled installer_output\RFQ_Updater_Bootstrap.exe
; (e.g. signtool sign /fd SHA256 /a ...). The bundled windows_updater.exe should
; itself be signed upstream by the rfqautomation build.
;
; Identity is env-var-direct with literal defaults, matching the
; INFA-669/670/671 pattern in setup.iss.

#define BootstrapAppVersion "1.0.1"
#define BootstrapPublisher "LAMAAI Ventures LLC"
#define BootstrapURL "https://github.com/lama-ai-RFQ"

; Distinct AppId so this mini-installer never collides with the full app's
; Add/Remove Programs entry.
#define BootstrapAppId GetEnv("RFQ_UPDATER_BOOTSTRAP_APP_ID")
#if BootstrapAppId == ""
  #define BootstrapAppIdSource "{{F7C1A2B3-44D5-4E6F-9A8B-0C1D2E3F4A5B}"
#else
  #define BootstrapAppIdSource "{{" + BootstrapAppId + "}"
#endif

#define BootstrapAppName GetEnv("RFQ_UPDATER_BOOTSTRAP_APP_NAME")
#if BootstrapAppName == ""
  #define BootstrapAppName "RFQ Updater Bootstrap"
#endif

#define BootstrapOutputBaseFilename GetEnv("RFQ_UPDATER_BOOTSTRAP_OUTPUT_BASE_FILENAME")
#if BootstrapOutputBaseFilename == ""
  #define BootstrapOutputBaseFilename "RFQ_Updater_Bootstrap"
#endif

[Setup]
AppId={#BootstrapAppIdSource}
AppName={#BootstrapAppName}
AppVersion={#BootstrapAppVersion}
AppPublisher={#BootstrapPublisher}
AppPublisherURL={#BootstrapURL}
AppSupportURL={#BootstrapURL}
; This is a one-shot maintenance tool: it does not install into a directory and
; leaves nothing behind to uninstall.
CreateAppDir=no
Uninstallable=no
OutputDir=installer_output
OutputBaseFilename={#BootstrapOutputBaseFilename}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
DisableProgramGroupPage=yes
DisableReadyPage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Carried to {tmp} only; deleteafterinstall removes them once the swap is done.
; windows_updater.exe MUST be the NEW self-update-capable build (UPDATER_BUILD.md).
Source: "windows_updater.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall ignoreversion
Source: "bootstrap-updater.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall ignoreversion

[Messages]
; Minimal IT-facing UX wording.
WelcomeLabel2=This tool replaces the existing RFQ updater (windows_updater.exe) with the new self-update-capable build.%n%nIt stops the updater service, backs up the current updater, installs the new one, and restarts the service. If anything fails it automatically rolls back. The application, database, and configuration are NOT touched.

[Code]
var
  SwapSucceeded: Boolean;

// Runs bootstrap-updater.ps1 from {tmp} and reports success/failure to the IT
// admin. Identity overrides (RFQ_UPDATER_SERVICE_NAME / RFQ_INSTALL_DIR) are
// inherited by the PowerShell child process from the installer's environment.
procedure RunBootstrapSwap();
var
  ScriptPath: String;
  NewExePath: String;
  LogPath: String;
  Params: String;
  ResultCode: Integer;
begin
  SwapSucceeded := False;

  ScriptPath := ExpandConstant('{tmp}\bootstrap-updater.ps1');
  NewExePath := ExpandConstant('{tmp}\windows_updater.exe');
  LogPath := ExpandConstant('{tmp}\bootstrap-updater.log');

  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"' +
            ' -NewUpdaterExe "' + NewExePath + '"' +
            ' -LogPath "' + LogPath + '"' +
            ' -NonInteractive';

  Log('Running updater bootstrap swap: powershell.exe ' + Params);

  if Exec('powershell.exe', Params, '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
  begin
    Log('Bootstrap swap exited with code ' + IntToStr(ResultCode));
    SwapSucceeded := (ResultCode = 0);
  end
  else
  begin
    Log('Failed to launch PowerShell for the bootstrap swap.');
    SwapSucceeded := False;
  end;

  if SwapSucceeded then
    MsgBox('The RFQ updater was successfully replaced with the new self-update-capable build.' + #13#10 + #13#10 +
           'The updater service is running again. This machine can now self-update.',
           mbInformation, MB_OK)
  else
    MsgBox('The RFQ updater swap did NOT complete successfully.' + #13#10 + #13#10 +
           'The tool attempts to roll back automatically, so the previous updater should still be in place.' + #13#10 +
           'Please review the log for details:' + #13#10 + LogPath,
           mbError, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RunBootstrapSwap();
end;
