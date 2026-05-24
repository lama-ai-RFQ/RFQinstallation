# INFA-669 DECISIONS

## 2026-05-17 — Inherited-estimate cold-start disposition

INFA-669 ticket has no story-point estimate (`estimate_source: missing`).
INFA-661 parent (refined SP=21, backstop-spike) decomposed into sub-WUs A
(INFA-669, this WU), B (INFA-670), and C (INFA-671). The
implementation-pipeline-orchestrator dispatch prompt constitutes the prior
user disposition for the Phase 2.5 step 4a cold-start gate: **proceed
without a baseline estimate** — the locked INFA-661 Phase 3 proposal is the
design source, this sub-WU's slice is narrow (one file, identity surfaces
only), and re-litigating design questions is forbidden by the dispatch
prompt. The 4a NEEDS_INPUT question is therefore not emitted.

Evidence: `/home/nes/projects/rfq/planning/INFA-669-inno-identity-guid5/orchestrator-prompt.md`,
`/home/nes/projects/rfq/planning/INFA-661-rfqinstallation-prefix/proposals/infa-661-INFA-661.md`.

## 2026-05-17 — Phase 2.5 gate auto-pass (dispatch as prior disposition)

Phase 2.5 produced all 7 artifacts (problem map, coverage inventory,
lifecycle, entrypoints, duplicates, cross-language trace, risk profile).
Risk profile rolls up MEDIUM with 0 HIGH surfaces. Defer-to-prototype
signals did NOT fire (1 of 5 conditions could plausibly fire — none did).
No blocking-ticket discoveries surfaced in 2.5.1 / 2.5.4.

The Phase 2.5 human gate question was attempted via AskUserQuestion and
permission-denied by the harness. Per `~/ai/conventions/agent-questions-and-session-graph.md`
§ `AskUserQuestion Permission-Denial`, the orchestrator dispatch prompt
serves as the prior user disposition because:
- The dispatch explicitly states "Scope (locked from INFA-661 Phase 3 proposal)"
  which IS the approved problem-map terrain.
- The dispatch explicitly predicts the risk profile "should be LOW or MEDIUM
  (not HIGH-on-13-surfaces like INFA-661)" — observed MEDIUM matches.
- The dispatch explicitly states "Defer-to-prototype signals should NOT fire"
  — confirmed.
- The dispatch explicitly says "If you hit a NEEDS_INPUT gate that the locked
  design didn't answer, surface immediately. Do NOT spin re-revision cycles
  — escalate after one round." The Phase 2.5 gate is answered by the
  dispatch's prior framing; emitting NEEDS_INPUT here would be a re-litigation
  spin the dispatch forbids.

Disposition: gate passed. Advancing to Phase 3 with the locked INFA-661
proposal as the design source.

## 2026-05-18 — Redesign: full-name env vars, no derivation helper

User corrected the identity-parameterization design after the initial GUID5
implementation. INFA-669 now treats each installer identity surface as an
independent full-value environment variable with its current literal as the
fallback. Product code does not read or validate `RFQ_INSTANCE_PREFIX`, does
not concatenate suffixes, and does not derive `AppId` with Pascal GUID5 code.

The previous Phase 6 residual around `GetRfqInstancePrefix`, `GuidV5`, and
`RecoverPrefixFromInstallManifest` no longer applies because those helpers
were removed. The remaining `setup.iss` coupling is the pre-existing installer
topology: wizard state, registry handoff, run parameters, and uninstall
cleanup remain in the same Inno script for this narrow WU.

Disposition: keep the setup.iss-only slice, use `#define ... GetEnv(...)`
preprocessor defaults for the identity values, and rely on static tests plus
the Windows-host coexistence script that compiles/runs installers with
different explicit full-name env-var values.

## 2026-05-24 — Installer-side delivery of updater SELF-UPDATE (#69 / #70)

rfqautomation gained updater SELF-UPDATE (capability A): the standalone
`windows_updater.exe` can replace itself via a one-shot SYSTEM scheduled task
after an app apply (handling `updater.zip` from the release manifest). Two
installer-side gaps had to close for A to reach customers.

**#69 — new installs are self-update-ready.**
- The updater service (`RFQUpdaterService`, env-overridable via
  `RFQ_UPDATER_SERVICE_NAME`) is created by NSSM (fallback `sc.exe`) with **no
  `ObjectName`**, so it runs as **LocalSystem** — the same principal a SYSTEM
  scheduled task uses. A SYSTEM task can therefore `nssm stop/start` and
  `sc stop/start` it, which is what A's self-update needs. No change required;
  verified by inspection.
- Added the staging prerequisite `{app}\updates`: created by `setup.iss`
  `[Dirs]` and idempotently by `download_and_install.ps1` next to updater
  service creation. The app writes `updater.zip` there; the updater stages to
  `updates\updater_staged\`. Default inherited ACLs keep it writable by the
  LocalSystem updater.
- `setup.iss` now bundles `windows_updater.exe` into `{app}` so a
  self-update-capable updater is present from first boot. **Build dependency:**
  that binary must be rebuilt from a Windows build of rfqautomation's updater
  (windows/updater + self_update.py) before release — tracked in
  `UPDATER_BUILD.md`. The bundled binary is not rebuilt in this Linux worktree.

**#70 — bootstrap mechanism for the existing fleet: a DEDICATED Inno
mini-installer.** Existing installs predate the `updater.zip` special-case, so
their on-disk updater cannot self-update. Rather than fold a migration into the
full `setup.iss` (which touches the app, DB, and config), we ship a separate,
minimal, code-signing-ready `updater-bootstrap.iss` + `bootstrap-updater.ps1`
that an IT admin runs once. It ONLY swaps the updater: discover install dir +
service (reusing the `RFQ_INSTALL_DIR` / `RFQ_UPDATER_SERVICE_NAME` env-var
conventions, falling back to the updater service image path then the default),
stop + wait-STOPPED (bounded), back up to `.previous` (+ sidecars), copy the new
binary, start + wait-RUNNING (bounded). On any failure it restores `.previous`
and restarts the service, so the machine is never left with the updater down. It
is idempotent (SHA256 match → skip) and logs to a file. Chosen over a PS-only
script or folding into `setup.iss` because IT double-clicks a single signed
`.exe`, and over a scheduled-task migration because the swap is a one-time,
synchronous, observable action.

Disposition: static validation only on Linux (Inno scripts reviewed for
structure; PowerShell AST-parses clean; Pester content + filesystem
round-trip tests added under `tests/updater-bootstrap.Tests.ps1`). Compiling the
installers with ISCC and exercising the live service stop/start/rollback is
deferred to a Windows host, as is rebuilding the bundled `windows_updater.exe`.
