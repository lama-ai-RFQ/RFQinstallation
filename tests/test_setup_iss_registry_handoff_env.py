#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"
REGISTRY_MACRO = "'{#RfqRegistryHandoffKey}'"


def code_section(text: str) -> str:
    start = re.search(r"(?im)^\[Code\]\s*$", text)
    assert start, "setup.iss must contain [Code]"
    next_section = re.search(r"(?m)^\[[^\]]+\]\s*$", text[start.end() :])
    end = start.end() + next_section.start() if next_section else len(text)
    return text[start.end() : end]


def handoff_registry_calls(code: str) -> list[str]:
    calls: list[str] = []
    for line in code.splitlines():
        if "HKEY_CURRENT_USER" not in line:
            continue
        if not re.search(r"\bReg(?:WriteStringValue|QueryStringValue|DeleteKeyIncludingSubkeys)\s*\(", line):
            continue
        calls.append(line.strip())
    return calls


def test_registry_handoff_key_is_a_full_value_env_var_with_default() -> None:
    text = SETUP.read_text(encoding="utf-8")

    assert re.search(
        r'(?ms)^#define\s+RfqRegistryHandoffKey\s+GetEnv\("RFQ_REGISTRY_HANDOFF_KEY"\)\s*'
        r'^#if\s+RfqRegistryHandoffKey\s*==\s*""\s*'
        r'^\s*#define\s+RfqRegistryHandoffKey\s+"Software\\RFQApplication\\Installer"\s*'
        r'^#endif\s*$',
        text,
    )


def test_handoff_registry_calls_use_the_preprocessed_full_key() -> None:
    code = code_section(SETUP.read_text(encoding="utf-8"))
    calls = handoff_registry_calls(code)

    assert calls, "expected registry handoff calls to remain present"
    assert all(REGISTRY_MACRO in call for call in calls), (
        "HKCU installer handoff calls must use RFQ_REGISTRY_HANDOFF_KEY via "
        "{#RfqRegistryHandoffKey}"
    )


def test_uninstall_deletes_the_same_preprocessed_registry_key() -> None:
    code = code_section(SETUP.read_text(encoding="utf-8"))

    assert (
        "RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, '{#RfqRegistryHandoffKey}')"
        in code
    )
    assert "HKCU\\{#RfqRegistryHandoffKey}" in code


def test_registry_handoff_no_longer_has_prefix_recovery_helpers() -> None:
    code = code_section(SETUP.read_text(encoding="utf-8"))

    forbidden = [
        "ResolveRegistryHandoffPath",
        "ResolveUninstallRegistryHandoffPath",
        "RecoverPrefixFromInstallManifest",
        "RFQ_INSTANCE_PREFIX",
        "rfq_instance_prefix",
    ]
    for token in forbidden:
        assert token not in code
