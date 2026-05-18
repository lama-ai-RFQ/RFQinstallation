#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"
DEFAULT_APP_ID_BODY = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
CUSTOM_APP_ID_BODY = "01234567-89AB-CDEF-0123-456789ABCDEF"


def setup_directives(text: str) -> dict[str, str]:
    section = re.search(r"(?ims)^\[Setup\]\s*(?P<body>.*?)(?=^\[[^\]]+\]\s*$)", text)
    assert section, "setup.iss must contain a [Setup] section"

    directives: dict[str, str] = {}
    for line in section.group("body").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(";") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        directives[key.strip()] = value.strip()
    return directives


def app_id_source_from_env(value: str | None) -> str:
    if value is None or value == "":
        return "{{" + DEFAULT_APP_ID_BODY + "}"
    return "{{" + value + "}"


def compiled_app_id_from_source(source_value: str) -> str:
    assert source_value.startswith("{{"), "AppId source must escape the literal opening brace"
    assert source_value.endswith("}"), "AppId source must keep the literal closing brace"
    return "{" + source_value[2:]


def test_app_id_uses_rfq_app_id_preprocessor_with_literal_default() -> None:
    text = SETUP.read_text(encoding="utf-8")
    setup = setup_directives(text)

    assert re.search(r'(?m)^#define\s+RfqAppId\s+GetEnv\("RFQ_APP_ID"\)\s*$', text)
    assert re.search(r'(?m)^#if\s+RfqAppId\s*==\s*""\s*$', text)
    assert re.search(
        rf'(?m)^\s*#define\s+RfqAppIdSource\s+"\{{\{{{DEFAULT_APP_ID_BODY}\}}"\s*$',
        text,
    )
    assert re.search(
        r'(?m)^\s*#define\s+RfqAppIdSource\s+"\{\{"\s*\+\s*RfqAppId\s*\+\s*"\}"\s*$',
        text,
    )
    assert setup["AppId"] == "{#RfqAppIdSource}"


def test_app_id_unset_compiles_to_default_literal() -> None:
    source_value = app_id_source_from_env(None)

    assert source_value == "{{" + DEFAULT_APP_ID_BODY + "}"
    assert compiled_app_id_from_source(source_value) == "{" + DEFAULT_APP_ID_BODY + "}"


def test_app_id_env_value_is_used_directly_without_derivation() -> None:
    source_value = app_id_source_from_env(CUSTOM_APP_ID_BODY)

    assert source_value == "{{" + CUSTOM_APP_ID_BODY + "}"
    assert compiled_app_id_from_source(source_value) == "{" + CUSTOM_APP_ID_BODY + "}"


def test_setup_iss_does_not_contain_guid5_or_prefix_derivation_code() -> None:
    text = SETUP.read_text(encoding="utf-8")

    forbidden = [
        "RFQ_INSTANCE_PREFIX",
        "GuidV5",
        "GetAppId",
        "GetRfqInstancePrefix",
        "ResolveIdentity",
        "ResolveAppName",
        "RecoverPrefixFromInstallManifest",
        "RFQ_NAMESPACE_UUID_BYTES",
    ]
    for token in forbidden:
        assert token not in text
