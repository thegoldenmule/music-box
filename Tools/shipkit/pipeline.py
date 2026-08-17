"""The staged build: checklist → tests → archive → verify → export → verify → upload.

Two decisions shape this and both are deliberate departures from the obvious.

**The export writes an .ipa to disk and the upload sends that file.** The single
command everyone reaches for is `-exportArchive` with `destination: upload`,
which signs and uploads in one step — and leaves nothing to inspect. This repo's
rule is to verify the artifact rather than the settings, and that is only
possible if the artifact exists. So the export lands on disk, the entitlements
and Info.plist are read back out of it, and only then are those exact bytes
handed to `altool`. What gets uploaded is what got checked. (`--upload-with
xcodebuild` restores the single-step path for anyone who wants it.)

**The build number is a command-line override, not a file edit.** It wins over
the conditional `CURRENT_PROJECT_VERSION[sdk=…]` form that a regex cannot safely
rewrite, and a failed archive leaves no dirty project file behind. It is written
back into the project only after a successful upload, so the repo records what
actually shipped rather than what was attempted.

`manageAppVersionAndBuildNumber` is set to false because it defaults to **true**,
and true means Xcode rewrites the build number during upload — silently
defeating any bump the pipeline just computed.
"""

from __future__ import annotations

import dataclasses
import os
import shutil
from typing import Any, Dict, List, Optional

from . import classify, config, preflight, proc, verify, xcode
from .report import FAIL, Link, Result, blocked, fail, ok, say

APPS_LINK = Link("Open My Apps", "https://appstoreconnect.apple.com/apps")
TESTFLIGHT_APP = Link("TestFlight for iPhone", "https://apps.apple.com/app/testflight/id899247664")


def export_options_xml(team_id: str, upload: bool, icloud: bool) -> str:
    """The exportOptions plist.

    Every key here is written explicitly because the defaults are wrong for a
    TestFlight build in ways that do not announce themselves:

      `method` defaults to `debugging` — omit it and the export is quietly
      development-signed. (`app-store` is a deprecated alias; the current
      spelling is `app-store-connect`.)

      `manageAppVersionAndBuildNumber` defaults to YES, meaning Xcode rewrites
      the build number during upload.

      `signingStyle` normally inherits from the archive's own signing identity,
      which is the empty string on an unsigned archive — so there is nothing to
      inherit and it has to be stated.
    """
    lines = [
        "<key>method</key>", "<string>app-store-connect</string>",
        "<key>destination</key>", "<string>%s</string>" % ("upload" if upload else "export"),
        "<key>signingStyle</key>", "<string>automatic</string>",
        "<key>teamID</key>", "<string>%s</string>" % team_id,
        "<key>manageAppVersionAndBuildNumber</key>", "<false/>",
        "<key>uploadSymbols</key>", "<true/>",
    ]
    if icloud:
        # Only rewrites an entitlement that is already present; it cannot create
        # the container identifiers. Stated anyway, because "defaults to
        # Production for distribution signing" is a default worth not relying on.
        lines += ["<key>iCloudContainerEnvironment</key>", "<string>Production</string>"]
    body = "\n\t".join(lines)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n\t%s\n</dict>\n</plist>\n' % body)


@dataclasses.dataclass
class Stage:
    name: str
    result: Result
    log: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return {"name": self.name, "ok": self.result.ok, "title": self.result.title,
                "log": self.log}


class Run:
    """One pass through the stages, accumulating what happened."""

    def __init__(self, cfg: config.Config, args, upload: bool):
        self.cfg = cfg
        self.args = args
        self.upload = upload
        self.stages: List[Stage] = []
        self.facts: Optional[preflight.Facts] = None
        self.build_number = ""
        self.context: Dict[str, str] = {}
        # Set when the caller names an .ipa built by an earlier run; every stage
        # then works on that file rather than on whatever is in the export dir.
        self.ipa_override = ""

    # ── helpers ───────────────────────────────────────────────────────────────

    def log_path(self, name: str) -> str:
        return os.path.join(self.cfg.logs_dir, name + ".log")

    def auth_flags(self) -> List[str]:
        """API-key flags, when a key is configured.

        Passed to `archive` as well as to `-exportArchive`: on archive they
        authorise creating profiles and certificates, on export they authorise
        re-signing and the upload. Exact spelling matters — the ID is
        capitalised and `-authenticationKeyId` is not a flag."""
        creds = self.cfg.asc_credentials()
        if not (creds["key_id"] and creds["issuer_id"] and creds["key_path"]):
            return []
        return ["-authenticationKeyPath", creds["key_path"],
                "-authenticationKeyID", creds["key_id"],
                "-authenticationKeyIssuerID", creds["issuer_id"]]

    def secrets(self) -> List[str]:
        """Credential values to keep out of the logs.

        The .p8's contents never reach a command line, but its path, the key id
        and the issuer id all do — and a build log is a file people paste into
        issues. The child process still receives the real values."""
        creds = self.cfg.asc_credentials()
        return [creds["issuer_id"], creds["key_id"], creds["key_path"]]

    def record(self, name: str, result: Result, log: str = "") -> Result:
        self.stages.append(Stage(name, result, log))
        return result

    def data(self) -> Dict[str, Any]:
        return {"stages": [stage.as_dict() for stage in self.stages],
                "build_number": self.build_number,
                "build_dir": self.cfg.build_dir,
                "upload": self.upload}

    def failed(self, name: str, result: Result, log: str = "") -> Result:
        self.record(name, result, log)
        merged = dict(result.data)
        merged.update(self.data())
        merged["failed_stage"] = name
        return Result(False, result.title, result.guidance, result.links, merged, result.blocked)

    # ── stages ────────────────────────────────────────────────────────────────

    def stage_preflight(self) -> Optional[Result]:
        say("── preflight ──")
        self.facts = preflight.gather(self.cfg, offline=False)
        rows = preflight.rows_for(self.facts)
        failures = [row for row in rows if row.status == FAIL]
        for row in rows:
            if row.status != "ok":
                say(row.render())
        if self.args.skip_preflight:
            self.record("preflight", ok("Skipped"))
            return None
        blocking = [row for row in failures if row.id != "git"]
        if blocking:
            manual = all(row.manual and not row.fix for row in blocking)
            message = "Preflight failed: %s" % ", ".join(row.label for row in blocking)
            guidance = ("Each failing row above carries its steps; `Tools/ship fix <id>` handles "
                        "the repairable ones. --skip-preflight builds anyway.")
            result = (blocked(message, guidance) if manual else fail(message, guidance))
            return self.failed("preflight", result)
        dirty = next((row for row in rows if row.id == "git" and row.status != "ok"), None)
        if dirty and self.upload and not self.args.allow_dirty:
            return self.failed("preflight", fail(
                "The working tree has uncommitted changes",
                "A build uploaded from a dirty tree cannot be reproduced: the commit recorded "
                "against it is not the code that shipped. Commit first, or pass --allow-dirty."))
        self.record("preflight", ok("%d checks" % len(rows)))
        return None

    def stage_tests(self) -> Optional[Result]:
        if self.args.skip_tests:
            self.record("tests", ok("Skipped"))
            return None
        packages = sorted(
            os.path.join(self.cfg.root, "Packages", name)
            for name in os.listdir(os.path.join(self.cfg.root, "Packages"))
            if os.path.exists(os.path.join(self.cfg.root, "Packages", name, "Package.swift"))
        ) if os.path.isdir(os.path.join(self.cfg.root, "Packages")) else []
        if not packages:
            self.record("tests", ok("No packages to test"))
            return None
        say("")
        say("── tests (%d packages) ──" % len(packages))
        for package in packages:
            name = os.path.basename(package)
            result = proc.stream(["swift", "test", "--package-path", package],
                                 self.log_path("test-" + name), quiet=self.args.quiet,
                                 cwd=self.cfg.root)
            if not result.ok:
                diagnosis = classify.classify(result.out, self.context)
                return self.failed("tests", fail(
                    "%s tests failed" % name,
                    "%s\n\nFull log: %s" % (diagnosis.guidance, result.log)), result.log)
        self.record("tests", ok("%d packages green" % len(packages)))
        return None

    def stage_build_number(self) -> Optional[Result]:
        assert self.facts is not None
        if self.args.build_number:
            self.build_number = self.args.build_number
        elif self.args.no_bump:
            self.build_number = self.facts.build_number
        else:
            self.build_number = preflight.next_build_number(self.facts)
        self.record("build_number", ok("Build %s" % self.build_number))
        say("")
        say("── build number %s (was %s) ──" % (self.build_number, self.facts.build_number))
        return None

    def stage_archive(self) -> Optional[Result]:
        assert self.facts is not None
        archive = os.path.join(self.cfg.build_dir, self.cfg.app_name + ".xcarchive")
        if os.path.isdir(archive):
            shutil.rmtree(archive)
        os.makedirs(self.cfg.build_dir, exist_ok=True)
        argv = [
            "xcodebuild", "archive",
            "-project", self.cfg.xcodeproj,
            "-scheme", self.cfg.scheme,
            "-configuration", self.cfg.configuration,
            "-destination", "generic/platform=iOS",
            "-archivePath", archive,
            "-allowProvisioningUpdates",
        ] + self.auth_flags() + ["CURRENT_PROJECT_VERSION=" + self.build_number]
        if self.args.unsigned_archive:
            # Sidesteps needing a *development* profile, which Apple will not
            # mint for a team with no registered devices. The cost is real and
            # is why the post-export entitlements check is a hard gate: no
            # signing means no .xcent, so the entitlements file never enters the
            # archive and export has nothing to carry forward.
            argv += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]
        say("")
        say("── archive ──")
        result = proc.stream(argv, self.log_path("archive"), quiet=self.args.quiet,
                             secrets=self.secrets())
        if not result.ok:
            diagnosis = classify.classify(result.out, self.context)
            return self.failed("archive", fail(
                diagnosis.title, "%s\n\nFull log: %s" % (diagnosis.guidance, result.log),
                links=diagnosis.links, blocked=diagnosis.manual), result.log)
        self.record("archive", ok(archive), result.log)
        return None

    def stage_verify_archive(self) -> Optional[Result]:
        assert self.facts is not None
        archive = os.path.join(self.cfg.build_dir, self.cfg.app_name + ".xcarchive")
        say("")
        say("── verify the archive ──")
        result = verify.run(self.cfg, archive, self.facts.settings, self.build_number)
        if not result.ok:
            return self.failed("verify_archive", result)
        self.record("verify_archive", result)
        return None

    def stage_export(self) -> Optional[Result]:
        assert self.facts is not None
        archive = os.path.join(self.cfg.build_dir, self.cfg.app_name + ".xcarchive")
        export_dir = os.path.join(self.cfg.build_dir, "export")
        if os.path.isdir(export_dir):
            shutil.rmtree(export_dir)
        os.makedirs(export_dir, exist_ok=True)
        options = os.path.join(self.cfg.build_dir, "ExportOptions.plist")
        single_step = self.upload and self.args.upload_with == "xcodebuild"
        with open(options, "w", encoding="utf-8") as handle:
            handle.write(export_options_xml(
                self.facts.team_id, single_step,
                icloud=any(key.startswith("com.apple.developer.icloud")
                           for key in self.facts.entitlements)))
        argv = ["xcodebuild", "-exportArchive",
                "-archivePath", archive,
                "-exportOptionsPlist", options,
                "-exportPath", export_dir,
                "-allowProvisioningUpdates"] + self.auth_flags()
        say("")
        say("── export%s ──" % (" and upload" if single_step else ""))
        result = proc.stream(argv, self.log_path("export"), quiet=self.args.quiet,
                             secrets=self.secrets())
        if not result.ok:
            diagnosis = classify.classify(result.out, self.context)
            guidance = "%s\n\nFull log: %s" % (diagnosis.guidance, result.log)
            bundle = classify.distribution_log_bundle(result.out)
            if bundle and diagnosis.id != "unknown":
                guidance += ("\nxcodebuild's own export logs: %s\n"
                             "(IDEDistribution.verbose.log names the failing step.)" % bundle)
            return self.failed("export", fail(diagnosis.title, guidance, links=diagnosis.links,
                                              blocked=diagnosis.manual), result.log)
        self.record("export", ok(export_dir), result.log)
        return None

    def exported_ipa(self) -> str:
        if self.ipa_override:
            return self.ipa_override
        export_dir = os.path.join(self.cfg.build_dir, "export")
        if not os.path.isdir(export_dir):
            return ""
        found = [os.path.join(export_dir, name) for name in sorted(os.listdir(export_dir))
                 if name.endswith(".ipa")]
        return found[0] if found else ""

    def stage_verify_export(self) -> Optional[Result]:
        assert self.facts is not None
        ipa = self.exported_ipa()
        if not ipa:
            if self.upload and self.args.upload_with == "xcodebuild":
                # destination: upload does not reliably leave a file behind.
                self.record("verify_export", ok("Skipped — nothing was written to disk"))
                say("")
                say("  note: --upload-with xcodebuild uploads without leaving an artifact, so "
                    "the bytes Apple received were never read back.")
                return None
            return self.failed("verify_export", fail(
                "The export produced no .ipa",
                "Nothing landed in %s. The export log is the place to look."
                % os.path.join(self.cfg.build_dir, "export")))
        say("")
        say("── verify the export ──")
        result = verify.run(self.cfg, ipa, self.facts.settings, self.build_number)
        if not result.ok:
            return self.failed("verify_export", result)
        self.record("verify_export", result)
        return None

    def stage_upload(self) -> Optional[Result]:
        if not self.upload:
            return None
        if self.args.upload_with == "xcodebuild":
            self.record("upload", ok("Uploaded by the export stage"))
            return None
        ipa = self.exported_ipa()
        creds = self.cfg.asc_credentials()
        if not (creds["key_id"] and creds["issuer_id"] and creds["key_path"]):
            return self.failed("upload", blocked(
                "Uploading needs an App Store Connect API key",
                "The .ipa is built, signed and verified at %s — nothing is lost.\n"
                "  Tools/ship auth import ~/Downloads/AuthKey_<KEYID>.p8\n"
                "  Tools/ship auth set-issuer <uuid>\n"
                "Then `Tools/ship upload` sends this same file.\n"
                "Or upload it through Xcode's Organizer by hand." % ipa))
        # altool finds the .p8 by searching a fixed set of directories; naming
        # the one the key actually lives in is unambiguous and works wherever
        # the credentials came from.
        environment = dict(os.environ)
        environment["API_PRIVATE_KEYS_DIR"] = os.path.dirname(creds["key_path"])
        argv = ["xcrun", "altool", "--upload-app", "-f", ipa, "--platform", "ios",
                "--api-key", creds["key_id"], "--api-issuer", creds["issuer_id"]]
        say("")
        say("── upload ──")
        result = proc.stream(argv, self.log_path("upload"), quiet=self.args.quiet, env=environment,
                             secrets=self.secrets())
        if not result.ok:
            diagnosis = classify.classify(result.out, self.context)
            return self.failed("upload", fail(
                diagnosis.title,
                "%s\n\nThe .ipa is still at %s — `Tools/ship upload` retries without rebuilding."
                "\n\nFull log: %s" % (diagnosis.guidance, ipa, result.log),
                links=diagnosis.links, blocked=diagnosis.manual), result.log)
        self.record("upload", ok("Uploaded %s" % os.path.basename(ipa)), result.log)
        return None

    def stage_record_build_number(self) -> None:
        """Write the shipped number back into the project.

        After the upload, never before: a failed release should leave no trace
        in the project file, and the number is only true once Apple has it."""
        if not self.upload or self.args.no_bump or self.args.build_number:
            return
        pbxproj = os.path.join(self.cfg.xcodeproj, "project.pbxproj")
        bump = xcode.write_build_number(pbxproj, self.build_number)
        if bump.conditional or not bump.count:
            say("  note: could not record build %s in the project file — set it by hand."
                % self.build_number)


def run(cfg: config.Config, args, upload: bool) -> Result:
    if not os.path.isdir(cfg.build_dir):
        os.makedirs(cfg.build_dir, exist_ok=True)
    pipeline = Run(cfg, args, upload)

    for stage in (pipeline.stage_preflight, pipeline.stage_tests):
        failure = stage()
        if failure is not None:
            return failure

    assert pipeline.facts is not None
    pipeline.context = {"bundle_id": pipeline.facts.bundle_id,
                        "team_id": pipeline.facts.team_id,
                        "key_id": cfg.asc_credentials()["key_id"]}

    for stage in (pipeline.stage_build_number, pipeline.stage_archive,
                  pipeline.stage_verify_archive, pipeline.stage_export,
                  pipeline.stage_verify_export, pipeline.stage_upload):
        failure = stage()
        if failure is not None:
            return failure

    pipeline.stage_record_build_number()

    if not upload:
        return ok("Signed .ipa exported",
                  "It is at %s, verified against what the project declares.\n"
                  "`Tools/ship upload` sends this same file to TestFlight."
                  % (pipeline.exported_ipa() or os.path.join(cfg.build_dir, "export")),
                  data=pipeline.data())
    return ok("Build %s uploaded to App Store Connect" % pipeline.build_number,
              "Apple processes it in a few minutes.\n"
              "  Tools/ship status      — has it finished, and can anyone install it\n"
              "Then: the TestFlight app on the phone, signed in with the same Apple ID.",
              data=pipeline.data(), links=[APPS_LINK, TESTFLIGHT_APP])


def upload_only(cfg: config.Config, args) -> Result:
    """Send an already-built .ipa without rebuilding.

    The case this exists for: an upload that failed on something that had
    nothing to do with the binary — an unaccepted agreement, a missing app
    record, a network drop. Rebuilding to retry would be twenty minutes spent
    proving the same bytes twice."""
    pipeline = Run(cfg, args, upload=True)
    pipeline.facts = preflight.gather(cfg, offline=True)
    pipeline.ipa_override = os.path.abspath(os.path.expanduser(args.ipa)) if args.ipa else ""
    ipa = pipeline.exported_ipa()
    if not ipa or not os.path.exists(ipa):
        return fail("No .ipa to upload",
                    "Looked in %s. Pass a path, or run `Tools/ship build` first."
                    % os.path.join(cfg.build_dir, "export"))
    app, _ = verify.resolve_app(ipa, os.path.join(cfg.build_dir, "verify"))
    built = xcode.read_plist(os.path.join(app, "Info.plist")) if app else {}
    pipeline.build_number = str(built.get("CFBundleVersion", ""))
    pipeline.context = {"bundle_id": pipeline.facts.bundle_id,
                        "team_id": pipeline.facts.team_id,
                        "key_id": cfg.asc_credentials()["key_id"],
                        "build_number": pipeline.build_number}
    failure = pipeline.stage_verify_export()
    if failure is not None:
        return failure
    failure = pipeline.stage_upload()
    if failure is not None:
        return failure
    return ok("Build %s uploaded to App Store Connect" % pipeline.build_number,
              "  Tools/ship status — has it finished processing, and can anyone install it",
              data=pipeline.data(), links=[APPS_LINK, TESTFLIGHT_APP])
