"""Failure signatures → a diagnosis and the exact next action.

This is the half of the tool that earns its keep. `xcodebuild` failures are
several hundred lines ending in something like `error: exportArchive`, and the
sentence that tells you what to *do* is usually not in there at all. Every
signature below was either observed in a real run or is documented as the
literal string Apple emits, and each one maps to steps rather than to a
restatement of the error.

Rules are ordered most-specific-first and the first match wins, so a generic
`** ARCHIVE FAILED **` never shadows the specific reason it failed.

`{bundle_id}`, `{team_id}`, `{build_number}` and `{key_id}` are substituted from
the pipeline's context — guidance that names the actual identifier is guidance
someone can follow without translating it first.
"""

from __future__ import annotations

import dataclasses
import re
from typing import Any, Dict, List, Optional

from .report import Link


@dataclasses.dataclass
class Rule:
    id: str
    patterns: List[str]
    title: str
    guidance: str
    links: List[Link] = dataclasses.field(default_factory=list)
    # True when no retry can help — a human has to go and do something.
    manual: bool = False


DEVELOPER_ACCOUNT = Link("Apple Developer account", "https://developer.apple.com/account")
APPS = Link("Open My Apps", "https://appstoreconnect.apple.com/apps")
IDENTIFIERS = Link("Open Identifiers",
                   "https://developer.apple.com/account/resources/identifiers/list")
INTEGRATIONS = Link("Open Integrations",
                    "https://appstoreconnect.apple.com/access/integrations/api")
AGREEMENTS = Link("Open Agreements", "https://appstoreconnect.apple.com/agreements")


RULES: List[Rule] = [
    Rule(
        "agreement_not_accepted",
        ["You must accept the latest", "have not been accepted", "Contracts, Tax, and Banking",
         "must first sign the relevant contracts"],
        "An Apple agreement is waiting to be accepted",
        "Apple blocks uploads until the account holder accepts the current Program License "
        "Agreement. Nobody else on the team can do it and no flag works around it.\n"
        "1. Sign in as the Account Holder\n"
        "2. Agreements, Tax, and Banking → accept whatever is pending\n"
        "3. Run the release again.",
        [AGREEMENTS], manual=True,
    ),
    Rule(
        "duplicate_build_number",
        ["already been used", "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
         "bundle version must be higher", "The build number must be higher"],
        "Apple already has a build with this number",
        "CFBundleVersion has to rise for every upload of the same marketing version, and "
        "{build_number} has been used before.\n"
        "1. Tools/ship bump\n"
        "2. Run the release again.\n"
        "(`Tools/ship doctor` reads the highest number Apple holds and warns before the archive, "
        "which is twenty minutes earlier than this.)",
        [APPS],
    ),
    Rule(
        "missing_app_record",
        ["DistributionAppRecordProviderError.missingApp", "Error Downloading App Information",
         "No suitable application records were found", "app record was not found"],
        "No App Store Connect app record for {bundle_id}",
        "App creation is the one step genuinely absent from Apple's public API — about two "
        "minutes by hand, once:\n"
        "1. My Apps → ＋ → New App\n"
        "2. Platform iOS. Name: must be unique across the whole App Store.\n"
        "3. Bundle ID: pick {bundle_id} from the dropdown — it is already registered, because "
        "signing registered it on the first archive.\n"
        "4. SKU: any internal identifier.\n"
        "The archive is still on disk; `Tools/ship upload` will not need to rebuild it.",
        [APPS], manual=True,
    ),
    Rule(
        "no_dist_cert",
        ['No signing certificate "iOS Distribution"', 'No signing certificate "Apple Distribution"',
         "no valid signing identity"],
        "No distribution certificate in the keychain",
        "1. Xcode → Settings → Accounts → select team {team_id}\n"
        "2. Manage Certificates… → ＋ (bottom left) → Apple Distribution\n"
        "3. Run the release again.\n"
        "An App Manager API key can also mint one during export — a Developer-role key cannot.",
        [Link("Open Xcode", "/Applications/Xcode.app")],
        manual=True,
    ),
    Rule(
        "cloud_signing_permission",
        ["Cloud signing permission error", "not permitted to manage certificates",
         "DeveloperAPIServiceErrorDomain Code=5", "cloud-managed distribution certificates"],
        "The API key cannot manage signing (its role is too low)",
        "Key {key_id} authenticated and was then refused permission to mint signing assets. "
        "Cloud signing is reported to need the Admin role — App Manager is enough to upload and "
        "read state but not, apparently, to sign. A key's role cannot be changed after creation.\n"
        "1. Revoke it and create a new key with role Admin\n"
        "2. Tools/ship auth import ~/Downloads/AuthKey_<NEWID>.p8\n"
        "Or sidestep it: with a distribution certificate already in the keychain and a signed-in "
        "Xcode session, nothing needs to be minted in the cloud.",
        [INTEGRATIONS],
        manual=True,
    ),
    Rule(
        "redundant_binary",
        ["ITMS-4238", "Redundant Binary Upload"],
        "Apple already has build {build_number} for this version",
        "CFBundleVersion must be unique within a marketing version — Apple calls that a train — "
        "and it rejects a repeat only after the whole binary has been transferred.\n"
        "1. Tools/ship bump\n"
        "2. Run the release again.\n"
        "`Tools/ship doctor` reads the highest number Apple holds for this train and warns "
        "before the archive, which is a great deal earlier than this.",
        [APPS],
    ),
    Rule(
        "device_not_registered",
        ["doesn't include the currently selected device", "no devices registered",
         "There are no devices registered"],
        "The provisioning profile does not cover this machine",
        "This bites when the archive is signed for *development*. A TestFlight build does not "
        "need it: the only signature that matters is the distribution one applied at export, and "
        "a distribution profile needs no registered devices.\n"
        "  Tools/ship release --unsigned-archive\n"
        "Registering the machine also works (`-allowProvisioningDeviceRegistration`) but spends "
        "a device slot on the account.",
        [DEVELOPER_ACCOUNT],
    ),
    Rule(
        "entitlement_not_in_profile",
        ["doesn't match the entitlements", "does not support the", "Invalid Code Signing Entitlements",
         "doesn't support the following capabilities", "is not available with a Personal Team"],
        "The profile does not carry a capability the entitlements ask for",
        "The App ID has to have the capability enabled before a profile can carry it — this app "
        "asks for iCloud/CloudKit and push.\n"
        "1. ↗ Identifiers → {bundle_id} → enable the capability the log names\n"
        "2. Run the release again; automatic signing regenerates the profile.\n"
        "If the log names aps-environment, check `Tools/ship verify` output: an App Store export "
        "must end up with `production`, whatever the source entitlements file says.",
        [IDENTIFIERS],
        manual=True,
    ),
    Rule(
        "signing_conflict",
        ["conflicting provisioning settings", "Automatic signing is disabled"],
        "Automatic signing is fighting a pinned identity",
        "The target pins a code-sign identity or profile that automatic signing cannot override. "
        "Either clear the manual setting in Xcode (target → Signing & Capabilities → Automatically "
        "manage signing) or archive unsigned and let export do the signing:\n"
        "  Tools/ship release --unsigned-archive",
    ),
    Rule(
        "no_profiles",
        ["No profiles for", "Provisioning profile", "profile doesn't match", "doesn't include signing certificate"],
        "Provisioning profile problem",
        "1. Run it again — automatic signing regenerates profiles, and a profile that predates "
        "your certificate heals on the next attempt\n"
        "2. If it repeats: ↗ Identifiers — {bundle_id} must be listed under team {team_id}\n"
        "3. If the auth in use cannot regenerate profiles, the 'auth:' line at the top of the log "
        "says which one it was (an API key must be role App Manager).",
        [IDENTIFIERS],
    ),
    Rule(
        "not_signed_in",
        ["No Accounts", "Your session has expired", "No Apple ID", "requires a development team",
         "No signing certificate"],
        "No usable Apple account for signing",
        "Either sign into Xcode (Settings → Accounts → ＋, then select team {team_id}), or "
        "configure an API key, which works headless and does not expire the way a login session "
        "does:\n  Tools/ship auth import ~/Downloads/AuthKey_<KEYID>.p8",
        [INTEGRATIONS],
        manual=True,
    ),
    Rule(
        "asc_auth",
        ["Failed to authenticate", "authentication credentials", "NOT_AUTHORIZED",
         "Authentication credentials are missing or invalid"],
        "App Store Connect rejected the credentials",
        "The key was rejected outright — it is invalid, revoked, or belongs to a different team "
        "than {team_id}. `Tools/ship doctor` checks the key's team against the project's before "
        "anything is built, because a wrong-team key answers every other question truthfully "
        "about the wrong team.",
        [INTEGRATIONS],
        manual=True,
    ),
    Rule(
        "asset_validation",
        ["Asset validation failed", "ITMS-", "Invalid Bundle", "Missing Info.plist value"],
        "Apple rejected the uploaded binary",
        "This is Apple's own validation, not xcodebuild's — the ITMS- code in the log is the "
        "specific complaint and is worth searching verbatim. `Tools/ship verify` reads the keys "
        "back out of the built artifact, which catches the Info.plist family of these before an "
        "upload rather than after.",
        [APPS],
        manual=True,
    ),
    Rule(
        "network",
        ["Communication with Apple failed", "The network connection was lost", "timed out",
         "Could not connect to the server"],
        "Network problem talking to Apple",
        "Transient. Retry. If it repeats immediately, check whether a VPN or proxy is in the way "
        "— Apple's upload endpoints are picky about both.",
    ),
    Rule(
        "test_failed",
        # Both dialects. The only stage that runs tests runs `swift test`, which
        # emits none of xcodebuild's strings — a rule carrying only those could
        # never fire on the one place it is asked to.
        ["** TEST FAILED **", "Testing failed:",
         "Test Suite 'All tests' failed", "error: fatalError", "Fatal error:",
         "with 1 failure", "failures, ", " failure ("],
        "The package tests failed",
        "The failing test is named just above the summary in the log. Fix it, or run with "
        "--skip-tests if you are certain and in a hurry — but a red suite is the cheapest signal "
        "available and this is the last place it is free.",
    ),
    Rule(
        "export_failed",
        ["error: exportArchive", "** EXPORT FAILED **"],
        "Export or upload failed",
        "xcodebuild rejected the export and no specific signature matched. The real reason is in "
        "the .xcdistributionlogs bundle whose path appears in the log above — inside it, "
        "IDEDistribution.standard.log names the failing step.",
    ),
    Rule(
        "archive_failed",
        ["** ARCHIVE FAILED **", "** BUILD FAILED **"],
        "The archive failed to build",
        "A compile or signing error, not a release problem. The last `error:` line in the log is "
        "the actual cause; everything after it is fallout.",
    ),
]


@dataclasses.dataclass
class Diagnosis:
    id: str
    title: str
    guidance: str
    links: List[Link]
    manual: bool = False

    def as_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "title": self.title, "guidance": self.guidance,
                "manual": self.manual, "links": [l.as_dict() for l in self.links]}


UNKNOWN = Rule(
    "unknown", [],
    "The step failed and no known signature matched",
    "Read the tail of the log for the first `error:` line — that is the cause; everything after "
    "it is consequence. If the failure turns out to be a recognisable one, its signature belongs "
    "in Tools/shipkit/classify.py so the next person gets a sentence instead of a log.",
)

ERROR_LINE = re.compile(r"^.*\berror:\s*(.+)$", re.M)

# On a failed export, xcodebuild writes a bundle of logs to $TMPDIR and prints
# its path exactly once. `IDEDistribution.verbose.log` inside it holds the
# actual cause; the console output holds a generic exit 70. Losing that path is
# losing the only copy of the diagnosis.
DISTRIBUTION_LOGS = re.compile(r'bundle at path "([^"]+\.xcdistributionlogs)"')


def first_error(log_text: str) -> str:
    """The first `error:` line, which is the cause; the rest is fallout.

    Note the pattern is deliberately loose about what follows `error:` —
    Xcode 26 emits `error: exportArchive <message>` where Xcode 15 emitted
    `error: exportArchive: <message>`, and anchoring on the colon breaks on one
    or the other."""
    match = ERROR_LINE.search(log_text)
    return match.group(1).strip() if match else ""


def distribution_log_bundle(log_text: str) -> str:
    match = DISTRIBUTION_LOGS.search(log_text)
    return match.group(1) if match else ""


def classify(log_text: str, context: Optional[Dict[str, str]] = None) -> Diagnosis:
    context = context or {}
    for rule in RULES:
        if any(pattern in log_text for pattern in rule.patterns):
            return Diagnosis(rule.id, _fill(rule.title, context), _fill(rule.guidance, context),
                             rule.links, rule.manual)
    guidance = UNKNOWN.guidance
    error = first_error(log_text)
    if error:
        guidance = "First error in the log:\n  %s\n\n%s" % (error, guidance)
    bundle = distribution_log_bundle(log_text)
    if bundle:
        guidance += ("\n\nThe export wrote its own logs to:\n  %s\nIDEDistribution.verbose.log "
                     "inside it names the failing step." % bundle)
    return Diagnosis(UNKNOWN.id, UNKNOWN.title, guidance, [])


def _fill(text: str, context: Dict[str, str]) -> str:
    for key, value in context.items():
        text = text.replace("{%s}" % key, str(value))
    return text
