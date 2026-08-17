"""What `next` picks, and in what order.

The ordering is the design, so it is what gets tested. It is not "most severe
first" — it is the order in which doing one thing stops being wasted effort.
A loop driven by this must also terminate, which is why there is a test that a
finished release reports `done` rather than looping back to `release`.
"""

from __future__ import annotations

import unittest

from shipkit import config, nextstep, preflight
from shipkit.report import FAIL, OK, SKIP, WARN, Row


def facts(**kwargs) -> preflight.Facts:
    cfg = config.Config(root="/tmp/repo", xcodeproj="/tmp/repo/App.xcodeproj", scheme="App")
    out = preflight.Facts(cfg=cfg)
    out.settings = {"CURRENT_PROJECT_VERSION": kwargs.pop("build_number", "3"),
                    "MARKETING_VERSION": kwargs.pop("marketing_version", "0.1")}
    for key, value in kwargs.items():
        setattr(out, key, value)
    return out


def rows(**statuses) -> list:
    """A clean checklist, overridden by keyword. Every row defaults to ok, so a
    test only states the thing it is about."""
    default = ["xcode", "project", "floor", "plist", "encryption", "entitlements", "git",
               "signing", "team", "asc_key", "bundle_id", "musickit", "app_record",
               "beta_group", "build_number"]
    out = []
    for name in default:
        status, fix = statuses.get(name, (OK, ""))
        out.append(Row(name, name.replace("_", " "), status, "detail", "guidance", fix=fix))
    return out


class Ordering(unittest.TestCase):
    def test_a_repairable_failure_comes_before_a_manual_one(self) -> None:
        # Applying the repairable fix may clear the other row too, and it costs
        # a second against a trip to a browser.
        action = nextstep.decide(facts(), rows(app_record=(FAIL, ""),
                                               bundle_id=(FAIL, "bundle_id")))
        self.assertEqual(action.id, "bundle_id")
        self.assertEqual(action.kind, "run")
        self.assertEqual(action.command, "Tools/ship fix bundle_id")

    def test_a_manual_failure_is_reported_as_manual(self) -> None:
        action = nextstep.decide(facts(), rows(app_record=(FAIL, "")))
        self.assertEqual(action.id, "app_record")
        self.assertEqual(action.kind, "manual")
        self.assertEqual(action.command, "")

    def test_the_key_can_be_declined_so_the_loop_can_finish(self) -> None:
        # Without an opt-out `next` returns the same manual step forever on a
        # machine that will never have a key, and can never reach `done`.
        f = facts()
        f.cfg.skip_asc_key = True
        action = nextstep.decide(f, rows(asc_key=(WARN, "")))
        self.assertEqual(action.id, "release")

    def test_declining_the_key_does_not_skip_real_failures(self) -> None:
        f = facts()
        f.cfg.skip_asc_key = True
        action = nextstep.decide(f, rows(asc_key=(WARN, ""), app_record=(FAIL, "")))
        self.assertEqual(action.id, "app_record")

    def test_an_outage_is_a_wait_not_a_missing_key(self) -> None:
        # Both surface as a warning on the same row. Telling someone to create a
        # key they already have — as `manual`, which the contract says retrying
        # cannot help — is the wrong answer to a problem that fixes itself.
        f = facts(asc_blocked="App Store Connect unreachable",
                  asc_error="cannot reach App Store Connect: timed out")
        action = nextstep.decide(f, rows(asc_key=(WARN, "")))
        self.assertEqual(action.id, "unreachable")
        self.assertEqual(action.kind, "wait")

    def test_a_real_failure_still_beats_an_outage(self) -> None:
        f = facts(asc_blocked="App Store Connect unreachable", asc_error="timed out")
        action = nextstep.decide(f, rows(plist=(FAIL, "")))
        self.assertEqual(action.id, "plist")

    def test_credentials_come_before_optional_repairs(self) -> None:
        # Without a key nothing can be checked before a build or read after one,
        # so every later decision would be made blind.
        action = nextstep.decide(facts(), rows(asc_key=(WARN, ""),
                                               encryption=(WARN, "encryption")))
        self.assertEqual(action.id, "asc_key")

    def test_recommended_repairs_come_before_shipping(self) -> None:
        action = nextstep.decide(facts(), rows(encryption=(WARN, "encryption")))
        self.assertEqual(action.id, "encryption")

    def test_a_dirty_tree_blocks_the_release(self) -> None:
        action = nextstep.decide(facts(), rows(git=(WARN, "")))
        self.assertEqual(action.id, "commit")
        self.assertEqual(action.kind, "manual")

    def test_a_clean_checklist_means_ship(self) -> None:
        action = nextstep.decide(facts(), rows())
        self.assertEqual(action.id, "release")
        self.assertEqual(action.command, "Tools/ship release")

    def test_a_warning_with_no_fix_does_not_stall_the_loop(self) -> None:
        # `entitlements` warns on every run of this project (the source file
        # says aps-environment development, which is correct). If a warning
        # with no repair were chosen, the loop would never advance.
        action = nextstep.decide(facts(), rows(entitlements=(WARN, "")))
        self.assertEqual(action.id, "release")


class InFlight(unittest.TestCase):
    def build(self, **kwargs) -> dict:
        payload = {"version": "3", "train": "0.1", "state": "VALID", "beta_state": ""}
        payload.update(kwargs)
        return {"id": "1", "name": "App", "builds": [payload]}

    def test_waits_while_apple_is_processing(self) -> None:
        action = nextstep.decide(facts(app=self.build(state="PROCESSING")), rows())
        self.assertEqual(action.id, "wait")
        # NOT kind "run": its command only reports, so a driver that ran it in a
        # loop would spin against Apple's processing queue and never advance.
        self.assertEqual(action.kind, "wait")

    def test_a_ready_build_terminates_the_loop(self) -> None:
        action = nextstep.decide(
            facts(app=self.build(beta_state="READY_FOR_BETA_TESTING")), rows())
        self.assertEqual(action.kind, "done")

    def test_missing_compliance_is_surfaced_as_a_human_step(self) -> None:
        # It processed successfully and no tester can install it; nothing in
        # processingState says so.
        action = nextstep.decide(
            facts(app=self.build(beta_state="MISSING_EXPORT_COMPLIANCE")), rows())
        self.assertEqual(action.id, "compliance")
        self.assertEqual(action.kind, "manual")

    def test_a_build_from_a_different_version_train_does_not_count(self) -> None:
        # Uniqueness and ordering are per train, so a build of 0.2 says nothing
        # about whether 0.1 build 3 has been uploaded.
        action = nextstep.decide(
            facts(app=self.build(train="0.2", state="PROCESSING")), rows())
        self.assertEqual(action.id, "release")

    def test_a_different_build_number_means_this_one_has_not_shipped(self) -> None:
        action = nextstep.decide(
            facts(app=self.build(version="2", beta_state="READY_FOR_BETA_TESTING")), rows())
        self.assertEqual(action.id, "release")


if __name__ == "__main__":
    unittest.main()
