#!/usr/bin/env python3
import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("updates", Path(__file__).with_name("update-release.py"))
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)


class UpdateReleaseTests(unittest.TestCase):
    def setUp(self):
        root = Path(".agents/tests")
        root.mkdir(parents=True, exist_ok=True)
        self.folder = Path(tempfile.mkdtemp(prefix="updates-", dir=root))
        (self.folder / "Contents").mkdir()
        self.plist = self.folder / "Contents/Info.plist"
        self.plist.write_bytes(plistlib.dumps({"CFBundleVersion": "1.0.0"}))

    def test_configuration_requires_signed_feed_and_explicit_install(self):
        updates.configure(self.folder, True, "https://example.com/appcast.xml", base64.b64encode(bytes(32)).decode())
        data = plistlib.loads(self.plist.read_bytes())
        self.assertTrue(data["SUEnableAutomaticChecks"])
        self.assertTrue(data["SURequireSignedFeed"])
        self.assertFalse(data["SUAllowsAutomaticUpdates"])
        self.assertFalse(data["SUAutomaticallyUpdate"])

    def test_insecure_feed_is_rejected_without_mutating_plist(self):
        before = self.plist.read_bytes()
        with self.assertRaises(ValueError):
            updates.configure(self.folder, True, "http://example.com/feed", "")
        self.assertEqual(before, self.plist.read_bytes())

    def test_disabled_rc_does_not_require_production_keys(self):
        updates.configure(self.folder, False, "", "")
        self.assertFalse(plistlib.loads(self.plist.read_bytes())["SpeakFlowUpdatesEnabled"])

    def test_appcast_escapes_notes_and_records_signed_archive_length(self):
        archive = self.folder / "update.zip"
        archive.write_bytes(b"fixture archive")
        feed = self.folder / "appcast.xml"
        updates.create_appcast(archive, "https://example.com/update.zip", "2.0.0", "Fix <text> & typing", base64.b64encode(bytes(64)).decode(), feed)
        item = ET.parse(feed).find("channel/item")
        self.assertEqual(item.find("description").text, "Fix <text> & typing")
        self.assertEqual(item.find("description").get(f"{{{updates.SPARKLE}}}format"), "plain-text")
        self.assertEqual(item.find("enclosure").get("length"), str(archive.stat().st_size))
        self.assertEqual(item.find(f"{{{updates.SPARKLE}}}version").text, "2.0.0")

    def test_rc_versions_cannot_enter_stable_feed(self):
        with self.assertRaises(ValueError):
            updates.create_appcast(self.plist, "https://example.com/update.zip", "2.0.0-rc.1", "", "", self.folder / "bad.xml")


if __name__ == "__main__":
    unittest.main()
