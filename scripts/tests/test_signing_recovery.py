import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("signing_recovery", Path(__file__).parents[1] / "signing_recovery.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.key = cls.root / "private.pem"
        cls.certificate = cls.root / "recipient.crt"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=Recovery Test", "-keyout", str(cls.key), "-out", str(cls.certificate),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_round_trip_keeps_secrets_encrypted_and_restores_private_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            secret = b"private signing material for test only"
            for name in module.SIGNING_FILES:
                (source / name).write_bytes(secret + name.encode())
            update = root / "update-key"
            update.write_bytes(secret)
            encrypted = root / "recovery.cms"
            module.seal(source, update, self.certificate, encrypted, "0.1.31")
            self.assertNotIn(secret, encrypted.read_bytes())
            target = root / "restored"
            restored_update = root / "restored-update"
            module.restore(encrypted, self.key, self.certificate, target, restored_update)
            self.assertEqual(restored_update.read_bytes(), secret)
            for name in module.SIGNING_FILES:
                self.assertEqual((target / name).read_bytes(), (source / name).read_bytes())
                self.assertEqual((target / name).stat().st_mode & 0o777, 0o600)

    def test_recovery_for_a_different_published_update_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            for name in module.SIGNING_FILES:
                (source / name).write_bytes(b"fixture")
            update = root / "update-key"
            update.write_bytes(b"fixture update private key")
            encrypted = root / "recovery.cms"
            module.seal(source, update, self.certificate, encrypted, "0.1.31", "original public key")
            target = root / "restored"
            with self.assertRaises(ValueError):
                module.restore(encrypted, self.key, self.certificate, target, root / "out-key", "another public key")
            self.assertFalse(target.exists())

    def test_tampered_ciphertext_is_rejected_before_restoring_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            for name in module.SIGNING_FILES:
                (source / name).write_bytes(os.urandom(100))
            update = root / "update-key"
            update.write_bytes(os.urandom(64))
            encrypted = root / "recovery.cms"
            module.seal(source, update, self.certificate, encrypted, "0.1.31")
            damaged = bytearray(encrypted.read_bytes())
            damaged[-1] ^= 1
            encrypted.write_bytes(damaged)
            target = root / "restored"
            with self.assertRaises(subprocess.CalledProcessError):
                module.restore(encrypted, self.key, self.certificate, target, root / "out-key")
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
