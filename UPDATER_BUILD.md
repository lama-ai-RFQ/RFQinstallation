# Bundled `windows_updater.exe` — BUILD DEPENDENCY (must rebuild before release)

`windows_updater.exe` at the repo root is the updater binary shipped to customers.
Both shippers source it:

- **New installs** — `setup.iss` `[Files]` bundles it into `{app}\windows_updater.exe`,
  and `download_and_install.ps1` creates the `RFQUpdaterService` from that path.
- **Existing fleet** — `updater-bootstrap.iss` bundles it and `bootstrap-updater.ps1`
  swaps the old on-disk copy for it (see below).

## ⚠ The bundled binary MUST be rebuilt before any release

The copy committed here is a **placeholder / potentially stale** binary (it predates
rfqautomation's updater SELF-UPDATE work — capability A). It must be replaced with a
fresh **Windows** build of rfqautomation's updater that includes the self-update path:

- Source: rfqautomation `windows/updater` + the new `self_update.py`.
- The self-update build is the one that special-cases `updater.zip` from the release
  manifest and replaces `windows_updater.exe` via a one-shot SYSTEM scheduled task.
- That build is **user-run on a Windows host** and is **not** produced in this Linux
  worktree. Do not fabricate or hand-edit the binary here — drop in the real artifact.

Until this binary is rebuilt, neither shipper actually delivers self-update capability;
they only deliver the prerequisites and the swap *mechanism*.

### Release checklist

1. Build `windows_updater.exe` from rfqautomation capability A on Windows.
2. Replace `/windows_updater.exe` in this repo with that artifact.
3. (Recommended) record its version/hash here.
4. Compile `setup.iss` (new installs) and `updater-bootstrap.iss` (existing fleet),
   code-sign both `.exe` outputs.

## Why the updater service is self-update-ready (new installs)

Capability A's self-update replaces `windows_updater.exe` from a one-shot scheduled
task running as **SYSTEM (LocalSystem)**, which must be able to stop and start the
updater service.

- `download_and_install.ps1` creates `RFQUpdaterService` via NSSM (fallback `sc.exe`)
  and **never sets `ObjectName`**, so the service runs as **LocalSystem** — the same
  principal as a SYSTEM scheduled task. A SYSTEM task therefore has rights to
  `nssm stop/start RFQUpdaterService` and `sc stop/start RFQUpdaterService`.
- The staging prerequisite directory `{app}\updates` is created by both `setup.iss`
  (`[Dirs]`) and `download_and_install.ps1` (idempotent `New-Item`). The app writes
  `updater.zip` there; the updater stages its replacement under
  `updates\updater_staged\`. With default inherited ACLs the LocalSystem updater can
  read/write it.

Service name, display name, and description are env-var-overridable
(`RFQ_UPDATER_SERVICE_NAME` etc., defaults `RFQUpdaterService` /
`RFQ Application Updater Service`), matching the INFA-669/670/671 direct-env-var
identity pattern.
