"""Writing a credential to disk without leaving it somewhere git can commit it.

Every test here exists because of an ordering or a mode, not because of an
algorithm. The interesting failures are all of the form "it worked, and also
left the secret somewhere" — which no functional test would notice.
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest

from shipkit import config, proc


def git(*args, cwd: str) -> None:
    subprocess.run(["git", "-C", cwd] + list(args), check=True, capture_output=True)


class Repo:
    """A throwaway git repo, because the guard's whole job is asking git."""

    def __enter__(self) -> str:
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        git("init", "-q", cwd=root)
        git("config", "user.email", "t@example.com", cwd=root)
        git("config", "user.name", "T", cwd=root)
        return root

    def __exit__(self, *_) -> None:
        self.dir.cleanup()


def cfg_for(root: str) -> config.Config:
    return config.Config(root=root, xcodeproj=os.path.join(root, "A.xcodeproj"), scheme="A")


class IgnoreBeforeWrite(unittest.TestCase):
    def test_the_ignore_rule_lands_before_the_secret_does(self) -> None:
        with Repo() as root:
            cfg = cfg_for(root)
            cfg.write_env({"ASC_KEY_ID": "SECRETKEY"})
            self.assertTrue(config.gitignore_covers_env(
                open(os.path.join(root, ".gitignore")).read()))
            # The real test: git itself agrees, which is the only opinion that
            # decides whether it gets committed.
            self.assertTrue(proc.run(["git", "-C", root, "check-ignore", "-q",
                                      cfg.env_path], timeout=30).ok)

    def test_refuses_when_the_env_is_already_tracked(self) -> None:
        # A tracked file is never ignored, whatever rule exists — so adding one
        # would be a fix that changes nothing while reporting success.
        with Repo() as root:
            cfg = cfg_for(root)
            with open(cfg.env_path, "w") as handle:
                handle.write("EXISTING=1\n")
            git("add", "-f", ".env", cwd=root)
            git("commit", "-qm", "oops", cwd=root)
            with self.assertRaises(config.SecretWriteRefused):
                cfg.write_env({"ASC_KEY_ID": "SECRETKEY"})
            self.assertNotIn("SECRETKEY", open(cfg.env_path).read())

    def test_a_non_repo_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            cfg = cfg_for(root)
            cfg.write_env({"ASC_KEY_ID": "K"})
            self.assertEqual(config.parse_env(open(cfg.env_path).read())["ASC_KEY_ID"], "K")


class WritePermissions(unittest.TestCase):
    def test_the_env_is_never_group_or_world_readable(self) -> None:
        with Repo() as root:
            cfg = cfg_for(root)
            cfg.write_env({"ASC_KEY_ID": "K"})
            mode = stat.S_IMODE(os.stat(cfg.env_path).st_mode)
            self.assertEqual(mode & 0o077, 0, "mode was %o" % mode)


class AtomicReplace(unittest.TestCase):
    def test_an_existing_env_survives_a_failed_write(self) -> None:
        # Opening the destination with "w" truncates it before a byte is
        # written, so a crash mid-write destroys unrelated secrets. Writing a
        # temp file and renaming means the old contents survive any failure.
        # The rename is the moment of truth, so that is where the failure goes.
        with Repo() as root:
            cfg = cfg_for(root)
            cfg.write_env({"UNRELATED": "keepme"})
            original = open(cfg.env_path).read()

            real_replace = os.replace
            os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("disk full"))
            try:
                with self.assertRaises(OSError):
                    cfg.write_env({"ASC_KEY_ID": "SECRETKEY"})
            finally:
                os.replace = real_replace

            self.assertEqual(open(cfg.env_path).read(), original)
            self.assertNotIn("SECRETKEY", open(cfg.env_path).read())
            leftovers = [n for n in os.listdir(root)
                         if n.startswith(".env.") and n.endswith(".tmp")]
            self.assertEqual(leftovers, [], "a temp file holding the secret was left behind")

    def test_no_temp_files_are_left_behind(self) -> None:
        with Repo() as root:
            cfg = cfg_for(root)
            cfg.write_env({"ASC_KEY_ID": "K"})
            leftovers = [n for n in os.listdir(root) if n.startswith(".env.") and n.endswith(".tmp")]
            self.assertEqual(leftovers, [])

    def test_unrelated_keys_survive_an_update(self) -> None:
        with Repo() as root:
            cfg = cfg_for(root)
            cfg.write_env({"UNRELATED": "keepme"})
            cfg.write_env({"ASC_KEY_ID": "K"})
            parsed = config.parse_env(open(cfg.env_path).read())
            self.assertEqual(parsed, {"UNRELATED": "keepme", "ASC_KEY_ID": "K"})


class WorktreeRoots(unittest.TestCase):
    def test_a_dot_git_file_counts_as_a_root(self) -> None:
        # In a worktree or a submodule, .git is a FILE. Testing for a directory
        # walks past it into some unrelated outer repo — which is then where
        # the credential gets written.
        with tempfile.TemporaryDirectory() as outer:
            git("init", "-q", cwd=outer)
            inner = os.path.join(outer, "sub")
            os.makedirs(inner)
            with open(os.path.join(inner, ".git"), "w") as handle:
                handle.write("gitdir: /elsewhere/.git\n")
            self.assertEqual(config.repo_root(inner), inner)


class Redaction(unittest.TestCase):
    def test_credential_values_are_blanked_from_a_command_line(self) -> None:
        line = proc.quote(["xcodebuild", "-authenticationKeyID", "ABC123DEFG",
                           "-authenticationKeyIssuerID", "69a6de78-0000-47e3-e053-5b8c7c11a4d1"])
        out = proc.redact(line, ["ABC123DEFG", "69a6de78-0000-47e3-e053-5b8c7c11a4d1"])
        self.assertNotIn("ABC123DEFG", out)
        self.assertNotIn("69a6de78", out)
        self.assertIn("xcodebuild", out)

    def test_empty_and_tiny_values_are_ignored(self) -> None:
        # Redacting "" would replace between every character; redacting a
        # two-character value would shred unrelated text.
        self.assertEqual(proc.redact("hello world", ["", "o"]), "hello world")

    def test_longest_first(self) -> None:
        # Replacing the short value first would leave the long one half-intact.
        out = proc.redact("KEYID-EXTRA", ["KEYID", "KEYID-EXTRA"])
        self.assertEqual(out, "<redacted>")


if __name__ == "__main__":
    unittest.main()
