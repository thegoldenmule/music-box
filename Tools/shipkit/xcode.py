"""Reading the local Apple toolchain, and reading built artifacts back.

Two halves, and the split matters.

The first half asks `xcodebuild`, `security` and `defaults` what is installed
and configured. That is the *settings* view, and this repo has already been
bitten twice by trusting it: `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*]` resolved
to the SDK default while every report said 17.0, and
`INFOPLIST_KEY_UIBackgroundModes` appeared in `-showBuildSettings` and never
reached the generated plist.

So the second half reads values back out of the *artifact* — the archived app's
Info.plist, its signed entitlements, its embedded provisioning profile. That is
the only view that cannot lie, and it is why `ship verify` exists as a pipeline
stage rather than an afterthought.

One landmine, recorded because it cost a detour once: never
`plutil -extract KEY raw FILE`. Without `-o -` it rewrites the file in place, so
reading a key destroys the thing being read. Everything here uses
`plutil -convert json -o -`, which writes to stdout and leaves the file alone.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
from typing import Any, Dict, List, Optional, Tuple

from . import proc


# ── the toolchain ─────────────────────────────────────────────────────────────

def xcodebuild_version() -> Tuple[bool, str]:
    result = proc.run(["xcodebuild", "-version"], timeout=60)
    if not result.ok:
        return False, result.out.strip()
    return True, " ".join(result.out.strip().split("\n")[:2])


def developer_dir() -> str:
    result = proc.run(["xcode-select", "-p"], timeout=30)
    return result.out.strip() if result.ok else ""


def first_json(text: str, opener: str = "[") -> Any:
    """The first complete JSON value in `text`, ignoring anything after it.

    `xcodebuild -json` is not a JSON-only stream: it prefixes resolution chatter
    and, when a scheme matches several destinations, appends a warning listing
    every simulator on the machine. `json.loads` on the whole thing fails with
    "Extra data" — which reads exactly like "the command failed" and is not."""
    start = text.find(opener)
    if start < 0:
        return None
    try:
        value, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError:
        return None
    return value


def build_settings(xcodeproj: str, scheme: str, configuration: str = "Release",
                   sdk: str = "iphoneos") -> Dict[str, str]:
    """Resolved build settings for one scheme/sdk/configuration.

    `-showBuildSettings` resolves a package graph first, so this is seconds not
    milliseconds — callers should fetch once and pass the dict around."""
    result = proc.run([
        "xcodebuild", "-showBuildSettings", "-json",
        "-project", xcodeproj, "-scheme", scheme,
        "-configuration", configuration, "-sdk", sdk,
    ], timeout=600)
    payload = first_json(result.stdout, "[")
    if not isinstance(payload, list):
        return {}
    for entry in payload:
        settings = entry.get("buildSettings")
        if isinstance(settings, dict):
            return {str(k): str(v) for k, v in settings.items()}
    return {}


def schemes(xcodeproj: str) -> List[str]:
    result = proc.run(["xcodebuild", "-list", "-json", "-project", xcodeproj], timeout=600)
    payload = first_json(result.stdout, "{")
    if not isinstance(payload, dict):
        return []
    return list(payload.get("project", {}).get("schemes", []))


def signing_identities() -> List[str]:
    """Code-signing identities in the keychain, as their display names."""
    result = proc.run(["security", "find-identity", "-v", "-p", "codesigning"], timeout=60)
    return re.findall(r'"([^"]+)"', result.out)


def has_distribution_identity() -> bool:
    return any("Apple Distribution" in name or "iPhone Distribution" in name
               for name in signing_identities())


def xcode_teams() -> List[Dict[str, str]]:
    """Teams signed into Xcode, in Xcode's own order: [{id, name}, …].

    The defaults blocks list teamID before teamName, so a name attaches to the
    most recently seen id."""
    result = proc.run(
        ["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeamByIdentifier"],
        timeout=60)
    return parse_team_entries(result.out)


def parse_team_entries(defaults_output: str) -> List[Dict[str, str]]:
    entries: List[Dict[str, str]] = []
    seen = set()
    for raw in defaults_output.split("\n"):
        line = raw.strip()
        if line.startswith("teamID"):
            value = _plist_scalar(line)
            if value and value not in seen:
                seen.add(value)
                entries.append({"id": value, "name": ""})
        elif line.startswith("teamName") and entries and not entries[-1]["name"]:
            entries[-1]["name"] = _plist_scalar(line)
    return entries


def _plist_scalar(line: str) -> str:
    value = line.split("=", 1)[-1].strip().rstrip(";").strip()
    return value.strip('"')


def paired_devices() -> int:
    result = proc.run(["xcrun", "devicectl", "list", "devices"], timeout=120)
    if not result.ok:
        return -1
    return sum(1 for line in result.out.split("\n") if "available" in line)


# ── reading artifacts ─────────────────────────────────────────────────────────

def read_plist(path: str) -> Dict[str, Any]:
    """A plist of any format, as a dict. Binary and XML both work because
    `plutil -convert json -o -` normalises them — and `-o -` is what keeps this
    a read rather than a rewrite."""
    if not os.path.exists(path):
        return {}
    result = proc.run(["plutil", "-convert", "json", "-o", "-", path], timeout=60)
    if not result.ok:
        return {}
    payload = first_json(result.stdout, "{")
    return payload if isinstance(payload, dict) else {}


def app_entitlements(app_path: str) -> Dict[str, Any]:
    """Entitlements actually baked into a signed bundle.

    Not the .entitlements source file — the signature. For an App Store export
    these can legitimately differ from the source (Xcode substitutes
    `aps-environment: production`), and the difference is exactly what a
    verification step exists to observe."""
    code, out = proc.run_bytes(
        ["codesign", "-d", "--entitlements", ":-", "--xml", app_path], timeout=120)
    if code != 0 or not out:
        # Older codesign spellings emit a length-prefixed blob rather than XML.
        code, out = proc.run_bytes(["codesign", "-d", "--entitlements", ":-", app_path],
                                   timeout=120)
    if not out:
        return {}
    start = out.find(b"<?xml")
    if start < 0:
        start = out.find(b"bplist00")
    if start > 0:
        out = out[start:]
    try:
        parsed = plistlib.loads(out)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def embedded_profile(app_path: str) -> Dict[str, Any]:
    """The provisioning profile inside a signed .app, decoded from its CMS
    wrapper. Empty when the bundle is unsigned — which is not an error, just an
    archive that has not been through export yet."""
    path = os.path.join(app_path, "embedded.mobileprovision")
    if not os.path.exists(path):
        return {}
    code, out = proc.run_bytes(["security", "cms", "-D", "-i", path], timeout=60)
    if code != 0 or not out:
        return {}
    try:
        parsed = plistlib.loads(out)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def archive_app_path(archive: str) -> str:
    """The .app inside an .xcarchive. Named from the archive's own metadata
    rather than guessed from the scheme, because the product name and the
    scheme name are allowed to differ."""
    products = os.path.join(archive, "Products", "Applications")
    if not os.path.isdir(products):
        return ""
    apps = [name for name in sorted(os.listdir(products)) if name.endswith(".app")]
    return os.path.join(products, apps[0]) if apps else ""


# ── the build number ──────────────────────────────────────────────────────────

BUILD_NUMBER_RE = re.compile(r"^(\s*CURRENT_PROJECT_VERSION\s*=\s*)([^;]+)(;.*)$", re.M)


def read_build_numbers(pbxproj: str) -> List[str]:
    with open(pbxproj, encoding="utf-8") as handle:
        return [match.group(2).strip() for match in BUILD_NUMBER_RE.finditer(handle.read())]


def bump_build_number_text(text: str, value: str) -> Tuple[str, int]:
    """Set every `CURRENT_PROJECT_VERSION` to `value`; return (text, count).

    Every configuration is set to the same number on purpose. They are two
    spellings of one fact, and a Debug build whose number trails Release is a
    trap for anyone comparing a crash report against a TestFlight build. Pure,
    so the test can assert the count without a project on disk."""
    replaced = BUILD_NUMBER_RE.sub(lambda m: m.group(1) + value + m.group(3), text)
    return replaced, len(BUILD_NUMBER_RE.findall(text))


def write_build_number(pbxproj: str, value: str) -> int:
    with open(pbxproj, encoding="utf-8") as handle:
        text = handle.read()
    updated, count = bump_build_number_text(text, value)
    if count:
        with open(pbxproj, "w", encoding="utf-8") as handle:
            handle.write(updated)
    return count


CONDITIONAL_SETTING_RE = re.compile(r"^\s*([A-Z_0-9]+)\[[^\]]+\]\s*=", re.M)


def conditional_settings(pbxproj: str) -> List[str]:
    """Build settings written in the `SETTING[sdk=…]` conditional form.

    This repo has a scar here: `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*] = 17.0`
    was accepted, silently resolved to the SDK's own default, and would have
    shipped a binary that refused to install on anything below iOS 26. Nothing
    warned. Listing the conditional forms lets the checklist point at them
    before an upload rather than after."""
    with open(pbxproj, encoding="utf-8") as handle:
        return sorted(set(CONDITIONAL_SETTING_RE.findall(handle.read())))


def next_build_number(current: str) -> str:
    """`7` → `8`; `1.2.3` → `1.2.4`. Apple accepts both shapes but requires the
    value to rise, so bump the last numeric component and leave the rest."""
    parts = current.strip().split(".")
    try:
        parts[-1] = str(int(parts[-1]) + 1)
    except ValueError:
        return "1"
    return ".".join(parts)


def build_number_sort_key(value: str) -> Tuple[int, ...]:
    """Comparable form of a CFBundleVersion, for finding the highest one Apple
    already holds. Non-numeric components sort as 0 rather than raising — a
    weird build number should not stop a release."""
    out: List[int] = []
    for part in str(value).split("."):
        try:
            out.append(int(part))
        except ValueError:
            out.append(0)
    return tuple(out)
