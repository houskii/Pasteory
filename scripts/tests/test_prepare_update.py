import argparse
import base64
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import plistlib
import tempfile
from unittest import mock
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("prepare_update", Path(__file__).parents[1] / "prepare_update.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleShortVersionString": "0.1.26", "CFBundleVersion": "31", "LSMinimumSystemVersion": "14.0"}
        self.signature = base64.b64encode(bytes(64)).decode()

    def feed(self, tag="v0.1.26-beta", notes="资料库 & 更新 <说明>\n第二行"):
        return module.appcast_bytes(self.info, tag, notes, "Pasteory-0.1.26-arm64.dmg", 123,
                                    self.signature, datetime(2026, 11, 13, tzinfo=timezone.utc))

    def test_feed_preserves_unicode_notes_and_escapes_xml(self):
        item = ET.fromstring(self.feed()).find("./channel/item")
        self.assertEqual(item.findtext("description"), "资料库 & 更新 <说明>\n第二行")
        self.assertEqual(item.find("description").attrib[f"{{{module.SPARKLE}}}descriptionFormat"], "plain-text")
        enclosure = item.find("enclosure").attrib
        self.assertEqual(enclosure["url"], "https://github.com/houskii/Pasteory/releases/download/v0.1.26-beta/Pasteory-0.1.26-arm64.dmg")
        self.assertEqual(enclosure[f"{{{module.SPARKLE}}}version"], "31")
        self.assertEqual(enclosure[f"{{{module.SPARKLE}}}shortVersionString"], "0.1.26")
        self.assertEqual(enclosure[f"{{{module.SPARKLE}}}edSignature"], self.signature)

    def test_tag_cannot_escape_the_release_download_path(self):
        for tag in ["../evil", "v1/../../main", "v1?redirect=elsewhere", "v1#anchor", ""]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.feed(tag=tag)

    def test_default_published_baseline_still_rejects_a_repeated_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Pasteory.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "app.pasteory.Pasteory", "PasteoryBuildVariant": "production",
                "CFBundleShortVersionString": "0.1.31", "CFBundleVersion": "36",
            }))
            baseline = root / "release/beta/appcast.xml"
            baseline.parent.mkdir(parents=True)
            baseline.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:version="36"/></item></channel></rss>')
            notes = root / "notes.md"
            notes.write_text("Release notes")
            args = argparse.Namespace(app=app, dmg=root / "Pasteory-0.1.31-arm64.dmg", notes=notes, previous_appcast=None)
            with mock.patch.object(module, "__file__", str(root / "scripts/prepare_update.py")):
                with self.assertRaisesRegex(ValueError, "Build"):
                    module.prepare(args)

    def test_invalid_signature_is_rejected(self):
        self.signature = base64.b64encode(bytes(32)).decode()
        with self.assertRaises(ValueError):
            self.feed()


if __name__ == "__main__":
    unittest.main()
