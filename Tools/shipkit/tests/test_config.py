"""The pure halves of config: .env editing and gitignore coverage.

These are worth testing hard because both failure modes are silent and
expensive. A careless .env rewrite destroys an unrelated secret; a .gitignore
that does not actually cover .env means the tool cheerfully writes a credential
into a tracked file and reports success.
"""

from __future__ import annotations

import os
import tempfile
import unittest

from shipkit import config


class ParseEnv(unittest.TestCase):
    CASES = [
        ("plain", "ASC_KEY_ID=ABC123", {"ASC_KEY_ID": "ABC123"}),
        ("export prefix", "export ASC_KEY_ID=ABC123", {"ASC_KEY_ID": "ABC123"}),
        ("double quoted", 'ASC_KEY_ID="ABC123"', {"ASC_KEY_ID": "ABC123"}),
        ("single quoted", "ASC_KEY_ID='ABC123'", {"ASC_KEY_ID": "ABC123"}),
        ("padded", "  ASC_KEY_ID = ABC123  ", {"ASC_KEY_ID": "ABC123"}),
        ("comment", "# ASC_KEY_ID=NOPE", {}),
        ("blank", "\n\n", {}),
        ("no equals", "JUST_A_WORD", {}),
        ("value with equals", "TOKEN=a=b=c", {"TOKEN": "a=b=c"}),
    ]

    def test_cases(self) -> None:
        for name, text, expected in self.CASES:
            with self.subTest(name):
                self.assertEqual(config.parse_env(text), expected)


class UpsertEnv(unittest.TestCase):
    def test_rewrites_in_place_and_keeps_position(self) -> None:
        text = "# creds\nASC_KEY_ID=OLD\nOTHER=keep\n"
        out = config.upsert_env_text(text, {"ASC_KEY_ID": "NEW"})
        self.assertEqual(out, "# creds\nASC_KEY_ID=NEW\nOTHER=keep\n")

    def test_keeps_export_prefix(self) -> None:
        out = config.upsert_env_text("export ASC_KEY_ID=OLD\n", {"ASC_KEY_ID": "NEW"})
        self.assertIn("export ASC_KEY_ID=NEW", out)

    def test_appends_what_is_missing(self) -> None:
        out = config.upsert_env_text("OTHER=keep\n", {"ASC_KEY_ID": "NEW"})
        self.assertEqual(config.parse_env(out), {"OTHER": "keep", "ASC_KEY_ID": "NEW"})

    def test_preserves_unrelated_lines_and_comments(self) -> None:
        text = "# a comment\n\nUNRELATED=secret\n# trailing note\n"
        out = config.upsert_env_text(text, {"ASC_ISSUER_ID": "x"})
        for line in ("# a comment", "UNRELATED=secret", "# trailing note"):
            self.assertIn(line, out)

    def test_appends_cleanly_to_a_file_with_no_trailing_newline(self) -> None:
        out = config.upsert_env_text("OTHER=keep", {"NEW": "1"})
        self.assertEqual(config.parse_env(out), {"OTHER": "keep", "NEW": "1"})


class GitignoreCoverage(unittest.TestCase):
    def test_recognised_spellings(self) -> None:
        for line in (".env", "/.env", "*.env", ".env*"):
            with self.subTest(line):
                self.assertTrue(config.gitignore_covers_env("build/\n%s\n" % line))

    def test_near_misses_are_not_coverage(self) -> None:
        # `.envrc` and a commented rule both look like coverage to a careless
        # substring check, and neither one keeps a credential out of a commit.
        for line in (".envrc", "# .env", "env", "Tools/.env"):
            with self.subTest(line):
                self.assertFalse(config.gitignore_covers_env("build/\n%s\n" % line))


class Tildify(unittest.TestCase):
    def test_home_relative(self) -> None:
        home = os.path.expanduser("~")
        self.assertEqual(config.tildify(os.path.join(home, "private_keys", "k.p8")),
                         "~/private_keys/k.p8")

    def test_leaves_other_paths_alone(self) -> None:
        self.assertEqual(config.tildify("/opt/keys/k.p8"), "/opt/keys/k.p8")

    def test_does_not_match_a_sibling_prefix(self) -> None:
        # `/Users/ben` must not be rewritten when home is `/Users/benjamin`.
        home = os.path.expanduser("~")
        self.assertEqual(config.tildify(home + "x/keys"), home + "x/keys")


class Discovery(unittest.TestCase):
    def test_prefers_apps_and_ignores_build_output(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "Apps", "Thing", "Thing.xcodeproj"))
            os.makedirs(os.path.join(root, "DerivedData", "Ghost.xcodeproj"))
            os.makedirs(os.path.join(root, "build", "Stale.xcodeproj"))
            self.assertEqual(config.find_xcodeproj(root),
                             os.path.join(root, "Apps", "Thing", "Thing.xcodeproj"))

    def test_does_not_descend_into_a_project_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            nested = os.path.join(root, "Apps", "Thing", "Thing.xcodeproj",
                                  "project.xcworkspace", "Inner.xcodeproj")
            os.makedirs(nested)
            self.assertEqual(config.find_xcodeproj(root),
                             os.path.join(root, "Apps", "Thing", "Thing.xcodeproj"))

    def test_none_when_there_is_no_project(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            self.assertIsNone(config.find_xcodeproj(root))


if __name__ == "__main__":
    unittest.main()
