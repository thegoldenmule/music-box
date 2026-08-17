"""Argument parsing, and one trap that silently discarded half the flags.

`--json` is the whole machine-facing contract, so an option that is accepted and
then ignored is not a papercut: `ship --json doctor` printed nothing at all on
stdout, and a caller parsing it saw an empty document rather than an error.

The cause is an argparse behaviour worth stating plainly, because the code that
triggers it looks entirely reasonable. A parser built with `parents=[common]`
copies the parent's *arguments*, including their defaults. When `common` is a
parent of both the root parser and each subparser, argparse parses the
subcommand into a fresh namespace and copies every key back onto the main one —
so the subparser's `--json` default of False lands on top of the True the root
parser had already parsed. `default=argparse.SUPPRESS` leaves an unsupplied
option out of the namespace entirely, so there is nothing to copy over.
"""

from __future__ import annotations

import unittest

from shipkit import cli


def parse(*argv):
    return cli.apply_defaults(cli.build_parser().parse_args(list(argv)))


class SharedOptionsWorkInBothPositions(unittest.TestCase):
    def test_json_after_the_subcommand(self) -> None:
        self.assertTrue(parse("info", "--json").json)

    def test_json_before_the_subcommand(self) -> None:
        # The regression: this silently parsed as False.
        self.assertTrue(parse("--json", "info").json)

    def test_json_absent(self) -> None:
        self.assertFalse(parse("info").json)

    def test_project_before_the_subcommand(self) -> None:
        self.assertEqual(parse("--project", "/tmp/A.xcodeproj", "info").project,
                         "/tmp/A.xcodeproj")

    def test_project_after_the_subcommand(self) -> None:
        self.assertEqual(parse("info", "--project", "/tmp/A.xcodeproj").project,
                         "/tmp/A.xcodeproj")

    def test_mixed_positions(self) -> None:
        args = parse("-q", "--project", "/tmp/A.xcodeproj", "doctor", "--json", "--offline")
        self.assertTrue(args.quiet)
        self.assertTrue(args.json)
        self.assertTrue(args.offline)
        self.assertEqual(args.project, "/tmp/A.xcodeproj")

    def test_every_shared_option_survives_from_the_front(self) -> None:
        args = parse("--json", "-q", "--scheme", "S", "--configuration", "Debug", "info")
        self.assertTrue(args.json)
        self.assertTrue(args.quiet)
        self.assertEqual(args.scheme, "S")
        self.assertEqual(args.configuration, "Debug")

    def test_defaults_are_filled_in_for_every_shared_option(self) -> None:
        # SUPPRESS means an unsupplied option is absent from the namespace, so
        # every command would crash on attribute access without this.
        args = parse("info")
        for name in cli.SHARED_DEFAULTS:
            self.assertTrue(hasattr(args, name), "%s missing from the namespace" % name)

    def test_shared_options_reach_a_nested_subcommand(self) -> None:
        args = parse("auth", "show", "--json")
        self.assertTrue(args.json)
        self.assertEqual(args.auth_command, "show")


class EveryDeclaredCommandIsWired(unittest.TestCase):
    def test_no_subparser_without_a_handler(self) -> None:
        # A declared-but-unwired subcommand is reachable only as a runtime
        # failure, which is a poor place to discover it.
        actions = [a for a in cli.build_parser()._actions
                   if hasattr(a, "choices") and a.dest == "command"]
        self.assertTrue(actions, "no subparsers found")
        declared = set(actions[0].choices)
        self.assertEqual(declared - set(cli.COMMANDS), set())


if __name__ == "__main__":
    unittest.main()


class WalkIsWiredAndGuarded(unittest.TestCase):
    def test_walk_is_a_declared_command(self) -> None:
        self.assertIn("walk", cli.COMMANDS)

    def test_walk_refuses_json(self) -> None:
        # It is a conversation, not an output format. Silently ignoring --json
        # would put prompts where a caller expects one parseable object.
        from shipkit import config, walk
        result = walk.run(config.Config(root="/tmp", xcodeproj="/tmp/A.xcodeproj", scheme="A"),
                          as_json=True)
        self.assertFalse(result.ok)
