# New Windows installer — old vs new

Summary of work on `feature/new-windows-installer`.

## Old → new (side by side)


| Area                       | Before (Inno + PowerShell)                                                       | After (custom .NET/WPF)                                                                             |
| -------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Stack                      | Inno Setup wizard wrapping `download_and_install.ps1`                            | Custom WPF wizard + `RfqInstaller.Core`                                                             |
| License key                | Already existed in the **app** (runtime check). Installer did **not** collect it | Same `RFQ.xxx.yyy` key, now collected on a License page                                             |
| Download auth              | GitHub token + AWS key/secret/region                                             | License broker: valid key → short-lived S3 URLs                                                     |
| License check              | App-only at runtime                                                              | Installer: local signature check + broker                                                           |
| Downloads                  | Python/boto3/CloudFront; needs PATH                                              | Plain HTTPS; no Python/AWS SDK/PATH                                                                 |
| Postgres                   | Existing system install + `psql` on PATH                                         | Private bundled instance under install dir                                                          |
| TLS cert                   | OpenSSL on PATH (often first app run)                                            | Installer generates self-signed cert in .NET                                                        |
| Secrets                    | Credential Manager (or `.env` fallback)                                          | Current user → Credential Manager; LocalSystem/NetworkService → DPAPI; service logon password → LSA |
| Elevation                  | Always admin                                                                     | Only for service install or Program Files                                                           |
| Extra deps                 | Python, Postgres, NSSM, OpenSSL checks                                           | NSSM bundled; no Python/Postgres/OpenSSL                                                            |
| DB passwords               | User types superuser + RFQ user                                                  | Auto-generated                                                                                      |
| Settings password          | Prompted                                                                         | Still prompted                                                                                      |
| Azure / GitHub / AWS pages | Separate wizard pages                                                            | Removed (license key covers download)                                                               |
| Model download             | Yes (AWS key typed)                                                              | Yes (short-lived S3 URLs )                                                                          |
| Service account            | Wizard page + terminal                                                           | Advanced options + Windows credentials prompt                                                       |
| Install size               | Inno-reported size                                                               | Fixed to real size                                                                                  |
| Progress / errors          | PowerShell window                                                                | Real progress, retry, failed page, logging                                                          |
| Finish / launch            | Always “launch app”                                                              | Service: open in browser, not launch exe                                                            |
| Uninstall                  | Inno uninstaller                                                                 | Dedicated WPF uninstaller                                                                           |


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
- Read DB/settings passwords from DPAPI (not Credential Manager)

