"""Failure signatures, tested against the literal strings Apple emits.

The value of a classifier is entirely in whether it fires on the real log, so
these cases use verbatim fragments rather than paraphrases. The ordering tests
matter as much as the matching ones: a generic `** ARCHIVE FAILED **` appears in
almost every failed log, and if it shadowed the specific reason the classifier
would be worse than no classifier at all.
"""

from __future__ import annotations

import unittest

from shipkit import classify


class Matching(unittest.TestCase):
    CASES = [
        ("duplicate build number",
         "ERROR ITMS-4238: \"Redundant Binary Upload. There already exists a binary upload "
         "with build version '4.2' for train '4.2'\"",
         "redundant_binary"),
        ("missing app record",
         "error: exportArchive No suitable application records were found.",
         "missing_app_record"),
        ("no distribution certificate",
         'error: exportArchive No signing certificate "Apple Distribution" found',
         "no_dist_cert"),
        ("cloud signing role",
         "Cloud signing permission error (DeveloperAPIServiceErrorDomain Code=5)",
         "cloud_signing_permission"),
        ("device not registered",
         "Provisioning profile \"iOS Team Provisioning Profile\" doesn't include the currently "
         "selected device 'Constantine'.",
         "device_not_registered"),
        ("agreement",
         "You must accept the latest Program License Agreement before continuing.",
         "agreement_not_accepted"),
        ("network",
         "The network connection was lost.",
         "network"),
        ("archive failure with nothing more specific",
         "CompileSwift normal arm64\n** ARCHIVE FAILED **",
         "archive_failed"),
    ]

    def test_cases(self) -> None:
        for name, log, expected in self.CASES:
            with self.subTest(name):
                self.assertEqual(classify.classify(log).id, expected)


class Ordering(unittest.TestCase):
    def test_the_specific_reason_beats_the_generic_failure(self) -> None:
        # Every failed archive ends with this banner. If it won, no specific
        # diagnosis would ever be reachable.
        log = ('error: exportArchive No signing certificate "Apple Distribution" found\n'
               "** EXPORT FAILED **\n** ARCHIVE FAILED **")
        self.assertEqual(classify.classify(log).id, "no_dist_cert")

    def test_an_agreement_beats_a_signing_complaint(self) -> None:
        # These co-occur: an unaccepted agreement makes signing fail too, and
        # fixing the signature does nothing until the agreement is accepted.
        log = ("You must accept the latest Program License Agreement\n"
               "error: No profiles for 'com.example.app' were found")
        self.assertEqual(classify.classify(log).id, "agreement_not_accepted")


class Substitution(unittest.TestCase):
    def test_context_is_spliced_into_the_guidance(self) -> None:
        diagnosis = classify.classify("No suitable application records were found",
                                      {"bundle_id": "com.thegoldenmule.auralsanbox"})
        self.assertIn("com.thegoldenmule.auralsanbox", diagnosis.guidance)
        self.assertNotIn("{bundle_id}", diagnosis.guidance)

    def test_an_absent_key_leaves_no_stray_braces_it_can_fill(self) -> None:
        diagnosis = classify.classify("No suitable application records were found", {})
        # Nothing was supplied, so the placeholder survives — which is ugly but
        # honest. What must never happen is a half-filled sentence claiming a
        # value nobody provided.
        self.assertIn("{bundle_id}", diagnosis.guidance)


class Unknown(unittest.TestCase):
    def test_surfaces_the_first_error_line(self) -> None:
        log = ("note: something\n"
               "/tmp/x.swift:4:1: error: cannot find 'foo' in scope\n"
               "/tmp/x.swift:9:1: error: consequence of the first one\n")
        diagnosis = classify.classify(log)
        self.assertEqual(diagnosis.id, "unknown")
        self.assertIn("cannot find 'foo' in scope", diagnosis.guidance)
        self.assertNotIn("consequence of the first one", diagnosis.guidance)

    def test_matches_the_xcode_26_spelling_without_a_colon(self) -> None:
        # Xcode 15 wrote `error: exportArchive: <message>`; Xcode 26 dropped the
        # colon. Anchoring on either spelling breaks on the other.
        self.assertEqual(classify.first_error("error: exportArchive Some new phrasing"),
                         "exportArchive Some new phrasing")

    def test_recovers_the_distribution_log_bundle_path(self) -> None:
        log = ('[MT] IDEDistribution: Created bundle at path '
               '"/var/folders/x/AuralSandbox_2026-08-17_14-30-00.123.xcdistributionlogs".')
        self.assertTrue(classify.distribution_log_bundle(log).endswith(".xcdistributionlogs"))
        self.assertIn("xcdistributionlogs", classify.classify(log).guidance)

    def test_no_path_when_there_is_none(self) -> None:
        self.assertEqual(classify.distribution_log_bundle("** ARCHIVE FAILED **"), "")


class Coverage(unittest.TestCase):
    def test_every_rule_has_steps_and_a_unique_id(self) -> None:
        ids = [rule.id for rule in classify.RULES]
        self.assertEqual(len(ids), len(set(ids)))
        for rule in classify.RULES:
            with self.subTest(rule.id):
                self.assertTrue(rule.patterns, "a rule with no patterns can never fire")
                self.assertTrue(rule.guidance.strip())
                self.assertTrue(rule.title.strip())


if __name__ == "__main__":
    unittest.main()
