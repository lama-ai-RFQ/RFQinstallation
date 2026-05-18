These tests statically assert installer contracts:

- INFA-130 `setup.iss` encryption-key prefill behavior. Run from the worktree root with `python3 tests/test_setup_iss_encryption_key_prefill.py`.
- INFA-670 direct full-name env var PowerShell/batch identity behavior. Run from the worktree root with `pwsh -NoProfile -Command "Invoke-Pester -Path tests/rfq-full-name-env-vars.Tests.ps1"`.
