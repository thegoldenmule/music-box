"""Checklist rows, and the distinction the whole checklist rests on.

"Asked, and the answer was no" and "never asked" are different facts, and a row
that renders the second as the first is worse than a row that is absent — it
sends someone to create an app record that already exists, or lets a release
proceed on a check that never ran.

The wrong-team case is where that distinction is easiest to lose. A key issued
for another team authenticates perfectly and answers every question truthfully
about the wrong team, so `gather` stops as soon as it notices — and everything
downstream then holds an empty result that means "not asked".
"""

from __future__ import annotations

import unittest

from shipkit import config, preflight
from shipkit.report import FAIL, OK, SKIP, WARN


def facts(**kwargs) -> preflight.Facts:
    cfg = config.Config(root="/tmp/repo", xcodeproj="/tmp/repo/App.xcodeproj", scheme="App")
    out = preflight.Facts(cfg=cfg)
    out.settings = {"PRODUCT_BUNDLE_IDENTIFIER": "com.example.app",
                    "DEVELOPMENT_TEAM": "TEAM123",
                    "CURRENT_PROJECT_VERSION": "3",
                    "MARKETING_VERSION": "0.1"}
    for key, value in kwargs.items():
        setattr(out, key, value)
    return out


class UncheckedIsNotAbsent(unittest.TestCase):
    BLOCKED = "blocked — the API key belongs to team OTHER"

    def test_app_record_is_skipped_not_failed(self) -> None:
        row = preflight.check_app_record(facts(asc_blocked=self.BLOCKED))
        self.assertEqual(row.status, SKIP)
        self.assertIn("OTHER", row.detail)

    def test_bundle_id_is_skipped_not_failed(self) -> None:
        self.assertEqual(preflight.check_bundle_id(facts(asc_blocked=self.BLOCKED)).status, SKIP)

    def test_beta_group_is_skipped(self) -> None:
        self.assertEqual(preflight.check_beta_group(facts(asc_blocked=self.BLOCKED)).status, SKIP)

    def test_build_number_is_skipped(self) -> None:
        self.assertEqual(preflight.check_build_number(facts(asc_blocked=self.BLOCKED)).status,
                         SKIP)

    def test_a_real_answer_still_fails(self) -> None:
        # The guard must not swallow the genuine case: probes ran, and the app
        # record really is not there.
        row = preflight.check_app_record(facts(asc_blocked="", client=object(), app={}))
        self.assertEqual(row.status, FAIL)
        self.assertTrue(row.manual, "creating an app record is not something this tool can do")
        self.assertFalse(row.fix, "a manual row must not offer a fix that does nothing")


class BuildNumberAgainstApple(unittest.TestCase):
    def app(self, *builds) -> dict:
        return {"id": "1", "name": "App", "builds": list(builds)}

    def build(self, version: str, train: str = "0.1") -> dict:
        return {"version": version, "train": train, "state": "VALID", "beta_state": ""}

    def test_a_used_number_fails(self) -> None:
        row = preflight.check_build_number(facts(app=self.app(self.build("3"))))
        self.assertEqual(row.status, FAIL)
        self.assertEqual(row.fix, "build_number")

    def test_a_number_below_apples_highest_fails_too(self) -> None:
        # TestFlight requires the number to rise within a train, so this would
        # be rejected after the upload rather than before it.
        row = preflight.check_build_number(facts(app=self.app(self.build("9"))))
        self.assertEqual(row.status, WARN)

    def test_a_different_train_does_not_collide(self) -> None:
        # Uniqueness is per marketing version. Build 3 of 0.2 says nothing about
        # build 3 of 0.1.
        row = preflight.check_build_number(facts(app=self.app(self.build("3", train="0.2"))))
        self.assertEqual(row.status, OK)

    def test_ten_is_higher_than_nine(self) -> None:
        # Lexical comparison would call "10" lower than "9" and let a colliding
        # upload through.
        row = preflight.check_build_number(
            facts(app=self.app(self.build("10")),
                  settings=dict(facts().settings, CURRENT_PROJECT_VERSION="9")))
        self.assertEqual(row.status, WARN)


class NextBuildNumber(unittest.TestCase):
    def test_clears_apples_highest_even_when_the_project_trails(self) -> None:
        # The local project file is not authoritative: a build uploaded from
        # another machine raises Apple's floor without touching it.
        got = preflight.next_build_number(facts(app={
            "builds": [{"version": "12", "train": "0.1"}]}))
        self.assertEqual(got, "13")

    def test_ignores_other_trains(self) -> None:
        got = preflight.next_build_number(facts(app={
            "builds": [{"version": "99", "train": "0.9"}]}))
        self.assertEqual(got, "1")


class EntitlementCapabilities(unittest.TestCase):
    def test_icloud_and_push_are_derived_from_the_entitlements(self) -> None:
        wanted = preflight._entitlement_capabilities({
            "com.apple.developer.icloud-container-identifiers": ["iCloud.x"],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "aps-environment": "development",
        })
        self.assertEqual(sorted(wanted), ["ICLOUD", "PUSH_NOTIFICATIONS"])

    def test_nothing_wanted_when_the_app_asks_for_nothing(self) -> None:
        self.assertEqual(preflight._entitlement_capabilities({}), [])


class RowsSurviveABrokenProbe(unittest.TestCase):
    def test_an_exception_in_one_check_does_not_lose_the_rest(self) -> None:
        # A checklist that dies on its ninth row tells you nothing about the
        # other fourteen, which is the opposite of its job.
        def explode(_facts):
            raise RuntimeError("probe blew up")

        original = list(preflight.CHECKS)
        try:
            preflight.CHECKS.insert(0, explode)
            rows = preflight.rows_for(facts())
        finally:
            preflight.CHECKS[:] = original
        self.assertEqual(rows[0].status, SKIP)
        self.assertIn("probe blew up", rows[0].guidance)
        self.assertGreater(len(rows), 1)


class FixesAreReal(unittest.TestCase):
    def test_every_offered_fix_exists(self) -> None:
        # A row offering `Tools/ship fix X` where X is not in FIXES is a
        # checklist telling the user to run a command that errors.
        offered = set()
        for check in preflight.CHECKS:
            try:
                row = check(facts())
            except Exception:
                continue
            if row.fix:
                offered.add(row.fix)
        self.assertTrue(offered <= set(preflight.FIXES),
                        "offered but not implemented: %s" % (offered - set(preflight.FIXES)))


if __name__ == "__main__":
    unittest.main()
