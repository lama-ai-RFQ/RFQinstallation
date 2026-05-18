#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"
PREFIX_PATTERN = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$")


def require_prefix_product_surface() -> None:
    text = SETUP.read_text(encoding="utf-8")
    assert re.search(r"(?im)^function\s+GetRfqInstancePrefix\b", text), (
        "setup.iss must expose GetRfqInstancePrefix before prefix validation "
        "reference checks are meaningful"
    )


def is_valid_non_empty_prefix(value: str) -> bool:
    return bool(PREFIX_PATTERN.fullmatch(value))


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


def global_var_blocks_before(source: str, routine_name: str) -> list[str]:
    routine = re.search(
        rf"(?im)^(?:function|procedure)\s+{re.escape(routine_name)}\b.*?;\s*$",
        source,
    )
    assert routine, f"{routine_name} routine must exist"
    preamble = source[: routine.start()]
    return [
        match.group("body")
        for match in re.finditer(
            r"(?ims)^\s*var\s*(?P<body>.*?)(?=^\s*(?:const|type|function|procedure)\b)",
            preamble,
        )
    ]


def has_regex_validator(code: str) -> bool:
    compact = re.sub(r"\s+", "", code)
    return (
        "A-Za-z0-9" in code
        and "A-Za-z0-9._-" in code
        and "{0,62}" in code
        and "^" in code
        and "?" in code
    ) or "^[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$" in compact


def has_character_validator(code: str) -> bool:
    length_guard = re.search(
        r"(?is)\bLength\s*\([^)]*\)\s*>\s*64|64\s*<\s*Length\s*\(",
        code,
    )
    first_last_guard = (
        re.search(r"(?is)(?:Copy\s*\([^,]+,\s*1\s*,\s*1\s*\)|\[[^\]]*1[^\]]*\])", code)
        and re.search(r"(?is)(?:Length\s*\([^)]*\)|\[[^\]]*Length\s*\()", code)
    )
    allowed_chars = all(token in code for token in ("'A'", "'Z'", "'a'", "'z'", "'0'", "'9'"))
    separators = all(token in code for token in ("'.'", "'_'", "'-'"))
    rejects_bad_chars = re.search(r"(?is)\bExit\b|\bResult\s*:=\s*False\b", code)
    return bool(length_guard and first_last_guard and allowed_chars and separators and rejects_bad_chars)


def test_reference_prefix_regex_accepts_contract_examples() -> None:
    valid = [
        "e2e-test-1234",
        "qa.01",
        "ci_runner-7",
        "A",
        "a-b",
        "A" * 64,
    ]

    assert all(is_valid_non_empty_prefix(value) for value in valid)
    require_prefix_product_surface()


def test_reference_prefix_regex_rejects_contract_examples() -> None:
    invalid = [
        " ",
        "/",
        "\\",
        ":",
        '"',
        "'",
        "*",
        "?",
        ">",
        "<",
        "|",
        "\x00",
        "\x1f",
        "-foo",
        "foo-",
        "A" * 65,
    ]

    assert is_valid_non_empty_prefix("") is False
    assert all(not is_valid_non_empty_prefix(value) for value in invalid)
    require_prefix_product_surface()


def test_empty_prefix_is_unset_not_a_sanitized_value() -> None:
    assert "" == ""
    assert not is_valid_non_empty_prefix("")
    require_prefix_product_surface()


def test_setup_iss_reads_validates_and_fails_fast_on_prefix() -> None:
    require_prefix_product_surface()
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    prefix_body = routine_body(code, "GetRfqInstancePrefix")

    assert re.search(r"GetEnv\s*\(\s*'RFQ_INSTANCE_PREFIX'\s*\)", prefix_body), (
        "GetRfqInstancePrefix must read RFQ_INSTANCE_PREFIX from the process environment"
    )
    assert re.search(r"\bMsgBox\s*\(", code), (
        "invalid non-empty prefixes must surface a structured installer error"
    )
    assert re.search(r"\b(?:Abort|RaiseException)\b", code), (
        "invalid non-empty prefixes must abort instead of falling back to the default identity"
    )
    assert has_regex_validator(code) or has_character_validator(code), (
        "setup.iss must validate the prefix with the contract regex or an equivalent "
        "character-by-character implementation"
    )


def test_get_rfq_instance_prefix_is_memoized_and_returns_empty_for_unset_env() -> None:
    require_prefix_product_surface()
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    prefix_body = routine_body(code, "GetRfqInstancePrefix")
    var_blocks = "\n".join(global_var_blocks_before(code, "GetRfqInstancePrefix"))

    cached_prefix_var = re.search(
        r"(?im)^\s*\w*(?:Cached|Cache)?\w*(?:Prefix|RfqInstance)\w*\s*:\s*string\s*;",
        var_blocks,
    )
    resolved_flag_var = re.search(
        r"(?im)^\s*\w*(?:Prefix|RfqInstance)\w*(?:Resolved|Loaded|Cached|Initialized)\w*\s*:\s*boolean\s*;"
        r"|^\s*\w*(?:Resolved|Loaded|Cached|Initialized)\w*(?:Prefix|RfqInstance)\w*\s*:\s*boolean\s*;",
        var_blocks,
    )

    assert cached_prefix_var and resolved_flag_var, (
        "GetRfqInstancePrefix must be memoized with module-level Pascal var state, "
        "including a cached prefix string and a resolved/loaded Boolean flag"
    )

    env_reads = re.findall(r"GetEnv\s*\(\s*'RFQ_INSTANCE_PREFIX'\s*\)", prefix_body)
    assert len(env_reads) == 1, (
        "GetRfqInstancePrefix must read RFQ_INSTANCE_PREFIX exactly once in its "
        "body and reuse the memoized value on subsequent calls"
    )

    empty_return_path = re.search(
        r"(?is)\bif\b(?:(?!\belse\b).){0,300}(?:=\s*''|''\s*=)"
        r"(?:(?!\belse\b).){0,300}\bthen\b(?:(?!\belse\b).){0,300}"
        r"(?:\bResult\s*:=\s*''\s*;|\bExit\s*\(\s*''\s*\))",
        prefix_body,
    )
    assert empty_return_path, (
        "GetRfqInstancePrefix must have an explicit Result := '' or Exit('') path "
        "when RFQ_INSTANCE_PREFIX is unset or empty"
    )
