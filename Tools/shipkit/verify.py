"""Read the answers back out of the built thing.

This repo has a rule, learned the expensive way: a build setting can be accepted
and then ignored. `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*]` resolved to the SDK
default while every report said 17.0. `INFOPLIST_KEY_UIBackgroundModes` appeared
in `-showBuildSettings` and never reached the generated plist. Neither failed to
compile. Neither warned.

So this module never asks a setting anything. It opens the artifact — the
archived app, or the app inside the exported .ipa — and reads its Info.plist,
its signature and its embedded provisioning profile.

Two comparisons carry most of the weight:

**Every key the source partial Info.plist declares must appear in the built
one.** That is the general form of the UIBackgroundModes bug, so it catches the
next one too rather than only the one already known.

**Every key the source entitlements file declares must survive into the
signature.** This is the gate on the unsigned-archive shortcut, which produces
a binary carrying no entitlements at all and exports without complaint —
silently shipping an app whose CloudKit container is simply absent.

One legitimate difference is expected and asserted rather than ignored:
`aps-environment` comes from the provisioning profile's allowlist, not from the
source file, and a distribution profile always says `production`. A source file
saying `development` is correct and must not be edited; the exported binary
saying `development` is a build that Apple will reject.
"""

from __future__ import annotations

import os
import shutil
from typing import Any, Dict, List, Optional, Tuple

from . import config, proc, xcode
from .report import FAIL, OK, SKIP, WARN, Result, Row, fail, ok, say


def resolve_app(path: str, workdir: str) -> Tuple[str, str]:
    """(path to a .app, what kind of artifact it came from).

    An .ipa is extracted with `ditto -x -k` rather than Python's zipfile:
    executable bits and symlinks have to survive or `codesign` reads the result
    as a broken bundle and the verification reports a problem it invented."""
    path = os.path.abspath(os.path.expanduser(path))
    if path.endswith(".app"):
        return path, "app"
    if path.endswith(".xcarchive"):
        return xcode.archive_app_path(path), "archive"
    if path.endswith(".ipa"):
        extracted = os.path.join(workdir, os.path.basename(path)[: -len(".ipa")] + "-unpacked")
        if os.path.isdir(extracted):
            shutil.rmtree(extracted)
        os.makedirs(extracted, exist_ok=True)
        result = proc.run(["ditto", "-x", "-k", path, extracted], timeout=600)
        if not result.ok:
            return "", "ipa"
        payload = os.path.join(extracted, "Payload")
        if os.path.isdir(payload):
            apps = [name for name in sorted(os.listdir(payload)) if name.endswith(".app")]
            if apps:
                return os.path.join(payload, apps[0]), "ipa"
        return "", "ipa"
    return "", "unknown"


def latest_artifact(cfg: config.Config) -> str:
    """The most recent thing this tool built, preferring the exported .ipa —
    that is the artifact that gets uploaded, and therefore the one worth
    checking."""
    candidates: List[str] = []
    for root, _, files in os.walk(cfg.build_dir):
        for name in files:
            if name.endswith(".ipa"):
                candidates.append(os.path.join(root, name))
    archive = os.path.join(cfg.build_dir, cfg.app_name + ".xcarchive")
    if candidates:
        return max(candidates, key=os.path.getmtime)
    return archive if os.path.isdir(archive) else ""


# ── checks ────────────────────────────────────────────────────────────────────

def _plist_of(app: str) -> Dict[str, Any]:
    return xcode.read_plist(os.path.join(app, "Info.plist"))


def check_identity(built: Dict[str, Any], settings: Dict[str, str]) -> Row:
    got = built.get("CFBundleIdentifier", "")
    want = settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")
    if want and got != want:
        return Row("identity", "Bundle identifier", FAIL, "%s (project says %s)" % (got, want),
                   "The artifact is not this project's app, or an override changed the "
                   "identifier. A bundle identifier cannot be changed after launch — it carries "
                   "the MusicKit capability, the entitlements and the listing.")
    return Row("identity", "Bundle identifier", OK, got or "absent")


def check_version(built: Dict[str, Any], settings: Dict[str, str],
                  expected_build: str = "") -> Row:
    short = built.get("CFBundleShortVersionString", "")
    build = built.get("CFBundleVersion", "")
    detail = "%s (%s)" % (build or "absent", short or "absent")
    if not build or not short:
        return Row("version", "Version numbers", FAIL, detail,
                   "Both are required. With GENERATE_INFOPLIST_FILE on they come from "
                   "CURRENT_PROJECT_VERSION and MARKETING_VERSION — and note that writing them "
                   "into a partial Info.plist does not work: the generator claims both keys and "
                   "silently overwrites whatever is there.")
    if expected_build and build != expected_build:
        return Row("version", "Version numbers", FAIL,
                   "%s, expected %s" % (detail, expected_build),
                   "The number that reached the binary is not the number this build asked for. "
                   "The usual cause is a conditional CURRENT_PROJECT_VERSION in the project "
                   "file taking precedence over the plain one.")
    return Row("version", "Version numbers", OK, detail)


def check_floor(built: Dict[str, Any], settings: Dict[str, str]) -> Row:
    got = str(built.get("MinimumOSVersion", ""))
    want = settings.get("IPHONEOS_DEPLOYMENT_TARGET", "")
    if want and got != want:
        return Row("floor", "Minimum OS in the binary", FAIL, "%s, project says %s" % (got, want),
                   "This is the failure that hides: a deployment target written in the "
                   "conditional form is accepted and then resolves to the SDK's own default. "
                   "The binary refuses to install on anything below the value above, and "
                   "nothing in the build output says so.")
    return Row("floor", "Minimum OS in the binary", OK, "iOS %s" % (got or "absent"))


def _stale_note(stale: bool) -> str:
    """A mismatch caused by an out-of-date artifact reads exactly like a
    mismatch caused by a broken build, and the remedy is completely different.
    Say which one it is whenever the timestamps can tell."""
    return ("\nThe source file has changed since this artifact was built, so it may simply be "
            "out of date — rebuild before reading anything into this." if stale else "")


def check_declared_keys(built: Dict[str, Any], source_plist: Dict[str, Any],
                        stale: bool = False) -> Row:
    """Every key the source partial Info.plist declares, present in the built one.

    The general form of a bug this project already hit: Xcode accepts
    `INFOPLIST_KEY_UIBackgroundModes` and drops it from the generated plist. A
    check for that one key would have caught it once; this catches the next one
    as well."""
    if not source_plist:
        return Row("declared", "Declared Info.plist keys", SKIP, "no partial Info.plist")
    missing = [key for key in source_plist if key not in built]
    differing = [key for key in source_plist
                 if key in built and built[key] != source_plist[key]]
    if missing:
        return Row("declared", "Declared Info.plist keys", FAIL,
                   "%d of %d missing" % (len(missing), len(source_plist)),
                   "Declared in the source Info.plist and absent from the built app: %s.\n"
                   "A key can be accepted and then dropped without any warning — that is why "
                   "this reads the artifact rather than the settings.%s"
                   % (", ".join(missing), _stale_note(stale)))
    if differing:
        return Row("declared", "Declared Info.plist keys", WARN,
                   "%d changed in the build" % len(differing),
                   "Present but different from the source: %s. Sometimes correct (the generator "
                   "merges), sometimes an override you did not intend."
                   % ", ".join(differing))
    return Row("declared", "Declared Info.plist keys", OK,
               "%d present" % len(source_plist))


def check_encryption(built: Dict[str, Any]) -> Row:
    if "ITSAppUsesNonExemptEncryption" in built:
        value = built["ITSAppUsesNonExemptEncryption"]
        return Row("encryption", "Export compliance", OK, "declared %s" % bool(value))
    return Row("encryption", "Export compliance", WARN, "not declared in the binary",
               "This build will land in TestFlight as 'Missing Compliance' — processed, and "
               "undistributable until someone answers the question by hand.\n"
               "  Tools/ship fix encryption")


def check_signature(app: str, entitlements: Dict[str, Any], kind: str) -> Row:
    if entitlements:
        return Row("signed", "Code signature", OK, "%d entitlements" % len(entitlements))
    signed = proc.run(["codesign", "-dv", app], timeout=120)
    if "not signed" in signed.out:
        status = SKIP if kind == "archive" else FAIL
        return Row("signed", "Code signature", status, "not signed",
                   "An unsigned archive is expected — export applies the only signature that "
                   "matters. An unsigned *export* is not: it cannot be installed or uploaded."
                   if kind == "archive" else
                   "The exported app carries no signature. It cannot be uploaded.")
    return Row("signed", "Code signature", WARN, "signed, no entitlements readable",
               "`codesign -d --entitlements` returned nothing. The bundle is signed but carries "
               "no entitlements at all — which is what an archive built with "
               "CODE_SIGNING_ALLOWED=NO produces, and what silently drops iCloud.")


def check_entitlements(entitlements: Dict[str, Any], source: Dict[str, Any], kind: str) -> Row:
    """Every entitlement the source file asks for, surviving into the signature.

    This is the hard gate on the unsigned-archive shortcut. Skipping signing at
    archive time means no `.xcent` is produced, so the entitlements file never
    enters the archive in any form — and export's entitlement processors are
    *transformers*, not providers. They cannot invent a container identifier
    from nothing, so the export succeeds and the app simply has no CloudKit."""
    if not source:
        return Row("entitlements", "Entitlements survived", SKIP, "no source entitlements file")
    if not entitlements:
        status = SKIP if kind == "archive" else FAIL
        return Row("entitlements", "Entitlements survived", status,
                   "none in the artifact",
                   "Nothing to compare yet — the archive is unsigned and export applies the "
                   "signature." if kind == "archive" else
                   "The source file declares %d entitlements and the signed app has none. An "
                   "app store build with no entitlements has no CloudKit container and no push; "
                   "it will install and then fail at runtime in ways no log explains."
                   % len(source))
    # aps-environment is excluded on purpose: its value comes from the profile's
    # allowlist, never from the source file, and check_push asserts it properly.
    missing = [key for key in source if key not in entitlements and key != "aps-environment"]
    if missing:
        return Row("entitlements", "Entitlements survived", FAIL,
                   "%d of %d missing" % (len(missing), len(source)),
                   "Declared in the source entitlements and absent from the signature: %s.\n"
                   "The provisioning profile is a superset and proves nothing here — only the "
                   "signature does." % ", ".join(missing))
    changed = [key for key in source
               if key != "aps-environment" and entitlements.get(key) != source[key]]
    if changed:
        return Row("entitlements", "Entitlements survived", WARN,
                   "%d rewritten during signing" % len(changed),
                   "Present with a different value: %s. Some of this is normal — the App Store "
                   "profile adds beta-reports-active and clears get-task-allow — but a changed "
                   "iCloud container identifier is not." % ", ".join(changed))
    return Row("entitlements", "Entitlements survived", OK, "%d present" % len(source))


def check_push(entitlements: Dict[str, Any], source: Dict[str, Any], kind: str) -> Row:
    """`aps-environment` must end up `production` on a store build.

    The source file says `development` and that is correct — it is what makes
    local development work, and Xcode replaces it from the distribution
    profile's allowlist at signing time. Editing the source file to say
    `production` is the classic wrong fix. What matters is the value in the
    exported binary, which is what this reads."""
    if "aps-environment" not in source:
        return Row("push", "Push environment", SKIP, "app does not use push")
    if not entitlements:
        return Row("push", "Push environment", SKIP,
                   "unsigned artifact" if kind == "archive" else "no entitlements to read")
    value = entitlements.get("aps-environment", "")
    if value == "production":
        return Row("push", "Push environment", OK, "production")
    if not value:
        return Row("push", "Push environment", FAIL, "absent",
                   "The source entitlements ask for push and the signed app has no "
                   "aps-environment. The profile does not carry the capability — enable Push "
                   "Notifications on the App ID and let signing regenerate the profile.")
    if kind == "archive":
        return Row("push", "Push environment", SKIP, "%s (archive, pre-export)" % value,
                   "An archive is signed for development. The value that matters is the one in "
                   "the exported build.")
    return Row("push", "Push environment", FAIL, value,
               "An App Store build must carry `production`. Apple rejects the upload otherwise "
               "(ITMS-90164). Do NOT fix this by editing the entitlements file — that breaks "
               "development builds. It means the export signed with a development profile: "
               "check that exportOptions says method app-store-connect.")


def check_profile(app: str, kind: str) -> Row:
    profile = xcode.embedded_profile(app)
    if not profile:
        status = SKIP if kind == "archive" else WARN
        return Row("profile", "Provisioning profile", status, "none embedded",
                   "Expected before export." if kind == "archive"
                   else "An exported app should carry one.")
    name = profile.get("Name", "")
    devices = profile.get("ProvisionedDevices")
    expires = str(profile.get("ExpirationDate", ""))[:10]
    if devices is not None:
        return Row("profile", "Provisioning profile", FAIL if kind != "archive" else SKIP,
                   "%s · %d devices" % (name, len(devices)),
                   "A profile with a device list is a development or ad-hoc profile. An App "
                   "Store distribution profile has no device list at all — which is also why "
                   "it can be minted for a team with nothing registered.")
    return Row("profile", "Provisioning profile", OK, "%s · expires %s" % (name, expires))


# ── entry point ───────────────────────────────────────────────────────────────

def rows_for(cfg: config.Config, app: str, kind: str, settings: Dict[str, str],
             expected_build: str = "") -> List[Row]:
    built = _plist_of(app)
    entitlements = xcode.app_entitlements(app)
    source_plist: Dict[str, Any] = {}
    source_entitlements: Dict[str, Any] = {}
    stale = False
    binary = os.path.join(app, "Info.plist")
    name = settings.get("INFOPLIST_FILE", "")
    if name:
        path = os.path.join(cfg.project_dir, name)
        source_plist = xcode.read_plist(path)
        if os.path.exists(path) and os.path.exists(binary):
            stale = os.path.getmtime(path) > os.path.getmtime(binary)
    name = settings.get("CODE_SIGN_ENTITLEMENTS", "")
    if name:
        source_entitlements = xcode.read_plist(os.path.join(cfg.project_dir, name))
    return [
        check_identity(built, settings),
        check_version(built, settings, expected_build),
        check_floor(built, settings),
        check_declared_keys(built, source_plist, stale),
        check_encryption(built),
        check_signature(app, entitlements, kind),
        check_entitlements(entitlements, source_entitlements, kind),
        check_push(entitlements, source_entitlements, kind),
        check_profile(app, kind),
    ]


def run(cfg: config.Config, path: Optional[str] = None, settings: Optional[Dict[str, str]] = None,
        expected_build: str = "", quiet: bool = False) -> Result:
    target = path or latest_artifact(cfg)
    if not target:
        return fail("Nothing to verify",
                    "No .ipa or .xcarchive under %s. Pass a path, or run `Tools/ship build` "
                    "first." % cfg.build_dir)
    if not os.path.exists(target):
        return fail("No such artifact: %s" % target)
    app, kind = resolve_app(target, os.path.join(cfg.build_dir, "verify"))
    if not app or not os.path.isdir(app):
        return fail("Could not find an app inside %s" % target,
                    "Expected a .app, a .ipa containing Payload/<name>.app, or an .xcarchive.")
    if settings is None:
        settings = xcode.build_settings(cfg.xcodeproj, cfg.scheme, cfg.configuration)
    rows = rows_for(cfg, app, kind, settings, expected_build)
    if not quiet:
        say("")
        say("  %s" % target)
        for row in rows:
            say(row.render())
    failures = [row for row in rows if row.status == FAIL]
    warnings = [row for row in rows if row.status == WARN]
    data = {"artifact": target, "app": app, "kind": kind,
            "rows": [row.as_dict() for row in rows]}
    if failures:
        return fail("%d check%s failed against the artifact"
                    % (len(failures), "" if len(failures) == 1 else "s"),
                    "\n".join("%s — %s" % (row.label, row.detail) for row in failures),
                    data=data)
    if warnings:
        return ok("The artifact matches, with %d warning%s"
                  % (len(warnings), "" if len(warnings) == 1 else "s"), data=data)
    return ok("The artifact matches what the project declares", data=data)
