#!/usr/bin/env python3
from __future__ import annotations

import re
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"
NAMESPACE = uuid.UUID("A1B2C3D4-E5F6-7890-ABCD-EF1234567890")

VECTORS = {
    "e2e-test-1234": "{{2119A93C-EAC4-5130-BC42-69731D056F4E}",
    "e2e-12345-1": "{{12AFF6CB-1A9D-5816-A8B0-D251114EA721}",
    "e2e-12345-2": "{{7328E57A-DC20-530C-830A-1E3DE818CBCB}",
    "qa.01": "{{12E728BB-5065-50A8-A5DA-F428D00DF88E}",
    "ci_runner-7": "{{5660A939-0881-5675-8EED-E492084B2EE8}",
}


def require_guid5_product_surface() -> None:
    text = SETUP.read_text(encoding="utf-8")
    assert re.search(r"(?im)^function\s+GuidV5\b", text), (
        "setup.iss must expose the contracted GuidV5 Pascal implementation"
    )
    assert re.search(r"(?im)^function\s+GetAppId\b", text), (
        "setup.iss must expose GetAppId before vector checks are meaningful"
    )


def formatted_uuid5(prefix: str) -> str:
    return "{{" + str(uuid.uuid5(NAMESPACE, prefix)).upper() + "}"


def section(text: str, name: str) -> str:
    start = re.search(rf"(?im)^\[{re.escape(name)}\]\s*$", text)
    assert start, f"setup.iss must contain [{name}]"
    next_section = re.search(r"(?m)^\[[^\]]+\]\s*$", text[start.end() :])
    end = start.end() + next_section.start() if next_section else len(text)
    return text[start.end() : end]


def routine_body(source: str, name: str) -> str:
    start = re.search(
        rf"(?im)^function\s+{re.escape(name)}\b.*?;\s*$",
        source,
    )
    assert start, f"{name} function must exist"
    next_routine = re.search(
        r"(?im)^(?:function|procedure)\s+\w+\b.*?;\s*$",
        source[start.end() :],
    )
    end = start.end() + next_routine.start() if next_routine else len(source)
    return source[start.start() : end]


def test_contract_guid5_vectors_match_python_uuid5_oracle() -> None:
    for prefix, expected in VECTORS.items():
        actual_uuid = uuid.uuid5(NAMESPACE, prefix)
        actual = "{{" + str(actual_uuid).upper() + "}"

        assert actual == formatted_uuid5(prefix)
        assert actual == expected
        assert actual_uuid.version == 5
        assert actual_uuid.variant == uuid.RFC_4122
        assert actual[16] == "5"
        assert actual[21] in {"8", "9", "A", "B"}

    require_guid5_product_surface()


def test_setup_iss_exposes_guid5_pascal_surface_for_same_vectors() -> None:
    require_guid5_product_surface()
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    guid5_body = routine_body(code, "GuidV5")
    get_app_id_body = routine_body(code, "GetAppId")

    assert re.search(
        r"(?i)function\s+GuidV5\s*\(\s*NamespaceBytes\s*:\s*array\s+of\s+Byte\s*;\s*Name\s*:\s*string\s*\)\s*:\s*string\s*;",
        guid5_body,
    ), "GuidV5 must expose the contracted Pascal signature"

    assert "A1B2C3D4-E5F6-7890-ABCD-EF1234567890" in code or re.search(
        r"(?is)\bNamespace\w*\s*:\s*array\s*\[[^\]]+\]\s*of\s*Byte\s*=\s*\([^)]*\$A1[^)]*\$90[^)]*\)",
        code,
    ), "setup.iss must keep the namespace UUID as a visible constant"

    assert re.search(r"\bWSHA1\b|\bSHA1\b", guid5_body, re.I), (
        "GuidV5 must hash NamespaceBytes || UTF-8(Name) with SHA-1"
    )
    assert re.search(r"\bGuidV5\s*\(", get_app_id_body), (
        "GetAppId must route prefixed AppId generation through GuidV5"
    )
