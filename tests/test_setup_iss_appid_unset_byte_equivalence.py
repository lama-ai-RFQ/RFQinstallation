#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"
DEFAULT_APP_ID = "{{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}"


def section(text: str, name: str) -> str:
    start = re.search(rf"(?im)^\[{re.escape(name)}\]\s*$", text)
    assert start, f"setup.iss must contain [{name}]"
    next_section = re.search(r"(?m)^\[[^\]]+\]\s*$", text[start.end() :])
    end = start.end() + next_section.start() if next_section else len(text)
    return text[start.end() : end]


def routine_body(source: str, name: str) -> str:
    start = re.search(
        rf"(?im)^(?:function|procedure)\s+{re.escape(name)}\b.*?;\s*$",
        source,
    )
    assert start, f"{name} routine must exist"
    next_routine = re.search(
        r"(?im)^(?:function|procedure)\s+\w+\b.*?;\s*$",
        source[start.end() :],
    )
    end = start.end() + next_routine.start() if next_routine else len(source)
    return source[start.start() : end]


def test_unset_prefix_get_app_id_returns_direct_literal_before_guid5() -> None:
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    body = routine_body(code, "GetAppId")

    literal_stmt = re.search(
        rf"(?im)^\s*Result\s*:=\s*'{re.escape(DEFAULT_APP_ID)}'\s*;",
        body,
    )
    assert literal_stmt, (
        "GetAppId unset-prefix path must return the exact Inno AppId spelling "
        f"'{DEFAULT_APP_ID}' as a direct Pascal string literal"
    )

    assert "GuidV5" not in literal_stmt.group(0), (
        "the unset-prefix AppId return statement must not compute through GuidV5"
    )

    body_before_literal = body[: literal_stmt.start()]
    empty_prefix_gate = re.search(
        r"(?is)"
        r"(?:"
        r"GetRfqInstancePrefix\s*\(\s*\)\s*=\s*''"
        r"|"
        r"(\w+)\s*:=\s*GetRfqInstancePrefix\s*\(\s*\).*?\b\1\s*=\s*''"
        r")"
        r".{0,300}$",
        body_before_literal,
    )
    assert empty_prefix_gate, (
        "the direct literal return must be gated by an empty GetRfqInstancePrefix() path"
    )

    gate_to_literal = body[empty_prefix_gate.start() : literal_stmt.end()]
    assert "GuidV5" not in gate_to_literal, (
        "the empty-prefix branch must reach the direct literal without calling GuidV5"
    )


def test_get_app_id_prefixed_path_still_uses_guid5() -> None:
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    body = routine_body(code, "GetAppId")

    assert re.search(r"\bGuidV5\s*\(", body), (
        "GetAppId must use GuidV5 only for non-empty RFQ_INSTANCE_PREFIX values"
    )
