These tests statically assert installer contracts over `setup.iss` and supporting scripts:

- **INFA-130** — `setup.iss` encryption-key prefill behavior. Run from the worktree root with `python3 tests/test_setup_iss_encryption_key_prefill.py`.
- **INFA-669** — full-name identity env vars (AppId / AppName / AppVersion via `#GetEnv` with literal defaults). Run with `python3 -m pytest tests/test_setup_iss_identity_strings.py tests/test_setup_iss_appid_env_contract.py tests/test_setup_iss_registry_handoff_env.py` plus the Pester coexistence suite `pwsh -NoProfile -Command "Invoke-Pester -Path tests/setup-iss-identity-coexistence.Tests.ps1"`.
- **INFA-670** — direct full-name env var PowerShell/batch identity behavior. Run from the worktree root with `pwsh -NoProfile -Command "Invoke-Pester -Path tests/rfq-full-name-env-vars.Tests.ps1"`.

Python tests can also be run together with `python3 -m pytest tests`.
