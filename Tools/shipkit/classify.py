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
"Sign in as the Account Holder → Agreements, Tax, and Banking → accept what is pending. "
        "Nobody else on the team can, and no flag works around it.",
        [AGREEMENTS], manual=True,
    ),
    Rule(
        "duplicate_build_number",
        ["already been used", "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
         "bundle version must be higher", "The build number must be higher"],
        "Apple already has a build with this number",
"Build {build_number} has been used before.\n"
        "  Tools/ship bump, then release again.",
        [APPS],
    ),
    Rule(
        "missing_app_record",
        ["DistributionAppRecordProviderError.missingApp", "Error Downloading App Information",
         "No suitable application records were found", "app record was not found"],
        "No App Store Connect app record for {bundle_id}",
"Create it by hand — Apple has no API for this.\n"
        "  My Apps → ＋ → New App → iOS, pick {bundle_id} from the Bundle ID dropdown.\n"
        "Then `Tools/ship upload` — the archive is still on disk.",
        [APPS], manual=True,
    ),
    Rule(
        "no_dist_cert",
        ['No signing certificate "iOS Distribution"', 'No signing certificate "Apple Distribution"',
         "no valid signing identity"],
        "No distribution certificate in the keychain",
"Xcode → Settings → Accounts → team {team_id} → Manage Certificates… → ＋ → Apple "
        "Distribution.",
        [Link("Open Xcode", "/Applications/Xcode.app")],
        manual=True,
    ),
    Rule(
        "cloud_signing_permission",
        ["Cloud signing permission error", "not permitted to manage certificates",
         "DeveloperAPIServiceErrorDomain Code=5", "cloud-managed distribution certificates"],
        "The API key cannot manage signing (its role is too low)",
"Key {key_id} authenticated and cannot mint signing assets — that needs role Admin, "
        "which cannot be changed after creation. Make a new key and import it, or put a "
        "distribution certificate in the keychain so nothing has to be minted.",
        [INTEGRATIONS],
        manual=True,
    ),
    Rule(
        "redundant_binary",
        ["ITMS-4238", "Redundant Binary Upload"],
        "Apple already has build {build_number} for this version",
"Build {build_number} is already uploaded for this version.\n"
        "  Tools/ship bump, then release again.",
        [APPS],
    ),
    Rule(
        "device_not_registered",
        ["doesn't include the currently selected device", "no devices registered",
         "There are no devices registered"],
        "The provisioning profile does not cover this machine",
"A TestFlight build does not need a development profile at all.\n"
        "  Tools/ship release --unsigned-archive",
        [DEVELOPER_ACCOUNT],
    ),
    Rule(
        "entitlement_not_in_profile",
        ["doesn't match the entitlements", "does not support the", "Invalid Code Signing Entitlements",
         "doesn't support the following capabilities", "is not available with a Personal Team"],
        "The profile does not carry a capability the entitlements ask for",
"↗ Identifiers → {bundle_id} → enable the capability the log names, then release "
        "again. Signing regenerates the profile.",
        [IDENTIFIERS],
        manual=True,
    ),
    Rule(
        "signing_conflict",
        ["conflicting provisioning settings", "Automatic signing is disabled"],
        "Automatic signing is fighting a pinned identity",
"Xcode → target → Signing & Capabilities → Automatically manage signing. Or archive "
        "unsigned:\n  Tools/ship release --unsigned-archive",
    ),
    Rule(
        "no_profiles",
        ["No profiles for", "Provisioning profile", "profile doesn't match", "doesn't include signing certificate"],
        "Provisioning profile problem",
"Run it again — signing regenerates profiles. If it repeats, ↗ Identifiers must list "
        "{bundle_id} under team {team_id}.",
        [IDENTIFIERS],
    ),
    Rule(
        "not_signed_in",
        ["No Accounts", "Your session has expired", "No Apple ID", "requires a development team",
         "No signing certificate"],
        "No usable Apple account for signing",
"Sign into Xcode (Settings → Accounts → ＋, team {team_id}), or configure an API key, "
        "which does not expire:\n  Tools/ship auth import ~/Downloads/AuthKey_<KEYID>.p8",
        [INTEGRATIONS],
        manual=True,
    ),
    Rule(
        "asc_auth",
        ["Failed to authenticate", "authentication credentials", "NOT_AUTHORIZED",
         "Authentication credentials are missing or invalid"],
        "App Store Connect rejected the credentials",
"The key is invalid, revoked, or belongs to a team other than {team_id}.",
        [INTEGRATIONS],
        manual=True,
    ),
    Rule(
        "asset_validation",
        ["Asset validation failed", "ITMS-", "Invalid Bundle", "Missing Info.plist value"],
        "Apple rejected the uploaded binary",
"The ITMS- code in the log is Apple's specific complaint — search it verbatim.",
        [APPS],
        manual=True,
    ),
    Rule(
        "network",
        ["Communication with Apple failed", "The network connection was lost", "timed out",
         "Could not connect to the server"],
        "Network problem talking to Apple",
"Transient — retry. If it repeats immediately, check for a VPN or proxy.",
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
"The failing test is named just above the summary. Fix it, or --skip-tests.",
    ),
    Rule(
        "export_failed",
        ["error: exportArchive", "** EXPORT FAILED **"],
        "Export or upload failed",
"No specific signature matched. The reason is in the .xcdistributionlogs bundle named "
        "in the log — IDEDistribution.verbose.log inside it names the failing step.",
    ),
    Rule(
        "archive_failed",
        ["** ARCHIVE FAILED **", "** BUILD FAILED **"],
        "The archive failed to build",
"A compile or signing error. The last `error:` line is the cause.",
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
    "Read the log for the first `error:` line — that is the cause. If it turns out to be a "
    "recognisable failure, add its signature to Tools/shipkit/classify.py.",
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
