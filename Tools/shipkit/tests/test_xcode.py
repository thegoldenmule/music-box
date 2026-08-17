"""The pure halves of the Xcode layer: build numbers and `defaults` parsing.

The build-number rewrite is the one place this tool edits a file the maintainer
also edits by hand, so it is tested against the exact shapes a `project.pbxproj`
uses — including the ones a naive regex would corrupt.
"""

from __future__ import annotations

import unittest

from shipkit import xcode

PBXPROJ = """\
/* Begin XCBuildConfiguration section */
\t\t1A2B /* Debug */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCURRENT_PROJECT_VERSION = 7;
\t\t\t\tDEVELOPMENT_TEAM = QKMK66X2FU;
\t\t\t\tMARKETING_VERSION = 0.1;
\t\t\t};
\t\t\tname = Debug;
\t\t};
\t\t3C4D /* Release */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCURRENT_PROJECT_VERSION = 7;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET[sdk=iphoneos*] = 17.0;
\t\t\t\tMARKETING_VERSION = 0.1;
\t\t\t};
\t\t\tname = Release;
\t\t};
"""


class BuildNumberRewrite(unittest.TestCase):
    def test_rewrites_every_configuration(self) -> None:
        out, count = xcode.bump_build_number_text(PBXPROJ, "8")
        self.assertEqual(count, 2)
        self.assertEqual(out.count("CURRENT_PROJECT_VERSION = 8;"), 2)
        self.assertNotIn("CURRENT_PROJECT_VERSION = 7;", out)

    def test_touches_nothing_else(self) -> None:
        out, _ = xcode.bump_build_number_text(PBXPROJ, "8")
        for line in ("DEVELOPMENT_TEAM = QKMK66X2FU;", "MARKETING_VERSION = 0.1;",
                     "isa = XCBuildConfiguration;", "name = Release;"):
            self.assertIn(line, out)
        self.assertEqual(len(out.split("\n")), len(PBXPROJ.split("\n")))

    def test_reports_zero_when_the_setting_is_absent(self) -> None:
        _, count = xcode.bump_build_number_text("buildSettings = {\n};\n", "8")
        self.assertEqual(count, 0)

    def test_handles_a_quoted_dotted_value(self) -> None:
        text = "\t\t\t\tCURRENT_PROJECT_VERSION = 1.2.3;\n"
        out, count = xcode.bump_build_number_text(text, "1.2.4")
        self.assertEqual(count, 1)
        self.assertIn("CURRENT_PROJECT_VERSION = 1.2.4;", out)

    def test_does_not_match_a_differently_named_setting(self) -> None:
        # A prefix match would rewrite this and silently change a different key.
        text = "\t\t\t\tMY_CURRENT_PROJECT_VERSION_SUFFIX = 7;\n"
        _, count = xcode.bump_build_number_text(text, "8")
        self.assertEqual(count, 0)


class NextBuildNumber(unittest.TestCase):
    CASES = [("7", "8"), ("0", "1"), ("1.2.3", "1.2.4"), ("1.2.9", "1.2.10"), ("99", "100")]

    def test_cases(self) -> None:
        for current, expected in self.CASES:
            with self.subTest(current):
                self.assertEqual(xcode.next_build_number(current), expected)

    def test_non_numeric_restarts_rather_than_raising(self) -> None:
        self.assertEqual(xcode.next_build_number("beta"), "1")


class BuildNumberOrdering(unittest.TestCase):
    def test_sorts_numerically_not_lexically(self) -> None:
        values = ["9", "10", "2"]
        self.assertEqual(max(values, key=xcode.build_number_sort_key), "10")

    def test_compares_dotted_components(self) -> None:
        self.assertGreater(xcode.build_number_sort_key("1.10"), xcode.build_number_sort_key("1.9"))

    def test_survives_a_non_numeric_component(self) -> None:
        self.assertEqual(xcode.build_number_sort_key("1.beta.3"), (1, 0, 3))


class ConditionalSettings(unittest.TestCase):
    def test_finds_the_sdk_conditional_form(self) -> None:
        found = xcode.CONDITIONAL_SETTING_RE.findall(PBXPROJ)
        self.assertEqual(found, ["IPHONEOS_DEPLOYMENT_TARGET"])

    def test_ignores_the_unconditional_form(self) -> None:
        self.assertEqual(
            xcode.CONDITIONAL_SETTING_RE.findall("\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;\n"), [])


class TeamParsing(unittest.TestCase):
    DEFAULTS = """{
    "QKMK66X2FU" =     {
        teamID = QKMK66X2FU;
        teamName = "The Golden Mule";
        teamType = Individual;
    };
    "ABC123" =     {
        teamID = ABC123;
        teamName = "Other Co";
    };
}"""

    def test_pairs_names_with_ids(self) -> None:
        self.assertEqual(xcode.parse_team_entries(self.DEFAULTS),
                         [{"id": "QKMK66X2FU", "name": "The Golden Mule"},
                          {"id": "ABC123", "name": "Other Co"}])

    def test_empty_when_nobody_is_signed_in(self) -> None:
        self.assertEqual(xcode.parse_team_entries("does not exist"), [])

    def test_an_id_with_no_name_still_counts(self) -> None:
        entries = xcode.parse_team_entries("teamID = LONELY;\n")
        self.assertEqual(entries, [{"id": "LONELY", "name": ""}])


if __name__ == "__main__":
    unittest.main()
