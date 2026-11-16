# Installer .env Emission Characterization Tests

Run from the repository root:

```powershell
Invoke-Pester ./tests
```

The Pester file compiles only the `.env` emission region from `download_and_install.ps1` and invokes it in a temporary install directory. It avoids dot-sourcing the full installer because the script has top-level installation side effects.
