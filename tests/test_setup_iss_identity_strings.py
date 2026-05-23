#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "setup.iss"

IDENTITY_DEFINES = {
    "RfqAppName": ("RFQ_APP_NAME", "RFQ Application"),
    "RfqOutputBaseFilename": ("RFQ_OUTPUT_BASE_FILENAME", "RFQ_Application_Setup"),
    "RfqDefaultDirName": ("RFQ_DEFAULT_DIR_NAME", r"{autopf}\RFQ Application"),
    "RfqDefaultGroupName": ("RFQ_DEFAULT_GROUP_NAME", "RFQ Application"),
    "RfqRegistryHandoffKey": ("RFQ_REGISTRY_HANDOFF_KEY", r"Software\RFQApplication\Installer"),
    "RfqStartMenuShortcutName": ("RFQ_START_MENU_SHORTCUT_NAME", r"{group}\RFQ Application"),
    "RfqUninstallShortcutName": (
        "RFQ_UNINSTALL_SHORTCUT_NAME",
        r"{group}\{cm:UninstallProgram,RFQ Application}",
    ),
    "RfqDesktopShortcutName": ("RFQ_DESKTOP_SHORTCUT_NAME", r"{autodesktop}\RFQ Application"),
    "RfqQuickLaunchShortcutName": (
        "RFQ_QUICK_LAUNCH_SHORTCUT_NAME",
        r"{userappdata}\Microsoft\Internet Explorer\Quick Launch\RFQ Application",
    ),
}

CUSTOM_VALUES = {
    "RFQ_APP_NAME": "RFQ Application e2e A",
    "RFQ_OUTPUT_BASE_FILENAME": "RFQ_Application_Setup_e2e_A",
    "RFQ_DEFAULT_DIR_NAME": r"C:\Program Files\RFQ Application e2e A",
    "RFQ_DEFAULT_GROUP_NAME": "RFQ Application e2e A",
    "RFQ_REGISTRY_HANDOFF_KEY": r"Software\RFQApplication-e2e-A\Installer",
    "RFQ_START_MENU_SHORTCUT_NAME": r"{group}\RFQ Application e2e A",
    "RFQ_UNINSTALL_SHORTCUT_NAME": r"{group}\Uninstall RFQ Application e2e A",
    "RFQ_DESKTOP_SHORTCUT_NAME": r"{autodesktop}\RFQ Application e2e A",
    "RFQ_QUICK_LAUNCH_SHORTCUT_NAME": (
        r"{userappdata}\Microsoft\Internet Explorer\Quick Launch\RFQ Application e2e A"
    ),
}


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


def assert_getenv_define(text: str, macro: str, env_name: str, fallback: str) -> None:
    escaped_fallback = re.escape(fallback)
    pattern = (
        rf'(?ms)^#define\s+{macro}\s+GetEnv\("{env_name}"\)\s*'
        rf'^#if\s+{macro}\s*==\s*""\s*'
        rf'^\s*#define\s+{macro}\s+"{escaped_fallback}"\s*'
        rf'^#endif\s*$'
    )
    assert re.search(pattern, text), (
        f"{macro} must read {env_name} with fallback {fallback!r}"
    )


def resolve_macro(macro: str, env: dict[str, str]) -> str:
    env_name, fallback = IDENTITY_DEFINES[macro]
    value = env.get(env_name, "")
    return value if value else fallback


def test_identity_defines_read_specific_full_value_env_vars_with_defaults() -> None:
    text = SETUP.read_text(encoding="utf-8")

    for macro, (env_name, fallback) in IDENTITY_DEFINES.items():
        assert_getenv_define(text, macro, env_name, fallback)


def test_identity_values_resolve_to_defaults_when_env_vars_are_unset() -> None:
    for macro, (_, fallback) in IDENTITY_DEFINES.items():
        assert resolve_macro(macro, {}) == fallback


def test_identity_values_resolve_to_their_own_env_var_when_set() -> None:
    for macro, (env_name, _) in IDENTITY_DEFINES.items():
        env = {env_name: CUSTOM_VALUES[env_name]}
        assert resolve_macro(macro, env) == CUSTOM_VALUES[env_name]


def test_setup_identity_directives_use_preprocessor_macros() -> None:
    text = SETUP.read_text(encoding="utf-8")
    setup = setup_directives(section(text, "Setup"))

    assert setup["AppVersion"] == "{#MyAppVersion}"
    assert setup["AppName"] == "{#RfqAppName}"
    assert setup["OutputBaseFilename"] == "{#RfqOutputBaseFilename}"
    assert setup["DefaultDirName"] == "{#RfqDefaultDirName}"
    assert setup["DefaultGroupName"] == "{#RfqDefaultGroupName}"


def test_setup_keeps_the_selected_patch_version_bump() -> None:
    text = SETUP.read_text(encoding="utf-8")

    assert re.search(r'(?m)^#define\s+MyAppVersion\s+"1\.0\.1"\s*$', text)


def test_shortcut_names_each_use_their_own_full_value_env_macro() -> None:
    text = SETUP.read_text(encoding="utf-8")
    names = icon_name_fields(section(text, "Icons"))

    assert names == [
        "{#RfqStartMenuShortcutName}",
        "{#RfqUninstallShortcutName}",
        "{#RfqDesktopShortcutName}",
        "{#RfqQuickLaunchShortcutName}",
    ]
