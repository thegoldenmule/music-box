"""The checklist: every link in the chain, and how to repair each broken one.

A release fails in one of about fifteen places, and roughly half of them are
knowable before anything is built. Finding out at minute twenty of an archive
that the app record does not exist is the failure this command is here to
delete.

Two rules shape it.

**A row that cannot be fixed by this tool must not offer a fix.** `manual=True`
says a human has to go somewhere; conflating that with a repairable row is how a
checklist starts lying to the person reading it.

**Settings are not evidence.** Rows that check the project read the *project
file*, not `-showBuildSettings`, wherever the two can disagree — this repo has
been bitten by a setting that resolved to something other than what it said.
Rows that check a build artifact live in `verify` and read the artifact.
"""

from __future__ import annotations

import dataclasses
import os
import re
from typing import Any, Dict, List, Optional

from . import asc, config, proc, xcode
from .report import (FAIL, OK, SKIP, WARN, Link, Result, Row, blocked, fail, ok, say, usage)

XCODE_LINK = Link("Xcode on the App Store", "https://apps.apple.com/app/xcode/id497799835")
KEY_LINK = Link("Create API key", "https://appstoreconnect.apple.com/access/integrations/api")
APPS_LINK = Link("Open My Apps", "https://appstoreconnect.apple.com/apps")
IDENTIFIERS_LINK = Link("Open Identifiers",
                        "https://developer.apple.com/account/resources/identifiers/list")


@dataclasses.dataclass
class Facts:
    """Everything the rows are computed from, gathered once.

    Assembling this costs an `-showBuildSettings` (seconds) and up to four API
    calls, so it happens once and every check reads from it. A checklist whose
    rows each shell out independently takes a minute and tells you nothing more.
    """

    cfg: config.Config
    settings: Dict[str, str] = dataclasses.field(default_factory=dict)
    info_plist: Dict[str, Any] = dataclasses.field(default_factory=dict)
    entitlements: Dict[str, Any] = dataclasses.field(default_factory=dict)
    client: Optional[asc.Client] = None
    asc_error: str = ""
    asc_team: str = ""
    # Why the App Store Connect probes did not run. Empty means they did.
    # Without this, a wrong-team key makes `gather` bail after validation and
    # every row below reads its own empty result as an answer — reporting the
    # app record as *missing* when it was never asked about. That is precisely
    # the false confidence the wrong-team check exists to prevent, arriving by
    # a different door.
    asc_blocked: str = ""
    bundle_record: Dict[str, Any] = dataclasses.field(default_factory=dict)
    app: Dict[str, Any] = dataclasses.field(default_factory=dict)
    groups: List[Dict[str, Any]] = dataclasses.field(default_factory=list)
    offline: bool = False

    @property
    def bundle_id(self) -> str:
        return self.settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")

    @property
    def team_id(self) -> str:
        return self.settings.get("DEVELOPMENT_TEAM", "")

    @property
    def build_number(self) -> str:
        return self.settings.get("CURRENT_PROJECT_VERSION", "")

    @property
    def marketing_version(self) -> str:
        return self.settings.get("MARKETING_VERSION", "")

    @property
    def pbxproj(self) -> str:
        return os.path.join(self.cfg.xcodeproj, "project.pbxproj")

    @property
    def info_plist_path(self) -> str:
        name = self.settings.get("INFOPLIST_FILE", "")
        return os.path.join(self.cfg.project_dir, name) if name else ""

    @property
    def entitlements_path(self) -> str:
        name = self.settings.get("CODE_SIGN_ENTITLEMENTS", "")
        return os.path.join(self.cfg.project_dir, name) if name else ""


def gather(cfg: config.Config, offline: bool = False) -> Facts:
    facts = Facts(cfg=cfg, offline=offline)
    facts.settings = xcode.build_settings(cfg.xcodeproj, cfg.scheme, cfg.configuration)
    if facts.info_plist_path:
        facts.info_plist = xcode.read_plist(facts.info_plist_path)
    if facts.entitlements_path:
        facts.entitlements = xcode.read_plist(facts.entitlements_path)
    if offline:
        facts.asc_blocked = "not checked (--offline)"
        return facts
    client = asc.client_for(cfg)
    if client is None:
        facts.asc_blocked = "needs an API key"
        return facts
    facts.client = client
    try:
        # Order matters: validate the key's team first. A key issued for the
        # wrong team answers every subsequent question truthfully about the
        # wrong team, so nothing it says may be shown until this passes.
        facts.asc_team = client.team_id()
        if facts.team_id and facts.asc_team and facts.asc_team != facts.team_id:
            facts.asc_blocked = "blocked — the API key belongs to team %s" % facts.asc_team
            return facts
        if not facts.bundle_id:
            facts.asc_blocked = "no bundle identifier to ask about"
            return facts
        facts.bundle_record = client.bundle_id_record(facts.bundle_id)
        facts.app = client.live_app(facts.bundle_id)
        if facts.app:
            facts.groups = client.beta_groups(facts.app["id"])
    except asc.ASCError as error:
        facts.asc_error = str(error)
        facts.asc_blocked = "App Store Connect unreachable"
    return facts


# ── checks ────────────────────────────────────────────────────────────────────

def check_xcode(facts: Facts) -> Row:
    present, version = xcode.xcodebuild_version()
    if not present:
        return Row("xcode", "Xcode", FAIL, "",
                   "Install Xcode, then point the command line tools at it:\n"
                   "  sudo xcode-select -s /Applications/Xcode.app",
                   [XCODE_LINK], manual=True)
    return Row("xcode", "Xcode", OK, "%s · %s" % (version.split("\n")[0], xcode.developer_dir()))


def check_project(facts: Facts) -> Row:
    if not facts.settings:
        return Row("project", "Project and scheme", FAIL, facts.cfg.scheme,
                   "xcodebuild could not resolve scheme '%s' in %s.\nAvailable: %s"
                   % (facts.cfg.scheme, facts.cfg.xcodeproj,
                      ", ".join(xcode.schemes(facts.cfg.xcodeproj)) or "none"),
                   manual=True)
    problems = []
    if not facts.bundle_id:
        problems.append("no bundle identifier")
    if not facts.team_id:
        problems.append("no DEVELOPMENT_TEAM")
    detail = "%s → %s (%s %s)" % (facts.cfg.scheme, facts.bundle_id,
                                  facts.marketing_version, facts.build_number)
    if problems:
        return Row("project", "Project and scheme", FAIL, detail,
                   "Set it in Xcode: target → Signing & Capabilities. Missing: %s."
                   % ", ".join(problems), manual=True)
    return Row("project", "Project and scheme", OK, detail)


DEPLOYMENT_LINE = re.compile(r"^\s*(IPHONEOS_DEPLOYMENT_TARGET(?:\[[^\]]*\])?)\s*=\s*([^;]+);", re.M)


def check_floor(facts: Facts) -> Row:
    """The deployment target, checked against the project file rather than the
    resolved settings.

    `IPHONEOS_DEPLOYMENT_TARGET[sdk=iphone*] = 17.0` is accepted by Xcode and
    then silently resolves to the SDK's own default. Nothing warns, nothing
    fails to compile, and the result is a binary that refuses to install on
    every device below the current SDK — discovered, if at all, by a tester who
    cannot install the build. Comparing what the project *says* against what
    xcodebuild *resolved* is the only way to see it."""
    if not os.path.exists(facts.pbxproj):
        return Row("floor", "Deployment target", SKIP, "no project.pbxproj")
    with open(facts.pbxproj, encoding="utf-8") as handle:
        declared = DEPLOYMENT_LINE.findall(handle.read())
    resolved = facts.settings.get("IPHONEOS_DEPLOYMENT_TARGET", "")
    conditional = [name for name, _ in declared if "[" in name]
    values = sorted({value.strip() for _, value in declared})
    if conditional:
        return Row("floor", "Deployment target", FAIL,
                   "resolved %s, declared %s" % (resolved or "?", ", ".join(values)),
                   "IPHONEOS_DEPLOYMENT_TARGET is written in the conditional %s form. Xcode "
                   "accepts that and then resolves it to the SDK default — the declared value "
                   "never takes effect, and the shipped binary refuses to install below the "
                   "current SDK.\nSet it unconditionally in Xcode (target → General → Minimum "
                   "Deployments) and check this row again." % conditional[0], manual=True)
    if values and resolved and resolved not in values:
        return Row("floor", "Deployment target", FAIL, "resolved %s, project says %s"
                   % (resolved, ", ".join(values)),
                   "The project file and the resolved build setting disagree. Something is "
                   "overriding it — an xcconfig, or a target-level setting shadowing the "
                   "project-level one. The resolved value is what ships.", manual=True)
    return Row("floor", "Deployment target", OK, "iOS %s" % (resolved or ", ".join(values)))


# Keys this app's own spec makes invariants. Background audio is the one with
# history: INFOPLIST_KEY_UIBackgroundModes is accepted as a build setting and
# never reaches the generated plist, which is why a partial Info.plist file
# exists at all.
REQUIRED_PLIST: List[Any] = [
    ("UIBackgroundModes", ["audio"], "background audio — the player stops at lock without it"),
    ("UIBackgroundModes", ["remote-notification"],
     "where a parent's change arrives; without it a deny waits for the next launch"),
]


def check_info_plist(facts: Facts) -> Row:
    path = facts.info_plist_path
    if not path or not os.path.exists(path):
        return Row("plist", "Info.plist keys", WARN, path or "no INFOPLIST_FILE",
                   "This target generates its whole Info.plist from build settings. That is fine "
                   "until a key Xcode silently drops is needed (UIBackgroundModes is one), at "
                   "which point a partial Info.plist file is the only way to set it.")
    missing = []
    for key, wanted, why in REQUIRED_PLIST:
        have = facts.info_plist.get(key) or []
        for value in wanted:
            if value not in have:
                missing.append("%s → %s (%s)" % (key, value, why))
    if missing:
        return Row("plist", "Info.plist keys", FAIL, os.path.basename(path),
                   "Missing from %s:\n  %s" % (path, "\n  ".join(missing)), manual=True)
    return Row("plist", "Info.plist keys", OK,
               "%s · %s" % (os.path.basename(path),
                            ", ".join(facts.info_plist.get("UIBackgroundModes") or [])))


ENCRYPTION_KEY = "ITSAppUsesNonExemptEncryption"


def check_encryption(facts: Facts) -> Row:
    """Export compliance, answered in advance.

    Without this key every upload lands in TestFlight as *Missing Compliance*
    and sits there — not failed, not testable, just waiting for someone to
    answer a yes/no in the console. Declaring it in the Info.plist answers it
    once, for every build."""
    if ENCRYPTION_KEY in facts.info_plist:
        value = facts.info_plist[ENCRYPTION_KEY]
        return Row("encryption", "Export compliance", OK,
                   "%s = %s" % (ENCRYPTION_KEY, "true" if value else "false"))
    if not facts.info_plist_path:
        return Row("encryption", "Export compliance", WARN, "no Info.plist file to declare it in",
                   "Every uploaded build will sit in TestFlight as 'Missing Compliance' until "
                   "someone answers the encryption question by hand.")
    return Row("encryption", "Export compliance", WARN, "not declared",
               "Every build will land in TestFlight as 'Missing Compliance' and be untestable "
               "until someone answers the question in the console — per build, forever.\n"
               "This app uses only HTTPS, which is exempt, so the answer is 'false'.",
               fix="encryption")


def check_entitlements(facts: Facts) -> Row:
    path = facts.entitlements_path
    if not path or not os.path.exists(path):
        return Row("entitlements", "Entitlements", SKIP, "none for this configuration")
    keys = sorted(facts.entitlements.keys())
    aps = facts.entitlements.get("aps-environment", "")
    detail = "%s · %d keys" % (os.path.basename(path), len(keys))
    if aps == "development":
        # Not a defect: Xcode substitutes `production` when signing with an App
        # Store distribution profile. It is called out because if the
        # substitution does NOT happen the upload is rejected, and `ship verify`
        # is what proves which of those two worlds you are in.
        return Row("entitlements", "Entitlements", WARN, detail + " · aps-environment development",
                   "The source file says `development`. An App Store export is expected to "
                   "substitute `production` when it signs — `Tools/ship verify` reads the "
                   "signature back and says which actually happened. If it stays `development`, "
                   "Apple rejects the upload.")
    return Row("entitlements", "Entitlements", OK, detail)


def check_working_tree(facts: Facts) -> Row:
    result = proc.run(["git", "status", "--porcelain"], cwd=facts.cfg.root, timeout=60)
    if not result.ok:
        return Row("git", "Working tree", SKIP, "not a git checkout")
    dirty = [line for line in result.stdout.split("\n") if line.strip()]
    head = proc.run(["git", "rev-parse", "--short", "HEAD"], cwd=facts.cfg.root, timeout=30)
    commit = head.stdout.strip() if head.ok else "?"
    if dirty:
        return Row("git", "Working tree", WARN, "%s + %d uncommitted change%s"
                   % (commit, len(dirty), "" if len(dirty) == 1 else "s"),
                   "A build uploaded from a dirty tree cannot be reproduced later — the commit "
                   "in the crash report will not be the code that crashed. Commit first, or pass "
                   "--allow-dirty if you mean it.")
    return Row("git", "Working tree", OK, "clean at %s" % commit)


def check_signing(facts: Facts) -> Row:
    identities = xcode.signing_identities()
    distribution = [name for name in identities
                    if "Apple Distribution" in name or "iPhone Distribution" in name]
    if distribution:
        return Row("signing", "Distribution certificate", OK, distribution[0])
    return Row("signing", "Distribution certificate", WARN,
               "%d codesigning identit%s, none for distribution"
               % (len(identities), "y" if len(identities) == 1 else "ies"),
               "Export can still mint one through cloud signing (an Xcode session, or an "
               "App Manager API key). If it cannot:\n"
               "1. Xcode → Settings → Accounts → your team\n"
               "2. Manage Certificates… → ＋ → Apple Distribution")


def check_team(facts: Facts) -> Row:
    teams = xcode.xcode_teams()
    ids = [entry["id"] for entry in teams]
    if facts.team_id and facts.team_id in ids:
        name = next((e["name"] for e in teams if e["id"] == facts.team_id), "")
        return Row("team", "Xcode account", OK, "%s (%s)" % (name or facts.team_id, facts.team_id))
    if not teams:
        status = WARN if facts.cfg.has_asc_key() else FAIL
        return Row("team", "Xcode account", status, "no signed-in teams",
                   "Sign into Xcode (Settings → Accounts → ＋). Not needed once an App Store "
                   "Connect API key is configured — cloud signing then works with no session.",
                   [Link("Apple Developer account", "https://developer.apple.com/account")],
                   manual=True)
    return Row("team", "Xcode account", WARN,
               "signed in as %s, project wants %s" % (", ".join(ids), facts.team_id),
               "Xcode has no session for the team this project builds for. Signing will fall "
               "back to the API key if one is configured, and fail otherwise.",
               manual=True)


def check_asc_key(facts: Facts) -> Row:
    creds = facts.cfg.asc_credentials()
    if not any(creds.values()):
        return Row("asc_key", "App Store Connect API key", WARN, "not configured",
                   "Optional but it is most of this tool's value: without it nothing can be "
                   "checked before a build, and build status cannot be read at all.\n"
                   "1. ↗ Create a key. App Manager is enough to read state and upload; cloud "
                   "signing is reported to need Admin, and a role cannot be changed after "
                   "creation — so if the machine has no distribution certificate of its own, "
                   "make it Admin.\n"
                   "2. Tools/ship auth import ~/Downloads/AuthKey_<KEYID>.p8\n"
                   "3. Tools/ship auth set-issuer <uuid from the top of that page>",
                   [KEY_LINK], manual=True)
    if not creds["key_path"] or not os.path.exists(creds["key_path"]):
        return Row("asc_key", "App Store Connect API key", FAIL, creds["key_path"] or "no path",
                   "The key file is gone. Apple only lets a .p8 be downloaded once, so unless "
                   "you have a copy this needs a new key.", [KEY_LINK], manual=True)
    if not creds["issuer_id"]:
        return Row("asc_key", "App Store Connect API key", WARN,
                   "key %s, no issuer id" % creds["key_id"],
                   "One field left:\n  Tools/ship auth set-issuer <uuid>\n"
                   "It is at the top of the API keys page with a Copy button.",
                   [KEY_LINK], manual=True)
    if facts.offline:
        return Row("asc_key", "App Store Connect API key", SKIP, "key %s (not validated)"
                   % creds["key_id"])
    if facts.asc_error:
        return Row("asc_key", "App Store Connect API key", WARN, "could not validate",
                   "App Store Connect said: %s" % facts.asc_error, [KEY_LINK])
    if facts.team_id and facts.asc_team and facts.asc_team != facts.team_id:
        return Row("asc_key", "App Store Connect API key", FAIL,
                   "wrong team — key %s belongs to %s" % (creds["key_id"], facts.asc_team),
                   "This project builds for %s. A key issued for another team authenticates "
                   "fine and then answers every question truthfully about the wrong team, which "
                   "is worse than no key at all.\n"
                   "1. ↗ On the API keys page, switch the team picker (top right) to %s\n"
                   "2. ＋ → role App Manager → Generate → Download\n"
                   "3. Tools/ship auth import ~/Downloads/AuthKey_<NEWID>.p8"
                   % (facts.team_id, facts.team_id), [KEY_LINK], manual=True)
    suffix = " (team %s)" % facts.asc_team if facts.asc_team else " (team has no assets yet)"
    return Row("asc_key", "App Store Connect API key", OK, "key %s%s" % (creds["key_id"], suffix))


# Capabilities this project's entitlements depend on, by the name Apple's API
# uses. The API returns ENABLED capabilities only — there is no disabled row
# with a false flag — so absence from the list is the only "off" signal there is.
#
# The vocabulary is open, not closed: values exist in production that are absent
# from Apple's own published enum, so an unknown string is reported, never
# treated as an error.
CAPABILITY_NOTES = {
    "ICLOUD": "iCloud/CloudKit — where the family's records live",
    "PUSH_NOTIFICATIONS": "push — how one parent's change reaches a child's device",
}


def check_bundle_id(facts: Facts) -> Row:
    if facts.asc_blocked:
        return Row("bundle_id", "App ID registration", SKIP, facts.asc_blocked,
                   facts.asc_error)
    if not facts.bundle_record:
        return Row("bundle_id", "App ID registration", FAIL, "%s not registered" % facts.bundle_id,
                   "Nothing has registered this App ID yet, so the New App dialog's Bundle ID "
                   "dropdown has nothing to pick. Registering it is the same operation as "
                   "Identifiers → ＋.", [IDENTIFIERS_LINK], fix="bundle_id")
    capabilities = facts.bundle_record.get("capabilities") or []
    wanted = _entitlement_capabilities(facts.entitlements)
    missing = [name for name in wanted if name not in capabilities]
    detail = "%s · %s" % (facts.bundle_id, ", ".join(capabilities) or "no capabilities")
    if missing:
        return Row("bundle_id", "App ID registration", FAIL, detail,
                   "The entitlements file asks for %s, and the App ID does not have %s enabled. "
                   "A provisioning profile cannot grant what the App ID does not carry, so "
                   "signing will fail — or worse, succeed with the capability quietly absent.\n"
                   "  ↗ Identifiers → %s → enable it, then run this again."
                   % (", ".join(CAPABILITY_NOTES.get(m, m) for m in wanted),
                      ", ".join(missing), facts.bundle_id),
                   [IDENTIFIERS_LINK], manual=True)
    return Row("bundle_id", "App ID registration", OK, detail)


def _entitlement_capabilities(entitlements: Dict[str, Any]) -> List[str]:
    """Which App ID capabilities this target's entitlements imply."""
    wanted = []
    if any(key.startswith("com.apple.developer.icloud") for key in entitlements):
        wanted.append("ICLOUD")
    if "aps-environment" in entitlements:
        wanted.append("PUSH_NOTIFICATIONS")
    return wanted


def check_musickit(facts: Facts) -> Row:
    """MusicKit cannot be verified from here, and saying so is the point.

    It is an App Service on the App ID, not an entitlement and not a bundle-id
    capability: there is no `MUSIC_KIT` value in Apple's CapabilityType enum and
    no App Services resource in the API, so it appears in no provisioning
    profile and a clean signed build proves nothing about it. With it off, every
    catalog request fails in a way that reads as a bug in our own code — which
    is exactly why a row that guessed "not enabled" from an empty API answer
    would be worse than useless."""
    return Row("musickit", "MusicKit on the App ID", SKIP, "not checkable from here",
               "MusicKit is an App Service, not a capability: it is absent from the API's "
               "vocabulary and from every provisioning profile, so neither this tool nor a "
               "successful signed build can confirm it.\n"
               "Eyes-on check: ↗ Identifiers → %s → App Services → MusicKit.\n"
               "The real proof is a catalog request on a device that comes back — and a "
               "well-formed API error counts, while an authorization failure does not."
               % facts.bundle_id,
               [IDENTIFIERS_LINK], manual=True)


def check_app_record(facts: Facts) -> Row:
    if facts.asc_blocked:
        return Row("app_record", "App Store Connect record", SKIP, facts.asc_blocked,
                   facts.asc_error or
                   "Unchecked is not the same as absent: without an answer here, a missing app "
                   "record is only discovered at upload time, twenty minutes into a release.")
    if not facts.app:
        return Row("app_record", "App Store Connect record", FAIL,
                   "none for %s" % facts.bundle_id,
                   "App creation is the one step genuinely absent from Apple's public API — "
                   "about two minutes by hand, once:\n"
                   "1. My Apps → ＋ → New App\n"
                   "2. Platform iOS. Name: must be unique across the whole App Store.\n"
                   "3. Bundle ID: pick %s from the dropdown\n"
                   "4. SKU: any internal identifier." % facts.bundle_id,
                   [APPS_LINK], manual=True)
    builds = facts.app.get("builds") or []
    detail = facts.app["name"]
    if builds:
        detail += " · latest build %s (%s)" % (builds[0]["version"], builds[0]["state"])
    return Row("app_record", "App Store Connect record", OK, detail)


def check_beta_group(facts: Facts) -> Row:
    """A build that reaches nobody.

    This is the row that exists because the failure is invisible: processing
    succeeds, the state says Ready to Test, and no tester is ever notified
    because no internal group was ever created."""
    if facts.asc_blocked or not facts.app:
        return Row("beta_group", "Internal TestFlight group", SKIP,
                   facts.asc_blocked or "needs an app record")
    internal = [group for group in facts.groups if group["internal"]]
    if internal:
        return Row("beta_group", "Internal TestFlight group", OK,
                   ", ".join(group["name"] for group in internal))
    return Row("beta_group", "Internal TestFlight group", WARN, "none",
               "Uploads will process successfully, reach 'Ready to Test', and be visible to "
               "nobody. The fix creates a group with automatic distribution on, so this and "
               "every later build lands in it without touching the console.\n"
               "Testers still have to be added once, in the TestFlight tab.",
               fix="beta_group")


def check_build_number(facts: Facts) -> Row:
    """Whether the next upload is about to be rejected for a used build number.

    Apple's answer to a duplicate is `ITMS-4238 Redundant Binary Upload`, and it
    arrives after the archive and after the whole binary has been transferred.
    This is the same answer, twenty minutes earlier.

    Uniqueness is per *train* — per marketing version — so the comparison is
    against builds sharing this app's CFBundleShortVersionString, not against
    every build ever uploaded."""
    current = facts.build_number
    if not current:
        return Row("build_number", "Build number", WARN, "CURRENT_PROJECT_VERSION not set",
                   "Set a build number once in Xcode (target → General → Build); this tool can "
                   "advance it from then on.")
    conditional = os.path.exists(facts.pbxproj) and _has_conditional_build_number(facts.pbxproj)
    if conditional:
        return Row("build_number", "Build number", FAIL,
                   "%s (declared conditionally)" % current,
                   "CURRENT_PROJECT_VERSION is written in the `[sdk=…]` conditional form. That "
                   "value is what the build uses and it is invisible to a plain rewrite, so "
                   "`Tools/ship bump` would report success while the shipped build kept the old "
                   "number. Set it unconditionally in Xcode.")
    if facts.asc_blocked or not facts.app:
        return Row("build_number", "Build number", SKIP,
                   "%s (%s) — not checked against Apple" % (current, facts.marketing_version),
                   "The project file is not authoritative here: a build uploaded from another "
                   "machine raises Apple's floor without touching it.")
    train = [build for build in (facts.app.get("builds") or [])
             if not facts.marketing_version or build.get("train") == facts.marketing_version]
    used = [build["version"] for build in train if build["version"]]
    if current in used:
        highest = max(used, key=xcode.build_number_sort_key)
        return Row("build_number", "Build number", FAIL, "%s already uploaded for %s"
                   % (current, facts.marketing_version),
                   "Apple rejects a repeated CFBundleVersion within a marketing version, and it "
                   "does so after the upload. The highest it holds for %s is %s.\n"
                   "  Tools/ship bump" % (facts.marketing_version, highest),
                   fix="build_number")
    if used:
        highest = max(used, key=xcode.build_number_sort_key)
        if xcode.build_number_sort_key(current) < xcode.build_number_sort_key(highest):
            return Row("build_number", "Build number", WARN,
                       "%s is below Apple's highest for %s (%s)"
                       % (current, facts.marketing_version, highest),
                       "TestFlight requires the number to rise within a train, so this upload "
                       "will be rejected.\n  Tools/ship bump", fix="build_number")
    return Row("build_number", "Build number", OK, "%s (%s)" % (current, facts.marketing_version))


def _has_conditional_build_number(pbxproj: str) -> bool:
    with open(pbxproj, encoding="utf-8") as handle:
        return bool(xcode.CONDITIONAL_BUILD_NUMBER_RE.search(handle.read()))


CHECKS = [
    check_xcode,
    check_project,
    check_floor,
    check_info_plist,
    check_encryption,
    check_entitlements,
    check_working_tree,
    check_signing,
    check_team,
    check_asc_key,
    check_bundle_id,
    check_musickit,
    check_app_record,
    check_beta_group,
    check_build_number,
]


def rows_for(facts: Facts) -> List[Row]:
    out: List[Row] = []
    for check in CHECKS:
        try:
            out.append(check(facts))
        except Exception as error:  # a broken probe must not take the checklist with it
            out.append(Row(getattr(check, "__name__", "check").replace("check_", ""),
                           getattr(check, "__name__", "check"), SKIP, "probe failed",
                           "%s: %s" % (type(error).__name__, error)))
    return out


def run(cfg: config.Config, offline: bool = False, as_json: bool = False) -> Result:
    facts = gather(cfg, offline=offline)
    rows = rows_for(facts)
    if not as_json:
        say("")
        for row in rows:
            say(row.render())
    failures = [row for row in rows if row.status == FAIL]
    warnings = [row for row in rows if row.status == WARN]
    data = {"rows": [row.as_dict() for row in rows],
            "fixable": [row.id for row in rows if row.fix],
            "bundle_id": facts.bundle_id, "team_id": facts.team_id,
            "build_number": facts.build_number, "marketing_version": facts.marketing_version,
            "counts": {"fail": len(failures), "warn": len(warnings),
                       "ok": len([r for r in rows if r.status == OK]),
                       "skip": len([r for r in rows if r.status == SKIP])}}
    if failures:
        # Blocked when every failure needs a human — a caller that retries on 1
        # would otherwise spin on something no retry can move.
        every_failure_is_manual = all(row.manual and not row.fix for row in failures)
        message = "%d check%s failing: %s" % (len(failures), "" if len(failures) == 1 else "s",
                                              ", ".join(row.label for row in failures))
        guidance = "Each failing row above carries its own steps. `Tools/ship next` picks one."
        return (blocked(message, guidance, data=data) if every_failure_is_manual
                else fail(message, guidance, data=data))
    if warnings:
        return ok("Ready, with %d warning%s" % (len(warnings), "" if len(warnings) == 1 else "s"),
                  "Nothing blocks a release. The warnings above are things that will cost time "
                  "later rather than fail now.", data=data)
    return ok("Every check passed", data=data)


# ── fixes ─────────────────────────────────────────────────────────────────────

def add_plist_key(text: str, key: str, value_xml: str, comment: str = "") -> str:
    """Insert a key before the closing </dict>, preserving everything else.

    plistlib would round-trip this file and silently delete its XML comments,
    and PlistBuddy does the same. The comments in a hand-written partial
    Info.plist are the only record of *why* a key is set there rather than as a
    build setting — losing them to a convenience is a bad trade."""
    if "<key>%s</key>" % key in text:
        return text
    closing = text.rfind("</dict>")
    if closing < 0:
        raise ValueError("no </dict> in the plist")
    block = "\n"
    if comment:
        block += "\t<!-- " + comment.replace("\n", "\n\t     ") + " -->\n"
    block += "\t<key>%s</key>\n\t%s\n" % (key, value_xml)
    return text[:closing] + block + text[closing:]


def fix_encryption(facts: Facts) -> Result:
    path = facts.info_plist_path
    if not path or not os.path.exists(path):
        return fail("There is no Info.plist file to declare the key in",
                    "This target generates its Info.plist entirely from build settings. Add a "
                    "partial Info.plist to the target first (outside a synchronized file group, "
                    "or Xcode copies it as a resource too and the build fails with 'multiple "
                    "commands produce Info.plist').")
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    updated = add_plist_key(
        text, ENCRYPTION_KEY, "<false/>",
        "Answers the export compliance question once, at build time. Without it every\n"
        "upload lands in TestFlight as 'Missing Compliance' and is untestable until\n"
        "somebody answers the same question by hand, per build. This app's only\n"
        "cryptography is HTTPS, which is exempt.")
    if updated == text:
        return ok("%s was already declared" % ENCRYPTION_KEY)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(updated)
    return ok("Declared %s = false" % ENCRYPTION_KEY,
              "Written to %s. It is a source change — commit it." % path,
              data={"path": path})


def fix_bundle_id(facts: Facts) -> Result:
    if facts.client is None:
        return blocked("Registering the App ID needs an API key",
                       "Or do it by hand: ↗ Identifiers → ＋ → App IDs → %s" % facts.bundle_id,
                       links=[IDENTIFIERS_LINK])
    # UNIVERSAL when the project builds for both platforms: an iOS-only record
    # would have to be recreated the first time the Mac target ships, and a
    # UNIVERSAL record does not match an IOS-filtered query.
    platforms = facts.settings.get("SUPPORTED_PLATFORMS", "")
    platform = "UNIVERSAL" if "macosx" in platforms else "IOS"
    try:
        created = facts.client.register_bundle_id(facts.bundle_id, platform)
    except asc.ASCError as error:
        return fail("Could not register %s" % facts.bundle_id, str(error),
                    links=[IDENTIFIERS_LINK])
    if not created:
        return ok("%s was already registered" % facts.bundle_id)
    return ok("Registered %s" % facts.bundle_id,
              "It will now appear in the Bundle ID dropdown when you create the app record.",
              links=[APPS_LINK])


def fix_beta_group(facts: Facts) -> Result:
    if facts.client is None:
        return blocked("Creating a TestFlight group needs an API key")
    if not facts.app:
        return blocked("There is no app record to attach a group to",
                       "Create the app in App Store Connect first — see the app_record row.",
                       links=[APPS_LINK])
    name = facts.cfg.beta_group
    existing = [group for group in facts.groups if group["name"] == name]
    if existing:
        return ok("A group named '%s' already exists" % name)
    try:
        group = facts.client.create_internal_group(facts.app["id"], name)
    except asc.ASCError as error:
        return fail("Could not create the group", str(error), links=[APPS_LINK])
    return ok("Created internal group '%s'" % name,
              "Automatic distribution is on, so this and every later build lands in it. Add "
              "testers once in the TestFlight tab — the group exists, but it is empty.",
              data={"group": group}, links=[APPS_LINK])


def next_build_number(facts: Facts) -> str:
    """The number that will not be rejected: one past the highest anyone has,
    local or remote. The local project file is not authoritative — a build
    uploaded from another machine raises Apple's floor without touching it."""
    local = xcode.read_build_numbers(facts.pbxproj) if os.path.exists(facts.pbxproj) else []
    candidates = list(local)
    for build in (facts.app.get("builds") or []):
        if build.get("version") and (not facts.marketing_version
                                     or build.get("train") == facts.marketing_version):
            candidates.append(build["version"])
    if not candidates:
        return "1"
    return xcode.next_build_number(max(candidates, key=xcode.build_number_sort_key))


def fix_build_number(facts: Facts) -> Result:
    current = xcode.read_build_numbers(facts.pbxproj)
    if not current:
        return fail("CURRENT_PROJECT_VERSION is not set in the project",
                    "Set a build number once in Xcode (target → General → Build).")
    candidate = next_build_number(facts)
    bump = xcode.write_build_number(facts.pbxproj, candidate)
    if bump.conditional:
        return fail("CURRENT_PROJECT_VERSION is declared conditionally — refusing to edit it",
                    "The `[sdk=…]` form takes precedence and is invisible to this rewrite, so "
                    "editing the plain form would report success and ship the old number. Set it "
                    "unconditionally in Xcode first.")
    if not xcode.pbxproj_parses(facts.pbxproj):
        return fail("The project file no longer parses after the edit",
                    "Restore it with `git checkout -- %s` and set the build number by hand."
                    % facts.pbxproj)
    return ok("Build number %s → %s" % (current[0], candidate),
              "Rewritten in %d build configuration%s. It is a source change — commit it."
              % (bump.count, "" if bump.count == 1 else "s"),
              data={"build_number": candidate, "configurations": bump.count})


FIXES = {
    "encryption": fix_encryption,
    "bundle_id": fix_bundle_id,
    "beta_group": fix_beta_group,
    "build_number": fix_build_number,
}


def apply_fix(cfg: config.Config, fix_id: Optional[str]) -> Result:
    if not fix_id:
        return ok("Repairable rows", "\n".join("  %s" % name for name in sorted(FIXES)),
                  data={"fixes": sorted(FIXES)})
    if fix_id not in FIXES:
        # A usage error, not a failure: nothing was attempted and the fix is to
        # the command line, not to the project.
        return usage("No fix called '%s'" % fix_id,
                     "Repairable rows: %s" % ", ".join(sorted(FIXES)),
                     data={"fixes": sorted(FIXES)})
    facts = gather(cfg, offline=False)
    return FIXES[fix_id](facts)
