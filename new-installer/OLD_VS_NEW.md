# New Windows installer — old vs new

Summary of work on `feature/new-windows-installer`.

## Old → new (side by side)


| Area                       | Before (Inno + PowerShell)                                                       | After (custom .NET/WPF)                                                                             |
| -------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Stack                      | Inno Setup wizard wrapping `download_and_install.ps1`                            | Custom WPF wizard + `RfqInstaller.Core`                                                             |
| License key                | Already existed in the **app** (runtime check). Installer did **not** collect it | Same `RFQ.xxx.yyy` key, now collected on a License page                                             |
| Download auth              | GitHub token + AWS key/secret/region                                             | License activation through `license-api.scint.ai`; short-lived CloudFront URLs only                 |
| License check              | App-only at runtime                                                              | Fast local signature check followed by server activation, entitlement and device-limit checks       |
| Downloads                  | Python/boto3/CloudFront; needs PATH                                              | Native HTTPS with required size and SHA-256 verification; no Python or AWS SDK                      |
| Postgres                   | Existing system install + `psql` on PATH                                         | Private bundled instance under install dir                                                          |
| TLS cert                   | OpenSSL on PATH (often first app run)                                            | Installer generates self-signed cert in .NET                                                        |
| Secrets                    | Credential Manager (or `.env` fallback)                                          | Database/settings passwords use the selected store; broker device credentials use machine DPAPI. No AWS or GitHub distribution credentials |
| Elevation                  | Always admin at startup                                                          | Only when needed (Windows Service, or Program Files). Own dialog first, then UAC; wizard resumes in the elevated process |
| Extra deps                 | Python, Postgres, NSSM, OpenSSL checks                                           | NSSM bundled; no Python/Postgres/OpenSSL                                                            |
| DB passwords               | User types superuser + RFQ user                                                  | Auto-generated                                                                                      |
| Settings password          | Prompted                                                                         | Dedicated page: type one or generate, strength meter, confirm, show/copy                            |
| Encryption key             | Separate Azure wizard pages (generate or paste)                                  | Same logic in Advanced: first install generates only (no paste); reinstall keeps existing (recommended) or generate-new with warning. Writes `AZURE_CONFIG_ENCRYPTION_KEY` and `RFQ_CONFIG_ENCRYPTION_KEY` |
| Azure / GitHub / AWS pages | Separate wizard pages                                                            | GitHub/AWS pages removed (license key covers download). Azure encryption key kept under Advanced    |
| Model download             | Yes (AWS key typed)                                                              | Not in the installer. The app downloads models after setup, same as other runtime assets            |
| Install mode               | Always a Windows service                                                         | Windows Service (recommended) or desktop `.exe` (basic). Service account only shown for service     |
| Service account            | Wizard page + terminal                                                           | Advanced dropdown (Current User recommended). Current User: native Windows Security prompt (password, not PIN/Hello), with Try Again / switch account / switch to `.exe` |
| Install size               | Inno-reported size                                                               | Fixed to real size                                                                                  |
| Progress / errors          | PowerShell window                                                                | Real progress, retry, failed page, logging. Back from a failed install only to pages already visited |
| Finish / launch            | Always “launch app”                                                              | Service: open in browser, not launch exe                                                            |
| Uninstall                  | Inno uninstaller                                                                 | Dedicated WPF uninstaller; can view stored DB/settings passwords from Credential Manager or `.env`  |


## Open items / suggestions

- Publish and validate a complete Windows broker catalog before producing a customer installer.
- `README.md` / `USER_QUICK_START.md` no longer copied into the install directory (docs-only, nothing reads them at runtime)
- The server URL shown in the installer is a bare `localhost` — doesn't look like what a customer will actually see/use, and doesn't surface the port at all
- Add a revocation check to the license broker (no way to invalidate a leaked/issued key today)
- Settings password: no way to reset it from inside the app if forgotten
- Uninstaller
- Dark mode

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
- `.env` was missing `DB_PORT` (app couldn't reach the private Postgres instance)
- `.env` was missing a real `MODEL_PATH` (downloaded model was silently unfindable)
- Desktop shortcut wasn't removed on uninstall
- Reinstalling over an existing Postgres data directory generated a mismatched new superuser password
- "Reinstalling" options on Advanced page now only show when an install is actually detected
