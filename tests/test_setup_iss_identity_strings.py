#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"


def require_install_time_identity_surface() -> None:
    text = SETUP.read_text(encoding="utf-8")
    assert "AppId={code:GetAppId}" in text, (
        "setup.iss must route AppId through the install-time identity callback"
    )
    assert "AppName={code:ResolveAppName}" in text, (
        "setup.iss must route AppName through install-time identity resolution"
    )


def section(text: str, name: str) -> str:
    start = re.search(rf"(?im)^\[{re.escape(name)}\]\s*$", text)
    assert start, f"setup.iss must contain [{name}]"
    next_section = re.search(r"(?m)^\[[^\]]+\]\s*$", text[start.end() :])
    end = start.end() + next_section.start() if next_section else len(text)
    return text[start.end() : end]


def setup_directives(setup_section: str) -> dict[str, str]:
    directives: dict[str, str] = {}
    for line in setup_section.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(";") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        directives[key.strip()] = value.strip()
    return directives


def defines(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for match in re.finditer(r'(?im)^\s*#define\s+(\w+)\s+"([^"]*)"\s*$', text):
        result[match.group(1)] = match.group(2)
    return result


def effective_value(value: str, define_map: dict[str, str]) -> str:
    define_ref = re.fullmatch(r"\{#(\w+)\}", value)
    if define_ref:
        return define_map[define_ref.group(1)]
    return value


def icon_name_fields(icons_section: str) -> list[str]:
    names: list[str] = []
    for line in icons_section.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith(";"):
            continue
        match = re.search(r'(?i)\bName\s*:\s*"([^"]+)"', stripped)
        if match:
            names.append(match.group(1))
    return names


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


def test_setup_identity_directives_are_install_time_resolved() -> None:
    require_install_time_identity_surface()
    text = SETUP.read_text(encoding="utf-8")
    setup = setup_directives(section(text, "Setup"))
    define_map = defines(text)

    assert effective_value(setup["AppVersion"], define_map) == "1.0.1"
    assert setup["AppId"] == "{code:GetAppId}"
    assert setup["AppName"] == "{code:ResolveAppName}"
    assert setup["DefaultDirName"] == r"{autopf}\{code:ResolveAppName}"
    assert setup["DefaultGroupName"] == "{code:ResolveAppName}"


def test_compile_time_defaults_are_preserved() -> None:
    text = SETUP.read_text(encoding="utf-8")
    setup = setup_directives(section(text, "Setup"))
    define_map = defines(text)

    assert define_map["MyAppName"] == "RFQ Application"
    assert setup["OutputBaseFilename"] == "RFQ_Application_Setup"
    require_install_time_identity_surface()


def test_all_icons_use_install_time_app_name_resolution() -> None:
    require_install_time_identity_surface()
    text = SETUP.read_text(encoding="utf-8")
    names = icon_name_fields(section(text, "Icons"))

    assert len(names) == 4, "expected the four existing [Icons] rows to remain present"
    assert all("{code:ResolveAppName}" in name for name in names), (
        "Start Menu, uninstall, desktop, and Quick Launch icon names must use "
        "install-time ResolveAppName identity resolution"
    )


def test_resolve_identity_centralizes_suffix_join_for_app_name() -> None:
    text = SETUP.read_text(encoding="utf-8")
    code = section(text, "Code")
    signature = re.search(
        r"(?im)^function\s+ResolveIdentity\s*\(\s*(?:const\s+)?(?P<param>\w+)\s*:\s*string\s*\)\s*:\s*string\s*;",
        code,
    )
    assert signature, (
        "setup.iss must expose ResolveIdentity with a single string argument"
    )

    resolve_identity_body = routine_body(code, "ResolveIdentity")
    literal_param = re.escape(signature.group("param"))
    suffix_join = re.search(
        rf"\b{literal_param}\b\s*\+\s*'-'\s*\+\s*(?:GetRfqInstancePrefix\s*\(\s*\)|\w*(?:Prefix|Cached)\w*)",
        resolve_identity_body,
        re.I,
    )
    assert suffix_join, (
        "ResolveIdentity must centralize the non-GUID identity suffix join as "
        "Literal + '-' + prefix"
    )

    resolve_app_name_body = routine_body(code, "ResolveAppName")
    assert re.search(r"\bResolveIdentity\s*\(", resolve_app_name_body), (
        "ResolveAppName must route through ResolveIdentity instead of duplicating "
        "the suffix-join logic"
    )
