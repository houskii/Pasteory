import base64
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("check_release_signing", Path(__file__).parents[1] / "check_release_signing.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.private = cls.root / "private.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(cls.private)],
                       check=True, capture_output=True)
        public = subprocess.check_output(["openssl", "pkey", "-in", str(cls.private), "-pubout", "-outform", "DER"])
        cls.public = base64.b64encode(public[-32:]).decode()
        cls.payload = b"Pasteory release signing preflight\n"
        (cls.root / "payload").write_bytes(cls.payload)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(cls.private), "-rawin",
                        "-in", str(cls.root / "payload"), "-out", str(cls.root / "signature")],
                       check=True, capture_output=True)
        cls.signature = base64.b64encode((cls.root / "signature").read_bytes()).decode()
        cls.configured = cls.root / "UpdatePublicKey.txt"
        cls.configured.write_text(cls.public)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_signature_is_verified_against_the_fixed_public_key(self):
        module.verify_signature(self.public, self.signature, self.payload)
        with self.assertRaises(ValueError):
            module.verify_signature(self.public, self.signature, self.payload + b"changed")
        with self.assertRaises(ValueError):
            module.verify_signature(base64.b64encode(bytes(32)).decode(), self.signature, self.payload)

    def test_preflight_rejects_a_different_or_missing_key(self):
        with patch.object(module.subprocess, "check_output", return_value="another public key"):
            with self.assertRaisesRegex(ValueError, "does not match"):
                module.check(self.root, self.configured)
        with patch.object(module.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "generate_keys")):
            with self.assertRaises(subprocess.CalledProcessError):
                module.check(self.root, self.configured)

    def test_signer_cannot_claim_a_public_key_and_return_an_invalid_signature(self):
        with patch.object(module.subprocess, "check_output", side_effect=[self.public, base64.b64encode(bytes(64)).decode()]):
            with self.assertRaisesRegex(ValueError, "rejected"):
                module.check(self.root, self.configured)

    def test_preflight_accepts_a_real_matching_signature(self):
        with patch.object(module.subprocess, "check_output", side_effect=[self.public, self.signature]):
            self.assertEqual(len(module.check(self.root, self.configured)), 64)


if __name__ == "__main__":
    unittest.main()
