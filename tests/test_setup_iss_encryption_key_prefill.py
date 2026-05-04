#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"

TEST_FILES = {
    "setup.iss",
    "tests/README.md",
    "tests/test_setup_iss_encryption_key_prefill.py",
}


def line_no(text: str, offset: int) -> int:
    return text.count("\n", 0, max(offset, 0)) + 1


def first_line_matching(text: str, pattern: str, flags: int = 0) -> int | None:
    match = re.search(pattern, text, flags)
    if not match:
        return None
    return line_no(text, match.start())


def section(text: str, name: str) -> tuple[str, int] | tuple[None, None]:
    start_match = re.search(rf"(?im)^\[{re.escape(name)}\]\s*$", text)
    if not start_match:
        return None, None
    next_match = re.search(r"(?m)^\[[^\]]+\]\s*$", text[start_match.end() :])
    end = start_match.end() + next_match.start() if next_match else len(text)
    return text[start_match.end() : end], start_match.end()


def routine_body(source: str, name: str) -> tuple[str, int] | tuple[None, None]:
    start_match = re.search(
        rf"(?im)^(?:function|procedure)\s+{re.escape(name)}\b.*?;\s*$",
        source,
    )
    if not start_match:
        return None, None
    next_match = re.search(
        r"(?im)^(?:function|procedure)\s+\w+\b.*?;\s*$",
        source[start_match.end() :],
    )
    end = start_match.end() + next_match.start() if next_match else len(source)
    return source[start_match.start() : end], start_match.start()


def find_validity_helper(code: str, code_offset: int) -> dict[str, object] | None:
    for match in re.finditer(
        r"(?im)^function\s+(\w+)\s*\(([^)]*)\)\s*:\s*Boolean\s*;\s*$",
        code,
    ):
        name = match.group(1)
        if "encryption" not in name.lower() or "key" not in name.lower():
            continue
        params = match.group(2).strip()
        if not re.fullmatch(r"(?:const\s+)?\w+\s*:\s*String", params, re.I):
            continue
        body, rel_start = routine_body(code, name)
        if body is None:
            continue
        return {
            "name": name,
            "body": body,
            "start": code_offset + rel_start,
            "decl_start": code_offset + match.start(),
        }
    return None


def find_resolver_helper(code: str, code_offset: int) -> dict[str, object] | None:
    for match in re.finditer(
        r"(?im)^function\s+(\w+)\s*\(([^)]*)\)\s*:\s*String\s*;\s*$",
        code,
    ):
        name = match.group(1)
        params = match.group(2).strip()
        if "encryption" not in name.lower() or "key" not in name.lower():
            continue
        if not re.fullmatch(r"(?:const\s+)?\w+\s*:\s*String", params, re.I):
            continue
        body, rel_start = routine_body(code, name)
        if body is None:
            continue
        if "RFQ_CONFIG_ENCRYPTION_KEY" in body and "AZURE_CONFIG_ENCRYPTION_KEY" in body:
            return {
                "name": name,
                "body": body,
                "start": code_offset + rel_start,
                "decl_start": code_offset + match.start(),
            }
    return None


def has_non_empty_guard_for_assignment(body: str, assignment_match: re.Match[str]) -> bool:
    prior_lines = body[: assignment_match.start()].splitlines()[-8:]
    prior_text = "\n".join(prior_lines)
    return bool(re.search(r"\bif\b[^;\n]*<>\s*''\s*\bthen\b", prior_text, re.I))


def run_git_diff_names() -> tuple[int, list[str], str]:
    proc = subprocess.run(
        ["git", "diff", "--name-only", "origin/main...HEAD"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    names = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    return proc.returncode, names, proc.stderr.strip()


def assertion(name: str, passed: bool, evidence: str, failures: list[str]) -> None:
    if passed:
        print(f"PASS: {name}")
    else:
        print(f"FAIL: {name} — {evidence}")
        failures.append(name)


def main() -> int:
    text = SETUP.read_text(encoding="utf-8")
    code, code_offset = section(text, "Code")
    failures: list[str] = []

    load_body, load_start = routine_body(text, "LoadExistingEnvValues")
    read_body, _ = routine_body(text, "ReadEnvValue")
    init_body, _ = routine_body(text, "InitializeWizard")
    skip_body, _ = routine_body(text, "ShouldSkipPage")

    if code is None:
        assertion("[Code] section exists", False, "setup.iss has no [Code] section", failures)
        return 1

    validity = find_validity_helper(code, code_offset)
    resolver = find_resolver_helper(code, code_offset)

    load_decl_line = first_line_matching(text, r"(?im)^procedure\s+LoadExistingEnvValues\b")
    helper_reference_region = ""
    if resolver is not None:
        helper_reference_region += str(resolver["body"])
    if load_body is not None:
        helper_reference_region += "\n" + load_body

    helper_exists = validity is not None and load_decl_line is not None
    if helper_exists:
        helper_exists = line_no(text, int(validity["decl_start"])) < load_decl_line
        helper_exists = helper_exists and str(validity["name"]) in helper_reference_region
    assertion(
        "Validity helper exists",
        helper_exists,
        "expected a Boolean Encryption/Key helper with one String parameter before LoadExistingEnvValues and referenced from the prefill path",
        failures,
    )

    helper_body = str(validity["body"]) if validity is not None else ""
    placeholder_ok = all(
        literal in helper_body
        for literal in ("your_app_encryption_key_here", "your_azure_encryption_key_here")
    )
    placeholder_ok = placeholder_ok and "CompareText" in helper_body and "SameText" not in helper_body
    assertion(
        "Validity helper rejects placeholders",
        placeholder_ok,
        "expected both placeholder literals in the validity helper and CompareText, with no SameText",
        failures,
    )

    trim_empty_ok = bool(
        re.search(r"\bTrim\s*\(", helper_body)
        and re.search(r"(?:=\s*''|''\s*=)", helper_body)
    )
    assertion(
        "Validity helper rejects empty after trim",
        trim_empty_ok,
        "expected Trim(...) and an empty-string check inside the validity helper",
        failures,
    )

    length_guard = re.search(
        r"\bLength\s*\([^)]*\)\s*(?:>=|>|=)\s*(?:3[2-9]|[4-9]\d|\d{3,})"
        r"|(?:3[2-9]|[4-9]\d|\d{3,})\s*(?:<=|<|=)\s*\bLength\s*\(",
        helper_body,
        re.I,
    )
    base64_guard = re.search(r"\b(?:Decode64|DecodeBase64|Base64Decode)\s*\(", helper_body, re.I)
    assertion(
        "No base64/length enforcement in validity helper",
        validity is not None and length_guard is None and base64_guard is None,
        "expected helper body with no Length(...) >= 32 guard and no Decode64/DecodeBase64/Base64Decode call",
        failures,
    )

    resolver_body = str(resolver["body"]) if resolver is not None else ""
    rfq_pos = resolver_body.find("RFQ_CONFIG_ENCRYPTION_KEY")
    azure_pos = resolver_body.find("AZURE_CONFIG_ENCRYPTION_KEY")
    assertion(
        "Resolver checks RFQ before Azure",
        resolver is not None and rfq_pos != -1 and azure_pos != -1 and rfq_pos < azure_pos,
        "expected resolver helper to contain RFQ_CONFIG_ENCRYPTION_KEY before AZURE_CONFIG_ENCRYPTION_KEY",
        failures,
    )

    resolver_called = (
        resolver is not None
        and load_body is not None
        and re.search(rf"\b{re.escape(str(resolver['name']))}\s*\(", load_body) is not None
    )
    assertion(
        "LoadExistingEnvValues calls the resolver",
        resolver_called,
        "expected LoadExistingEnvValues to call the resolver helper",
        failures,
    )

    assignment_matches = list(
        re.finditer(r"\bAzureKeyPage\.SelectedValueIndex\s*:=\s*1\b", load_body or "", re.I)
    )
    gated_assignment = any(has_non_empty_guard_for_assignment(load_body or "", m) for m in assignment_matches)
    assertion(
        "Wizard-state side-effect on prefill hit",
        bool(assignment_matches) and gated_assignment,
        "expected AzureKeyPage.SelectedValueIndex := 1 in LoadExistingEnvValues guarded by a non-empty resolved-key check",
        failures,
    )

    read_signature = "function ReadEnvValue(FilePath: String; Key: String): String;"
    read_unchanged = read_body is not None and read_signature in read_body
    for snippet in (
        "Line := Trim(Lines[I]);",
        "// Skip empty lines and comments",
        "if (Length(Line) = 0) or (Copy(Line, 1, 1) = '#') then",
        "EqualPos := Pos('=', Line);",
        "Result := Trim(Copy(Line, EqualPos + 1, Length(Line)));",
    ):
        read_unchanged = read_unchanged and read_body is not None and snippet in read_body
    assertion(
        "Existing ReadEnvValue is unchanged",
        read_unchanged,
        "expected original ReadEnvValue signature and coarse parser lines to remain present",
        failures,
    )

    init_text = init_body or ""
    generate_pos = init_text.find("AzureKeyPage.Add('Generate automatically (recommended)');")
    custom_pos = init_text.find("AzureKeyPage.Add('Enter custom key manually');")
    default_pos = init_text.find("AzureKeyPage.SelectedValueIndex := 0;")
    assertion(
        "Page-construction defaults preserved",
        generate_pos != -1 and custom_pos != -1 and default_pos != -1 and generate_pos < custom_pos < default_pos,
        "expected InitializeWizard to keep generate index 0, custom index 1, and default SelectedValueIndex := 0",
        failures,
    )

    skip_ok = bool(
        skip_body
        and re.search(
            r"if\s+PageID\s*=\s*AzureKeyInputPage\.ID\s+then\s+Result\s*:=\s*AzureKeyPage\.SelectedValueIndex\s*=\s*0\s*;",
            skip_body,
            re.I | re.S,
        )
    )
    assertion(
        "ShouldSkipPage rule unchanged",
        skip_ok,
        "expected AzureKeyInputPage to be skipped only when AzureKeyPage.SelectedValueIndex = 0",
        failures,
    )

    switches_ok = "-AzureKeyGenerate" in text and "-AzureKeyCustom" in text
    assertion(
        "GetPowerShellParams switches unchanged",
        switches_ok,
        "expected both -AzureKeyGenerate and -AzureKeyCustom strings to remain in setup.iss",
        failures,
    )

    diff_rc, diff_names, diff_err = run_git_diff_names()
    diff_ok = diff_rc == 0 and sorted(diff_names) == sorted(TEST_FILES)
    evidence = (
        f"git diff returned {diff_rc}: {diff_err}"
        if diff_rc != 0
        else f"expected {sorted(TEST_FILES)}, got {sorted(diff_names)}"
    )
    assertion(
        "No edits outside setup.iss",
        diff_ok,
        evidence,
        failures,
    )

    unconditional = [
        m
        for m in assignment_matches
        if not has_non_empty_guard_for_assignment(load_body or "", m)
    ]
    assertion(
        "Fresh-install no regression",
        not unconditional,
        "found AzureKeyPage.SelectedValueIndex := 1 in LoadExistingEnvValues without a nearby non-empty guard",
        failures,
    )

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
