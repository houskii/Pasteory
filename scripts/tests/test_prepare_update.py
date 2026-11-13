import base64
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
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

    def test_invalid_signature_is_rejected(self):
        self.signature = base64.b64encode(bytes(32)).decode()
        with self.assertRaises(ValueError):
            self.feed()


if __name__ == "__main__":
    unittest.main()
