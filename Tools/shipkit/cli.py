"""Argument parsing and dispatch.

Every subcommand is a function of `(cfg, args) -> Result`, and `main` does
nothing but choose one and render what comes back. That shape is what makes the
tool scriptable: there is no path where a command writes its own answer to
stdout, so `--json` is guaranteed to be the only thing on it.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Callable, Dict, List

from . import __version__, config, report, xcode
from .report import Result, blocked, fail, ok

EPILOG = """\
driving this from a script or an agent
  Every command takes --json and prints exactly one object on stdout; all
  progress and subprocess output goes to stderr, so the two never mix.

  Exit codes
    0  ok
    1  failed — something the tool tried did not work
    2  usage error
    3  blocked on a human: a step no tool can perform (create the app record,
       accept an agreement, wait for Apple). Retrying will not help.
"""


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true",
                        help="print one JSON object on stdout (prose still goes to stderr)")
    common.add_argument("--project", metavar="PATH", help="path to the .xcodeproj (default: discovered)")
    common.add_argument("--scheme", metavar="NAME", help="scheme to build (default: the project's name)")
    common.add_argument("--configuration", metavar="NAME", help="build configuration (default: Release)")
    common.add_argument("-q", "--quiet", action="store_true", help="do not stream subprocess output")

    parser = argparse.ArgumentParser(
        prog="ship",
        parents=[common],
        description="Walk this Xcode app from a clean checkout to a TestFlight build.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--version", action="version", version="ship " + __version__)
    subparsers = parser.add_subparsers(dest="command", metavar="<command>")

    def add(name: str, help_text: str) -> argparse.ArgumentParser:
        return subparsers.add_parser(name, parents=[common], help=help_text, description=help_text)

    add("info", "print the resolved project facts and where the tool will write")

    add("status", "what App Store Connect currently says about this app's builds")

    bump = add("bump", "set or advance CURRENT_PROJECT_VERSION in the project file")
    bump.add_argument("value", nargs="?", help="the exact build number (default: advance by one)")

    auth = add("auth", "manage the App Store Connect API credentials")
    auth_sub = auth.add_subparsers(dest="auth_command", metavar="<subcommand>")
    auth_sub.add_parser("show", parents=[common], help="what is configured, and from where")
    auth_import = auth_sub.add_parser("import", parents=[common], help="adopt a downloaded AuthKey_*.p8")
    auth_import.add_argument("p8", help="path to the .p8 Apple gave you")
    auth_issuer = auth_sub.add_parser("set-issuer", parents=[common], help="save the Issuer ID")
    auth_issuer.add_argument("issuer", help="the UUID from the top of the API keys page")

    add("selftest", "run this tool's own unit tests")
    return parser


# ── commands ──────────────────────────────────────────────────────────────────

def cmd_info(cfg: config.Config, args: argparse.Namespace) -> Result:
    if not cfg.xcodeproj:
        return fail("No .xcodeproj found",
                    "Looked under %s. Pass --project if it lives somewhere else." % cfg.root)
    settings = xcode.build_settings(cfg.xcodeproj, cfg.scheme, cfg.configuration)
    pbxproj = os.path.join(cfg.xcodeproj, "project.pbxproj")
    data = {
        "root": cfg.root,
        "xcodeproj": cfg.xcodeproj,
        "scheme": cfg.scheme,
        "configuration": cfg.configuration,
        "build_dir": cfg.build_dir,
        "bundle_id": settings.get("PRODUCT_BUNDLE_IDENTIFIER", ""),
        "team_id": settings.get("DEVELOPMENT_TEAM", ""),
        "marketing_version": settings.get("MARKETING_VERSION", ""),
        "build_number": settings.get("CURRENT_PROJECT_VERSION", ""),
        "deployment_target": settings.get("IPHONEOS_DEPLOYMENT_TARGET", ""),
        "build_numbers_in_project": xcode.read_build_numbers(pbxproj) if os.path.exists(pbxproj) else [],
        "asc_key_configured": cfg.has_asc_key(),
        "config_file": cfg.config_path if os.path.exists(cfg.config_path) else "",
        "env_file": cfg.env_path if os.path.exists(cfg.env_path) else "",
    }
    if not args.json:
        report.say("")
        width = max(len(k) for k in data)
        for key, value in data.items():
            report.say("  %-*s  %s" % (width, key, report.dim(str(value) or "—")))
    return ok("%s %s (%s)" % (cfg.app_name, data["marketing_version"], data["bundle_id"]), data=data)


def cmd_bump(cfg: config.Config, args: argparse.Namespace) -> Result:
    pbxproj = os.path.join(cfg.xcodeproj, "project.pbxproj")
    if not os.path.exists(pbxproj):
        return fail("No project.pbxproj at %s" % pbxproj)
    current = xcode.read_build_numbers(pbxproj)
    if not current:
        return fail("CURRENT_PROJECT_VERSION is not set in the project",
                    "Set a build number in Xcode (target → General → Build) once, then this "
                    "tool can advance it.")
    value = args.value or xcode.next_build_number(current[0])
    count = xcode.write_build_number(pbxproj, value)
    return ok("Build number %s → %s" % (", ".join(sorted(set(current))), value),
              "Rewritten in %d build configuration%s." % (count, "" if count == 1 else "s"),
              data={"previous": current, "build_number": value, "configurations": count})


def cmd_auth(cfg: config.Config, args: argparse.Namespace) -> Result:
    from . import auth
    sub = getattr(args, "auth_command", None)
    if sub == "import":
        return auth.import_key(cfg, args.p8)
    if sub == "set-issuer":
        return auth.set_issuer(cfg, args.issuer)
    return auth.show(cfg)


def cmd_selftest(cfg: config.Config, args: argparse.Namespace) -> Result:
    import unittest
    loader = unittest.TestLoader()
    suite = loader.discover(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tests"),
                            top_level_dir=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    runner = unittest.TextTestRunner(stream=sys.stderr, verbosity=0 if args.json else 2)
    result = runner.run(suite)
    data = {"run": result.testsRun, "failures": len(result.failures), "errors": len(result.errors)}
    if result.wasSuccessful():
        return ok("%d tests passed" % result.testsRun, data=data)
    return fail("%d of %d tests failed" % (len(result.failures) + len(result.errors), result.testsRun),
                data=data)


def cmd_status(cfg: config.Config, args: argparse.Namespace) -> Result:
    from . import status
    return status.run(cfg)


COMMANDS: Dict[str, Callable[[config.Config, argparse.Namespace], Result]] = {
    "info": cmd_info,
    "status": cmd_status,
    "bump": cmd_bump,
    "auth": cmd_auth,
    "selftest": cmd_selftest,
}


def main(argv: List[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help(sys.stderr)
        return report.EXIT_USAGE

    cfg = config.load(xcodeproj=args.project, scheme=args.scheme,
                      configuration=args.configuration)
    if not cfg.xcodeproj and args.command not in ("auth", "selftest"):
        return report.emit(
            fail("No .xcodeproj found",
                 "Searched %s and its Apps/ directory. Pass --project if it is elsewhere."
                 % cfg.root),
            args.json, args.command)

    try:
        result = COMMANDS[args.command](cfg, args)
    except KeyboardInterrupt:
        return report.emit(fail("Interrupted"), args.json, args.command)
    return report.emit(result, args.json, args.command)
