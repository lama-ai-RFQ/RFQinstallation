# RFQ Application — Windows Installer

The active installer is a custom **.NET/WPF wizard** in [`new-installer/`](new-installer/) (branch
`feature/new-windows-installer`), replacing an older Inno Setup + PowerShell installer. See
[`new-installer/OLD_VS_NEW.md`](new-installer/OLD_VS_NEW.md) for the full old-vs-new comparison,
open items, and fix history.

A legacy Inno-based installer (`setup.iss`, `download_and_install.ps1`,
`setup_database_auto.ps1`) and a stripped-down demo of it (`legacy-demo/`) are kept in this
directory for reference until the new installer has been through a full real-world install cycle
and can retire them — they are not the active installer and are not otherwise documented here.

## Directory contents

| Path | Purpose |
|------|---------|
| `new-installer/` | The active WPF installer — `RfqInstaller.sln` (wizard + `RfqInstaller.Core` + `RfqInstaller.Uninstall`) |
| `new-installer/OLD_VS_NEW.md` | Old-vs-new comparison, open items, fix history |
| `new-installer/test-environments/` | Windows Sandbox + Hyper-V scenarios for testing installs without touching a real machine |
| `license-broker/` | Reference AWS Lambda implementation for the (not yet deployed) license/download service |
| `setup.iss`, `download_and_install.ps1`, `setup_database_auto.ps1` | Legacy Inno installer — reference only |
| `legacy-demo/` | Stripped-down demo of the legacy installer — reference only |

## Building

```powershell
cd new-installer
dotnet build RfqInstaller.sln
```

For a build that runs standalone on a machine with no .NET runtime installed (matches how it
actually ships), publish instead of building — `RfqInstaller.csproj`/`RfqInstaller.Uninstall.csproj`
are self-contained, single-file `win-x64`:

```powershell
dotnet publish RfqInstaller\RfqInstaller.csproj
```

This only takes effect on `publish`, not `build`. Output lands at
`RfqInstaller\bin\x64\Release\net8.0-windows\win-x64\publish\RfqInstaller.exe`.

## Testing

See [`new-installer/test-environments/README.md`](new-installer/test-environments/README.md) for
reproducible test scenarios (Windows Sandbox for a clean-machine install; Hyper-V + checkpoints for
upgrade paths, including installing on top of an existing legacy-installer install).

## Known gaps

The license/download service (`license-broker/`) is not deployed yet — `LicenseBrokerClient` in the
new installer is an intentional placeholder. See
[`new-installer/OLD_VS_NEW.md`](new-installer/OLD_VS_NEW.md) for this and other open items.
