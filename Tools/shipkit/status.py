"""What App Store Connect currently says about this app.

The question after an upload is never "did xcodebuild exit zero" — it did, ten
minutes ago. It is "has Apple finished processing it, and can anyone install
it". Those are two different facts and the second one is the one people forget:
a build can reach *Ready to Test* and still be visible to nobody, because
nothing has ever created a group for it to land in.
"""

from __future__ import annotations

from typing import Any, Dict, List

from . import asc, config, xcode
from .report import Link, Result, blocked, fail, ok, say

APPS_LINK = Link("Open My Apps", "https://appstoreconnect.apple.com/apps")
TESTFLIGHT_APP = Link("TestFlight for iPhone", "https://apps.apple.com/app/testflight/id899247664")


def testflight_link(app_id: str) -> Link:
    if not app_id:
        return APPS_LINK
    return Link("Open the TestFlight tab",
                "https://appstoreconnect.apple.com/apps/%s/testflight/ios" % app_id)


def run(cfg: config.Config) -> Result:
    client = asc.client_for(cfg)
    if client is None:
        return blocked(
            "No App Store Connect API key configured",
            "Build state can only be read through the API — a signed-in Xcode session cannot "
            "answer it.\n  Tools/ship auth import ~/Downloads/AuthKey_<KEYID>.p8\n"
            "  Tools/ship auth set-issuer <uuid>",
            links=[Link("Create API key",
                        "https://appstoreconnect.apple.com/access/integrations/api")])

    settings = xcode.build_settings(cfg.xcodeproj, cfg.scheme, cfg.configuration)
    bundle_id = settings.get("PRODUCT_BUNDLE_IDENTIFIER", "")
    if not bundle_id:
        return fail("Could not read PRODUCT_BUNDLE_IDENTIFIER from the project")

    try:
        app = client.live_app(bundle_id)
    except asc.ASCError as error:
        return fail("App Store Connect refused the query", str(error), links=[APPS_LINK])

    if not app:
        return blocked(
            "No app record for %s" % bundle_id,
            "App creation is the one step genuinely absent from Apple's public API — about two "
            "minutes by hand:\n"
            "1. My Apps → ＋ → New App\n"
            "2. Platform iOS. Name: must be unique across the whole App Store.\n"
            "3. Bundle ID: pick %s from the dropdown\n"
            "4. SKU: any internal identifier." % bundle_id,
            data={"bundle_id": bundle_id}, links=[APPS_LINK])

    builds: List[Dict[str, Any]] = app.get("builds") or []
    try:
        groups = client.beta_groups(app["id"])
    except asc.ASCError:
        groups = []
    internal = [group for group in groups if group["internal"]]

    data = {"bundle_id": bundle_id, "app_id": app["id"], "app_name": app["name"],
            "builds": builds, "beta_groups": groups}

    say("")
    say("  %s  (%s)" % (app["name"], bundle_id))
    for build in builds[:5]:
        say("  %-8s %-8s %-12s %-24s %s" % (build["train"], build["version"], build["state"],
                                            build["beta_state"] or "—", build["uploaded"] or ""))
    if not builds:
        say("  no builds uploaded")

    links = [testflight_link(app["id"]), TESTFLIGHT_APP]

    if not builds:
        return fail("The app record exists but holds no builds",
                    "Nothing has been uploaded for %s yet. `Tools/ship release` does that."
                    % bundle_id, data=data, links=links)

    latest = builds[0]
    name = "Build %s (%s)" % (latest["version"], latest["train"] or "?")

    # A build nobody can install is the failure this command exists to catch —
    # it looks identical to success everywhere else.
    group_note = ""
    if not internal:
        group_note = ("\n\nThere is no internal TestFlight group, so even a ready build reaches "
                      "nobody.\n  Tools/ship fix beta_group")

    # processingState is Apple's scan; internalBuildState is whether a tester can
    # actually install it. They disagree in the case that matters most: a build
    # can be VALID and still sit in MISSING_EXPORT_COMPLIANCE, processed
    # perfectly and undistributable.
    beta = latest["beta_state"]
    if beta == "MISSING_EXPORT_COMPLIANCE":
        return fail("%s is waiting on an export compliance answer" % name,
                    "It uploaded and processed fine and no tester can install it. Answer it "
                    "once in the build's page — or, better, declare it at build time so it never "
                    "happens again:\n  Tools/ship fix encryption",
                    data=data, links=links)
    if beta in ("READY_FOR_BETA_TESTING", "IN_BETA_TESTING"):
        return ok("%s is ready to test" % name,
                  "Open the TestFlight app on the phone, signed in with the same Apple ID.%s"
                  % group_note, data=data, links=links)
    if beta == "EXPIRED":
        return fail("%s has expired" % name,
                    "TestFlight builds expire ninety days after upload. Ship a new one.",
                    data=data, links=links)

    state = latest["state"]
    if state == "PROCESSING":
        return ok("%s is still processing" % name,
                  "Apple is scanning it — usually a few minutes. Ask again shortly.%s"
                  % group_note, data=data, links=links)
    if state == "FAILED":
        return fail("%s failed processing" % name,
                    "Apple rejected the binary after upload. The reason was emailed to the "
                    "developer account address — it is in no local log.",
                    data=data, links=links)
    if state == "INVALID":
        return fail("%s is invalid" % name,
                    "Usually an entitlement the provisioning profile does not carry, or a "
                    "missing Info.plist value. The TestFlight tab carries the specific "
                    "complaint.", data=data, links=links)
    if state == "VALID":
        # VALID with an unrecognised beta state: report both rather than
        # inventing a verdict from the half we understand.
        return ok("%s processed (%s)" % (name, beta or "no beta state reported"),
                  "Apple's scan passed. Whether a tester can install it is the beta state above."
                  + group_note, data=data, links=links)
    return ok("%s: %s" % (name, state or "unknown"), data=data, links=links)
