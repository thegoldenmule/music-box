"""The export options plist, and the plist edit `fix encryption` performs.

Both are places where being wrong is silent. Every key in the export options
exists because its default is wrong for a TestFlight build without saying so,
and the plist edit touches a hand-written source file whose comments are the
only record of why its keys are set there.
"""

from __future__ import annotations

import plistlib
import unittest

from shipkit import pipeline, preflight

PARTIAL_PLIST = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<!-- UIBackgroundModes is not expressible as a build setting: Xcode accepts
\t     INFOPLIST_KEY_UIBackgroundModes and silently drops it. -->
\t<key>UIBackgroundModes</key>
\t<array>
\t\t<string>audio</string>
\t</array>
</dict>
</plist>
"""


class ExportOptions(unittest.TestCase):
    def parsed(self, upload: bool = True, icloud: bool = True) -> dict:
        return plistlib.loads(pipeline.export_options_xml("TEAM123", upload, icloud).encode())

    def test_is_a_valid_plist(self) -> None:
        self.assertIsInstance(self.parsed(), dict)

    def test_method_is_stated_explicitly(self) -> None:
        # It defaults to `debugging`. Omitting it yields a development-signed
        # export that fails at upload with a confusing signing complaint.
        self.assertEqual(self.parsed()["method"], "app-store-connect")

    def test_does_not_use_the_deprecated_alias(self) -> None:
        self.assertNotEqual(self.parsed()["method"], "app-store")

    def test_build_number_management_is_off(self) -> None:
        # Defaults to YES, which means Xcode rewrites the build number during
        # upload — silently defeating whatever the pipeline just computed.
        self.assertIs(self.parsed()["manageAppVersionAndBuildNumber"], False)

    def test_signing_style_is_stated(self) -> None:
        # It normally inherits from the archive's signing identity, which is the
        # empty string on an unsigned archive — nothing to inherit.
        self.assertEqual(self.parsed()["signingStyle"], "automatic")

    def test_destination_follows_the_caller(self) -> None:
        self.assertEqual(self.parsed(upload=True)["destination"], "upload")
        self.assertEqual(self.parsed(upload=False)["destination"], "export")

    def test_icloud_environment_only_when_the_app_uses_icloud(self) -> None:
        self.assertEqual(self.parsed(icloud=True)["iCloudContainerEnvironment"], "Production")
        self.assertNotIn("iCloudContainerEnvironment", self.parsed(icloud=False))

    def test_team_is_carried_through(self) -> None:
        self.assertEqual(self.parsed()["teamID"], "TEAM123")


class AddPlistKey(unittest.TestCase):
    def test_inserts_before_the_closing_dict(self) -> None:
        out = preflight.add_plist_key(PARTIAL_PLIST, "ITSAppUsesNonExemptEncryption", "<false/>")
        parsed = plistlib.loads(out.encode())
        self.assertIs(parsed["ITSAppUsesNonExemptEncryption"], False)
        self.assertEqual(parsed["UIBackgroundModes"], ["audio"])

    def test_keeps_the_existing_comments(self) -> None:
        # plistlib and PlistBuddy both round-trip this file and delete every
        # comment in it. The comments are the only record of why a key is here
        # rather than expressed as a build setting.
        out = preflight.add_plist_key(PARTIAL_PLIST, "X", "<true/>")
        self.assertIn("silently drops it", out)

    def test_writes_its_own_comment(self) -> None:
        out = preflight.add_plist_key(PARTIAL_PLIST, "X", "<true/>", "because of a reason")
        self.assertIn("<!-- because of a reason -->", out)

    def test_is_idempotent(self) -> None:
        once = preflight.add_plist_key(PARTIAL_PLIST, "X", "<true/>")
        self.assertEqual(preflight.add_plist_key(once, "X", "<true/>"), once)

    def test_refuses_a_plist_it_cannot_place_a_key_in(self) -> None:
        with self.assertRaises(ValueError):
            preflight.add_plist_key("not a plist", "X", "<true/>")

    def test_multiline_comments_stay_inside_the_comment(self) -> None:
        out = preflight.add_plist_key(PARTIAL_PLIST, "X", "<true/>", "line one\nline two")
        self.assertTrue(plistlib.loads(out.encode())["X"])
        self.assertIn("line two", out)


if __name__ == "__main__":
    unittest.main()
