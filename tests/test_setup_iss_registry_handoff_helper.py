#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"
REGISTRY_LITERAL = r"Software\RFQApplication\Installer"


def section(text: str, name: str) -> str:
    start = re.search(rf"(?im)^\[{re.escape(name)}\]\s*$", text)
    assert start, f"setup.iss must contain [{name}]"
    next_section = re.search(r"(?m)^\[[^\]]+\]\s*$", text[start.end() :])
    end = start.end() + next_section.start() if next_section else len(text)
    return text[start.end() : end]


def routine_span(source: str, name: str) -> tuple[int, int, str]:
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
    return start.start(), end, source[start.start() : end]


def test_registry_handoff_helper_exists() -> None:
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    _, _, body = routine_span(code, "ResolveRegistryHandoffPath")

    assert REGISTRY_LITERAL in body, (
        "ResolveRegistryHandoffPath must be the single source of the default "
        "registry handoff path"
    )
    assert re.search(r"RFQApplication\s*-\s*'\s*\+\s*\w+", body) or re.search(
        r"RFQApplication-'\s*\+\s*GetRfqInstancePrefix\s*\(",
        body,
    ), "ResolveRegistryHandoffPath must derive the prefixed registry path"


def test_registry_literal_only_appears_inside_helper_body() -> None:
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    start, end, _ = routine_span(code, "ResolveRegistryHandoffPath")
    outside_helper = code[:start] + code[end:]

    raw_literal_pattern = re.compile(
        r"(?:'Software\\RFQApplication\\Installer'|Software\\\\RFQApplication\\\\Installer|Software\\RFQApplication\\Installer)"
    )
    outside_matches = list(raw_literal_pattern.finditer(outside_helper))

    assert not outside_matches, (
        "registry handoff callsites must call ResolveRegistryHandoffPath(); "
        f"found {len(outside_matches)} literal occurrence(s) outside the helper"
    )


def test_uninstall_hook_uses_resolved_handoff_path_with_fail_safe() -> None:
    code = section(SETUP.read_text(encoding="utf-8"), "Code")
    _, _, body = routine_span(code, "CurUninstallStepChanged")

    assert re.search(r"\bResolveRegistryHandoffPath\s*\(", body), (
        "CurUninstallStepChanged must delete only the registry subtree resolved "
        "through ResolveRegistryHandoffPath()"
    )
    assert re.search(r"\bRegDeleteKey(?:IncludingSubkeys)?\s*\(", body), (
        "CurUninstallStepChanged must contain the resolved registry deletion path"
    )

    diagnostic_call = r"\b(?:Log|MsgBox|RegWriteStringValue)\s*\("
    delete_call = r"\bRegDeleteKey(?:IncludingSubkeys)?\s*\("
    fail_safe_branches = [
        match.group("else_body")
        for match in re.finditer(
            rf"(?is)\bif\b.+?\bthen\b.+?\belse\b\s*(?:begin)?(?P<else_body>.+?)(?:\bend\s*;|;)",
            body,
        )
    ]
    assert fail_safe_branches, (
        "CurUninstallStepChanged must branch on path/prefix recovery so it can "
        "skip deletion when a prefixed uninstall cannot recover its target path"
    )

    diagnostic_else_branches = [
        else_body
        for else_body in fail_safe_branches
        if re.search(diagnostic_call, else_body) and not re.search(delete_call, else_body)
    ]
    assert diagnostic_else_branches, (
        "the uninstall fail-safe else branch must not call RegDeleteKey or "
        "RegDeleteKeyIncludingSubkeys, and must log or warn when deletion is skipped"
    )
