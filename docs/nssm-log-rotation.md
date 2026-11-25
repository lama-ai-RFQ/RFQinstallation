# NSSM service stream rotation

Both the legacy PowerShell installer and the WPF installer configure
`AppRotateFiles=1`, `AppRotateOnline=1`, and `AppRotateBytes` for
`RFQapplication` and `RFQUpdaterService`. They retain the existing stdout and
stderr paths so early startup and crash diagnostics remain available.

`RFQ_LOG_CAP_MAX_BYTES` defaults to 314572800 bytes (300 MiB) for NSSM. The
accepted value is an unsigned 32-bit NSSM base-zero integer: decimal, `0x`
hexadecimal, or a leading-zero octal value. The original value is passed through.
Invalid values fail validation before service replacement in the registration
routine. Earlier installer work may already have stopped services.

For compatibility with PR35, zero remains accepted and disables the size
threshold. Python logging uses the same environment name with its own parser
and defaults; its behavior is unchanged.

These settings request active-file rotation. They do not remove rotated archives
or establish a total disk-retention bound. Actual thresholds, overshoot, archive
growth, permissions, and the selected NSSM executable require Windows validation.
The legacy `sc.exe` fallback does not gain NSSM redirection or rotation.

Legacy setting failures remain warnings recorded among skipped steps. WPF uses
its existing setting-error mechanism and does not start a service if a rotation
setting fails. Successful service registration/startup is separate from app
readiness or update completion.
