# New Windows installer — old vs new

Summary of work on `feature/new-windows-installer`.

## Old → new (side by side)


| Area                       | Before (Inno + PowerShell)                                                       | After (custom .NET/WPF)                                                                             |
| -------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Stack                      | Inno Setup wizard wrapping `download_and_install.ps1`                            | Custom WPF wizard + `RfqInstaller.Core`                                                             |
| License key                | Already existed in the **app** (runtime check). Installer did **not** collect it | Same `RFQ.xxx.yyy` key, now collected on a License page                                             |
| Download auth              | GitHub token + AWS key/secret/region                                             | **Not built yet.** A valid key is meant to unlock downloads via an outside service — not decided whether that's AWS-only or AWS-primary-with-GitHub-fallback (the old script did the latter itself; see below). `LicenseBrokerClient` is an intentional placeholder pending that service's real contract |
| License check              | App-only at runtime                                                              | Installer: local signature check works today; the server-side re-check does not exist yet (placeholder) |
| Downloads                  | Python/boto3/CloudFront; needs PATH                                              | Plain HTTPS; no Python/AWS SDK/PATH (once the download service exists)                              |
| Postgres                   | Existing system install + `psql` on PATH                                         | Private bundled instance under install dir                                                          |
| TLS cert                   | OpenSSL on PATH (often first app run)                                            | Installer generates self-signed cert in .NET                                                        |
| Secrets                    | Credential Manager (or `.env` fallback)                                          | User chooses Credential Manager (recommended) or plaintext `.env`. CM only works for Current User / standalone; Network Service / Local System force `.env`. Service logon password → LSA. No DPAPI |
| Elevation                  | Always admin at startup                                                          | Only when needed (Windows Service, or Program Files). Own dialog first, then UAC; wizard resumes in the elevated process |
| Extra deps                 | Python, Postgres, NSSM, OpenSSL checks                                           | NSSM bundled; no Python/Postgres/OpenSSL                                                            |
| DB passwords               | User types superuser + RFQ user                                                  | Auto-generated                                                                                      |
| Settings password          | Prompted                                                                         | Dedicated page: type one or generate, strength meter, confirm, show/copy                            |
| Encryption key             | Separate Azure wizard pages (generate or paste)                                  | Same logic in Advanced: first install generates only (no paste); reinstall keeps existing (recommended) or generate-new with warning. Writes `AZURE_CONFIG_ENCRYPTION_KEY` and `RFQ_CONFIG_ENCRYPTION_KEY` |
| Azure / GitHub / AWS pages | Separate wizard pages                                                            | GitHub/AWS pages removed (license key covers download). Azure encryption key kept under Advanced    |
| Model download             | Yes (AWS key typed)                                                              | Same placeholder as "Download auth" above — not built yet                                            |
| Install mode               | Always a Windows service                                                         | Windows Service (recommended) or desktop `.exe` (basic). Service account only shown for service     |
| Service account            | Wizard page + terminal                                                           | Advanced dropdown (Current User recommended). Current User: native Windows Security prompt (password, not PIN/Hello), with Try Again / switch account / switch to `.exe` |
| Install size               | Inno-reported size                                                               | Fixed to real size                                                                                  |
| Progress / errors          | PowerShell window                                                                | Real progress, retry, failed page, logging. Back from a failed install only to pages already visited |
| Finish / launch            | Always “launch app”                                                              | Service: open in browser, not launch exe                                                            |
| Uninstall                  | Inno uninstaller                                                                 | Dedicated WPF uninstaller; can view stored DB/settings passwords from Credential Manager or `.env`  |


## Bugs found in a 2026-09-10 audit, fixed same day

- **`.env` was missing `DB_PORT`.** The private Postgres instance runs on port 55432
  (`PostgresBinariesConfig.DefaultPort`, chosen specifically to not collide with any pre-existing
  system Postgres on 5432) — but `ConfigureApplication` took the real port as a parameter and never
  wrote it anywhere, so `RFQautomation/backend/config/database.py`'s own default of 5432 silently
  took over. Every install would have the app trying to reach a port nothing listens on. Fixed:
  `DB_PORT` is now written from the actual provisioned port.
- **`.env` was missing `MODEL_PATH`.** Left at the literal placeholder text from `env.template`
  (`your_model_path_here`) regardless of where the model actually was/would be. Since that literal
  string isn't empty, `RFQautomation/backend/language_models/hf_language_model.py` used it directly
  instead of falling back to its own path-resolution logic, then failed the `os.path.exists` check —
  silently, just a log warning, no hard error. A customer who accepted the default "download model
  now" ended up with a fully downloaded model the app could never find. Fixed: `MODEL_PATH` is now
  always written from `plan.ModelPath` (known up front regardless of whether the model downloads
  now or later, unlike the old installer which discovered it only after downloading).
- **Desktop shortcut wasn't removed on uninstall.** Inno tracked and auto-removed it; the new
  `UninstallOrchestrator` stopped services and unregistered Add/Remove Programs but left
  `RFQ Application.lnk` on the Desktop pointing at a now-deleted install directory. Fixed.

Not fixed, left as a conscious choice to revisit: the old installer also copied `README.md` /
`USER_QUICK_START.md` into the install directory (`setup.iss`'s `[Files]`); the new installer
doesn't. Nothing at runtime reads these (checked), so it's a documentation-availability gap for the
customer, not a functional one — worth a decision, not urgent.

## Open gap found 2026-09-10: the installed app needs these credentials *after* install too

The old installer's `.env` write wasn't only for the one-time bootstrap download — several things
the **already-installed app** does on an ongoing basis read the same values back out of `.env` at
runtime:

- `AWS_KEY` / `AWS_SECRET` / `AWS_REGION` — read by `RFQautomation/backend/services/aws_downloader_service.py`,
  used by OCR models, sentence-transformer models, and the parts/cage-codes databases (see
  `backend/main/backend.py`, many call sites) to download/update those artifacts on demand, not
  just at install time.
- `GITHUB_PAT` / `GITHUB_USERNAME` — read by `RFQautomation/windows/updater/windows_updater_pkg/main.py`
  for the Windows updater's own update checks.

`InstallOrchestrator.ConfigureApplication` writes neither. Right now a real install ships whatever
literal placeholder text sits in `env.template` (`GITHUB_PAT=your_github_token_here`, no `AWS_KEY`/
`AWS_SECRET` lines at all) — meaning these ongoing app features are silently non-functional after a
new-installer install, even though the install itself appears to succeed. This was **not** part of
the original license-broker plan, which only considered the one-time install-time download; it
needs the same "outside API, license-gated" thinking applied to *ongoing* runtime credentials, not
just the initial download. Whoever designs the real service should account for this.

## Fixes & polish on the new installer

- Roadmap icon styling
- Removed accidental files
- Ignored build output
- Aligned browse button
- License placeholder position
- Progress bar animation
- Styled cancel / no-license dialogs
- Popup dialog styling
- Finish-page checkbox align
- Default model location
- Text overflow scroller
- Debug skip-steps mode
- Error handling + logging
- Crash when skipping Advanced
- Service-account dropdown restyle
- Dropdown scroller only when needed
- Windows credentials prompt
- Recommend current user
- Service password in LSA
- Keep `DOMAIN\user` / `.\user`
- Settings password page restored (generate, strength colors, confirm, validation)
- Wrong Windows password does not fail the install; stay on the confirm page
- Warn before the Windows Security prompt; Try Again / switch account / switch to `.exe`
- Don't ask for a service password until Current User is actually selected
- Standalone: hide service account from the summary
- Tooltip styling
- Restore `.env` as a password-storage option; Credential Manager disabled for Network Service / Local System; DPAPI removed
- Uninstaller can view stored passwords
- Azure encryption key: old installer logic (auto-generate on first install, keep existing on reinstall)
- License Try Again returns to the License page so the key can be re-entered
- Elevation relaunch: keep the window until the elevated UI is ready
- Don't skip password validation; don't prompt a Microsoft Account password; align prompted vs confirmed account name
- Show “Waiting for Windows Security…” first, then open the prompt
- Windows Service recommended; desktop `.exe` labeled basic
- Desktop shortcut checkbox styling
- Show-password actually shows the password
- Rename Demo → RFQ Application / `RfqInstaller`
