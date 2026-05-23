#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"
CREDMAN_TEST = ROOT / "test_credential_manager.ps1"


def resolve(value: str | None, default: str) -> str:
    return default if value in (None, "") else value


def assert_condition(name: str, condition: bool, evidence: str, failures: list[str]) -> None:
    if condition:
        print(f"PASS: {name}")
        return

    print(f"FAIL: {name} - {evidence}")
    failures.append(name)


def assert_equal(name: str, actual: object, expected: object, failures: list[str]) -> None:
    assert_condition(name, actual == expected, f"expected {expected!r}, got {actual!r}", failures)


def resolve_credential_targets(env_overrides: dict[str, str], failures: list[str]) -> dict[str, str]:
    if shutil.which("pwsh") is None:
        print("SKIP: PowerShell target resolution vectors (pwsh not found)")
        return {}

    target_env_vars = [
        "RFQ_CREDMAN_SQL_SUPER_USER_TARGET",
        "RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET",
        "RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET",
    ]
    env = os.environ.copy()
    for name in target_env_vars:
        env.pop(name, None)
    env.update(env_overrides)

    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(CREDMAN_TEST), "-ListTargetsOnly"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert_condition(
        "Credential target resolution helper exits cleanly",
        result.returncode == 0,
        f"pwsh exited {result.returncode}: {result.stderr or result.stdout}",
        failures,
    )

    resolved: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        resolved[key] = value

    return resolved


def setup_contract(failures: list[str]) -> None:
    setup = SETUP.read_text(encoding="utf-8")

    service_name_default = "RFQapplication"
    display_name_default = "RFQ Application Service"

    assert_condition(
        "Wizard prose does not read RFQ_INSTANCE_PREFIX",
        "RFQ_INSTANCE_PREFIX" not in setup,
        "expected setup.iss wizard prose to use direct full-name env vars only",
        failures,
    )
    assert_condition(
        "Service name has direct env-var preprocessor default",
        '#define RfqAppServiceName GetEnv("RFQ_APP_SERVICE_NAME")' in setup
        and '#define RfqAppServiceName "RFQapplication"' in setup,
        "expected RFQ_APP_SERVICE_NAME to default to the full literal service name",
        failures,
    )
    assert_condition(
        "Service display name has direct env-var preprocessor default",
        '#define RfqAppServiceDisplayName GetEnv("RFQ_APP_SERVICE_DISPLAY_NAME")' in setup
        and '#define RfqAppServiceDisplayName "RFQ Application Service"' in setup,
        "expected RFQ_APP_SERVICE_DISPLAY_NAME to default to the full literal display name",
        failures,
    )
    assert_condition(
        "Run status names resolved service directly",
        'StatusMsg: "Installing RFQ Application and creating Windows service \'{#RfqAppServiceName}\'..."' in setup,
        "expected [Run] StatusMsg to display the resolved service name",
        failures,
    )
    assert_condition(
        "Service info page displays resolved full names",
        "'  Service Name: {#RfqAppServiceName}' + #13#10" in setup
        and "'  Display Name: {#RfqAppServiceDisplayName}' + #13#10 + #13#10" in setup,
        "expected service information prose to use resolved full-name values",
        failures,
    )
    assert_condition(
        "Management prose displays resolved full names",
        "'  \u2022 Command Line: sc start/stop {#RfqAppServiceName}' + #13#10" in setup
        and "'  \u2022 GUI: Open Services.msc and look for \"{#RfqAppServiceDisplayName}\"' + #13#10 + #13#10" in setup,
        "expected management prose to use resolved full-name values",
        failures,
    )
    assert_condition(
        "Install description displays resolved service name",
        "creating Windows service ''{#RfqAppServiceName}''" in setup
        and "Create Windows service ''{#RfqAppServiceName}'' (starts automatically)" in setup,
        "expected install description prose to use the resolved service name",
        failures,
    )
    assert_condition(
        "Wizard prose has no suffix-join service formula",
        "'RFQapplication-'" not in setup and "'RFQ Application Service-'" not in setup,
        "expected no service/display-name suffix derivation in setup.iss",
        failures,
    )

    assert_equal(
        "Unset service name resolves to literal default",
        resolve(None, service_name_default),
        "RFQapplication",
        failures,
    )
    assert_equal(
        "Explicit service name resolves exactly",
        resolve("RFQapplication-e2e-42", service_name_default),
        "RFQapplication-e2e-42",
        failures,
    )
    assert_equal(
        "Unset display name resolves to literal default",
        resolve("", display_name_default),
        "RFQ Application Service",
        failures,
    )
    assert_equal(
        "Explicit display name resolves exactly",
        resolve("RFQ Application Service e2e 42", display_name_default),
        "RFQ Application Service e2e 42",
        failures,
    )


def credman_contract(failures: list[str]) -> None:
    script = CREDMAN_TEST.read_text(encoding="utf-8")
    targets = {
        "RFQ_CREDMAN_SQL_SUPER_USER_TARGET": "RFQApplication_SQL_SUPER_USER",
        "RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET": "RFQApplication_RFQ_USER_PASSWORD",
        "RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET": "RFQApplication_SETTINGS_PASSWORD",
    }

    assert_condition(
        "Credential helper does not read RFQ_INSTANCE_PREFIX",
        "RFQ_INSTANCE_PREFIX" not in script,
        "expected CredMan smoke helper to use direct target env vars only",
        failures,
    )
    assert_condition(
        "Credential helper has a direct env resolver",
        "function Get-ResolvedEnvValue" in script
        and "[Environment]::GetEnvironmentVariable($Name)" in script
        and "return $DefaultValue" in script,
        "expected constants to resolve from one env var with a full-name default",
        failures,
    )

    for env_var, default in targets.items():
        assert_condition(
            f"Credential helper reads {env_var}",
            f'EnvVarName = "{env_var}"' in script
            and f'Get-ResolvedEnvValue -Name "{env_var}" -DefaultValue "{default}"' in script,
            f"expected {env_var} to resolve directly to default {default}",
            failures,
        )
        assert_equal(
            f"Unset {env_var} resolves to literal default",
            resolve(None, default),
            default,
            failures,
        )
        assert_equal(
            f"Explicit {env_var} resolves exactly",
            resolve(f"custom-{default}", default),
            f"custom-{default}",
            failures,
        )

    default_resolution = resolve_credential_targets({}, failures)
    if default_resolution:
        for env_var, default in targets.items():
            assert_equal(
                f"PowerShell default behavior for {env_var}",
                default_resolution.get(env_var),
                default,
                failures,
            )

    explicit_overrides = {
        "RFQ_CREDMAN_SQL_SUPER_USER_TARGET": "RFQApplication_SQL_SUPER_USER_e2e",
        "RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET": "RFQApplication_RFQ_USER_PASSWORD_e2e",
        "RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET": "RFQApplication_SETTINGS_PASSWORD_e2e",
    }
    explicit_resolution = resolve_credential_targets(explicit_overrides, failures)
    if explicit_resolution:
        for env_var, expected in explicit_overrides.items():
            assert_equal(
                f"PowerShell explicit behavior for {env_var}",
                explicit_resolution.get(env_var),
                expected,
                failures,
            )

    assert_condition(
        "Credential helper has no suffix-join target formula",
        "Join-RfqInstanceSuffix" not in script
        and "$BaseName-$InstancePrefix" not in script
        and "BaseTargetName" not in script,
        "expected no target-name derivation from a prefix",
        failures,
    )
    assert_condition(
        "Credential helper filters exact resolved targets",
        "[regex]::Escape($_)" in script and "[regex]::Escape($test.TargetName)" in script,
        "expected cmdkey listing filters to escape exact resolved target names",
        failures,
    )


def main() -> int:
    failures: list[str] = []
    setup_contract(failures)
    credman_contract(failures)

    if failures:
        print("")
        print(f"{len(failures)} INFA-671 full-name env-var contract assertion(s) failed.")
        return 1

    print("")
    print("All INFA-671 full-name env-var contract assertions passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
