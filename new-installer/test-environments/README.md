# Installer test environments

Reproducible clean-room environments for testing `RfqInstaller` without touching this dev
machine's real install (`C:\Program Files\RFQ Application`). Two scenarios so far, matched to the
tool that actually fits each:

| Scenario | Tool | Why |
|---|---|---|
| **Empty** — nothing preexists | Windows Sandbox (`Sandbox-Empty.wsb`) | Always byte-identical clean, boots in seconds, disposable. No persistence needed because there's no prior state to set up. |
| **All existing** — Postgres + working DB + encryption key + model already installed **by an older build of this same new installer** | Hyper-V VM + checkpoints (`hyperv/`) | Needs to *keep* state between runs. Sandbox can't — it forgets everything on close, which would mean redoing a ~30GB model download before every single test. A checkpoint captures that state once and restores it in seconds. |
| **Legacy-installed** — same end state, but built by the **old Inno installer** (`download_and_install.ps1` + `setup_database_auto.ps1`), not the new one | Hyper-V VM + checkpoints (`hyperv/`) | This is the real customer-upgrade path — every existing customer's machine got into "has Postgres + DB + key" via the *old* installer, not a prior build of the new one. It also exercises code written specifically for this: `EncryptionKeyResolver` (comment references INFA-130) reads the key back out of a plain `.env`, and the new installer's Credential Manager targets (`RFQApplication_SQL_SUPER_USER`, `RFQApplication_RFQ_USER_PASSWORD`, `RFQApplication_SETTINGS_PASSWORD`) are byte-identical names to what the old `download_and_install.ps1` already writes — confirmed by reading both, not assumed. Scenario 2 above never touches that compatibility code path at all. |

A licensed install signs PostgreSQL binaries from the broker (`postgres.windows.binaries`).
`RFQ_POSTGRES_BINARIES_URL` / `RFQ_POSTGRES_BINARIES_SHA256` remain optional local overrides.
Leave them blank unless you are testing without the broker.

## Scenario 1 — Empty (Windows Sandbox)

1. `dotnet publish RfqInstaller\RfqInstaller.csproj` — `RfqInstaller.csproj` is now self-contained/
   single-file (`win-x64`), which only takes effect on `publish`, not `build` (a plain `dotnet build`
   still emits a framework-dependent output that needs the .NET Desktop Runtime preinstalled — the
   exact thing this scenario exists to catch on an empty machine). `dotnet publish` with no `-c`
   defaults to `Release` (unlike `build`, which defaults to `Debug`), and `Directory.Build.props`
   forces the `x64` platform folder, so the real output lands in
   `RfqInstaller\bin\x64\Release\net8.0-windows\win-x64\publish` — that's what `Sandbox-Empty.wsb`
   maps in. Just republish before each run.
2. If you need a real install to finish, set the three env vars above near the top of
   `scripts/Setup-Sandbox.ps1` (they're passed through as process-scope vars before the installer
   launches).
3. Double-click `Sandbox-Empty.wsb`. It boots a clean Windows instance, resets the sandbox
   account's password to a known value (one UAC consent click — see `Account password.txt` on the
   Desktop; the account's real, Windows-generated password is never surfaced to a human normally,
   so if you skip this step there's nothing to type when the wizard asks for it), copies the build
   to a writable local path, drops two desktop shortcuts ("Run RFQ Installer", "Collect
   Diagnostics"), and auto-launches the installer.
4. Walk the wizard. If you test Windows Service mode with the Current User service account, use
   the password from `Account password.txt` when prompted.
5. **Before closing the sandbox**, double-click "Collect Diagnostics" — it writes a timestamped
   report (installer.log, crash.log if any, service states, uninstall registry key, install dir
   listing, redacted `.env`) to `test-environments/output/<timestamp>/` on the host. Anything not
   collected before you close the sandbox window is gone for good.

Caveat: the sandbox's default user (`WDAGUtilityAccount`) is a local administrator, so this only
exercises the one-click-consent UAC path, not the "standard user typing admin credentials" path
(scenario #12 from the earlier discussion) — use the Hyper-V VM with a non-admin account for that
one later.

## Scenario 2 — All existing (Hyper-V + checkpoints)

One-time setup, then cheap to repeat:

1. `hyperv\New-BaseVM.ps1 -IsoPath <path-to-windows-iso>` — creates the VM, attaches the ISO,
   boots it. Walk through Windows Setup + Windows Update by hand in `vmconnect.exe` (there's no
   unattended-OOBE tooling here, same one-time cost as setting up any other VM), then create a
   local admin account you'll reuse for every PowerShell Direct call below.
2. `hyperv\New-Checkpoint.ps1 -CheckpointName clean` — snapshot the freshly-patched, nothing-
   installed state.
3. Build an *older* `RfqInstaller` (whatever version you want "already installed" to mean — check
   out an earlier commit, build it) and `hyperv\Push-ToGuest.ps1 -Credential (Get-Credential)` to
   copy it in. Note: any commit from before this project's Demo→RfqInstaller rename will build as
   `RfqInstaller.Demo\bin\...\RfqInstaller.Demo.exe` instead — `Push-ToGuest.ps1`'s `-BuildSource`/
   the exe name it copies won't match, so pass `-BuildSource` explicitly for those older commits
   (it fails loudly rather than silently if the path's wrong, so this is safe to get wrong once).
4. `vmconnect.exe localhost RFQ-Test-Base`, run that older installer through the wizard by hand
   (Windows Service mode, so you get a real Postgres + DB + encryption key + a downloaded model),
   let it finish.
5. `hyperv\New-Checkpoint.ps1 -CheckpointName existing-all` — this is now your reusable "all
   preexisting" starting point. Repeat step 3-5 with the *current* model version instead of an
   older one if you also want the `existing-same-model` variant from the scenario list — same
   process, different checkpoint name.

Then, for every actual test run against the *current* installer build:

```powershell
.\hyperv\Restore-Scenario.ps1 -CheckpointName existing-all
.\hyperv\Push-ToGuest.ps1 -Credential (Get-Credential)      # copies today's build in
vmconnect.exe localhost RFQ-Test-Base                        # walk the wizard by hand
.\hyperv\Collect-Diagnostics.ps1 -Credential (Get-Credential) # pulls the report back to output\
```

`Restore-Scenario.ps1` is what makes this reproducible: every run starts from the exact same disk
state (same DB, same key, same model already on disk) instead of whatever the last run left
behind, and it's seconds instead of re-running a 30GB download.

## Scenario 3 — Legacy-installed (Hyper-V, old Inno installer as the init state)

One important difference from Scenario 2: the old installer doesn't bundle Postgres — it expects
a real, separately-installed **system-wide PostgreSQL on port 5432** (`setup_database_auto.ps1`
hard-checks for `psql.exe` on PATH and connects to `localhost:5432`), whereas the new installer
provisions its own **private instance on a different port**. That mismatch is itself worth
watching for during the test, not just the credential/key hand-off.

One-time setup, from a `clean` checkpoint:

1. `.\hyperv\Restore-Scenario.ps1 -CheckpointName clean`
2. In `vmconnect.exe`, install a real PostgreSQL server (the standard EDB Windows installer) on
   the default port 5432, and note the `postgres` superuser password you set.
3. `.\hyperv\Push-LegacyInstaller.ps1 -Credential (Get-Credential)` — copies
   `download_and_install.ps1` and `setup_database_auto.ps1` from the repo root into
   `C:\LegacyInstaller` on the guest.
4. In the `vmconnect.exe` console (not scripted — see why below), run **one** of the two variants
   below, depending on which starting state you want to checkpoint. The encryption key is entirely
   `download_and_install.ps1`'s own concern (`-AzureKeyGenerate` / `-AzureKeyCustom`, both default
   to unset) — **not** `setup_database_auto.ps1`, which only ever touches the DB/credentials, never
   the key.

   **Variant A — with an Azure encryption key** (the common case: most real customers have one):
   ```powershell
   cd C:\LegacyInstaller
   .\download_and_install.ps1 -InstallPath "C:\Program Files\RFQ Application" `
       -GitHubToken <your PAT> -AWSKey <key> -AWSSecret <secret> -AzureKeyGenerate -NonInteractive
   ```

   **Variant B — without one** (older/edge-case installs that never got one set):
   ```powershell
   cd C:\LegacyInstaller
   .\download_and_install.ps1 -InstallPath "C:\Program Files\RFQ Application" `
       -GitHubToken <your PAT> -AWSKey <key> -AWSSecret <secret> -NonInteractive
   ```
   Leaving out `-AzureKeyGenerate`/`-AzureKeyCustom` writes `AZURE_CONFIG_ENCRYPTION_KEY=` empty —
   this is what the script does by default, so it's easy to end up here without meaning to.

   Either way: type the GitHub PAT / AWS key+secret directly into the console rather than saving
   them into any script or file in this repo — `Push-LegacyInstaller.ps1` deliberately stops short
   of running this step for that reason. `-InstallPath` must be set explicitly to match what the
   real Inno installer would have used (`{autopf}\RFQ Application` = `C:\Program Files\RFQ
   Application`); the script's own bare default is `%LOCALAPPDATA%\RFQApplication`, which would
   land somewhere the new installer's "existing install" detection won't be looking.
5. Still in the console: `cd "C:\Program Files\RFQ Application"; .\setup_database_auto.ps1` —
   creates the DB/user against the Postgres from step 2, and stores
   `RFQApplication_SQL_SUPER_USER` / `RFQApplication_RFQ_USER_PASSWORD` in Credential Manager. Does
   not touch the encryption key either way.
6. `.\hyperv\New-Checkpoint.ps1 -CheckpointName existing-legacy-installer-with-key` (Variant A) or
   `-CheckpointName existing-legacy-installer-no-key` (Variant B).

From then on, testing against either is the same loop as Scenario 2 —
`Restore-Scenario.ps1 -CheckpointName existing-legacy-installer-with-key` (or `-no-key`),
`Push-ToGuest.ps1` to drop in the *new* installer build, `vmconnect.exe` to run it — on
`AdvancedOptionsPage`, Variant A should show "keep the existing key (recommended)" already
selected, Variant B should behave like a first install and generate one — then
`Collect-Diagnostics.ps1` to pull the report back.

## Not built yet

Everything above only covers scenarios 1, 4/5, and the legacy-installer variant (with and without
an existing encryption key) from the original list (empty; all-existing with old or same model,
from either installer generation). The rest — no-Postgres-but-DB-present, corrupted (not just
missing) encryption key, expired license, non-admin elevation, domain-joined `DOMAIN\user`,
disk-space exhaustion, port conflicts — are just more
checkpoint names off the same `hyperv/` scripts (revert to `clean` or `existing-*`, provision the
specific broken state by hand, checkpoint it, reuse). Ask when you want the next batch scaffolded.

No silent/unattended install mode exists yet, so every provisioning pass and every test run still
needs a human clicking through the wizard once in `vmconnect.exe`. If this becomes the bottleneck,
UI automation (e.g. FlaUI) driving the WPF wizard programmatically would be the next investment —
not built now since it's a real chunk of work on its own and wasn't asked for.
