#!/usr/bin/env python3
"""Fail before building if the fixed update public key cannot verify a real signature."""
import argparse
import base64
import hashlib
from pathlib import Path
import subprocess
import tempfile

ACCOUNT = "app.pasteory.Pasteory.updates"


def verify_signature(public_key, signature, data):
    public = base64.b64decode(public_key, validate=True)
    raw_signature = base64.b64decode(signature, validate=True)
    if len(public) != 32 or len(raw_signature) != 64:
        raise ValueError("Invalid Ed25519 public key or signature")
    # Standard Ed25519 SubjectPublicKeyInfo. Verification uses the committed
    # public key, independently of the signing tool's own key lookup.
    with tempfile.TemporaryDirectory(prefix="pasteory-signature-check-") as temporary:
        root = Path(temporary)
        (root / "public.der").write_bytes(bytes.fromhex("302a300506032b6570032100") + public)
        (root / "signature").write_bytes(raw_signature)
        (root / "payload").write_bytes(data)
        checked = subprocess.run([
            "openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(root / "public.der"),
            "-keyform", "DER", "-rawin", "-in", str(root / "payload"), "-sigfile", str(root / "signature"),
        ], capture_output=True)
        if checked.returncode:
            raise ValueError("The configured public key rejected the signing key's signature")


def check(tools, public_key_file):
    expected = public_key_file.read_text().strip()
    selected = subprocess.check_output([str(tools / "generate_keys"), "--account", ACCOUNT, "-p"], text=True).strip()
    if selected != expected:
        raise ValueError("Signing key does not match Config/UpdatePublicKey.txt; restore the existing key")
    with tempfile.TemporaryDirectory(prefix="pasteory-signing-preflight-") as temporary:
        probe = Path(temporary) / "probe.bin"
        probe.write_bytes(b"Pasteory release signing preflight\n")
        signature = subprocess.check_output([
            str(tools / "sign_update"), "--account", ACCOUNT, "-p", str(probe),
        ], text=True).strip()
        verify_signature(expected, signature, probe.read_bytes())
    return hashlib.sha256(base64.b64decode(expected, validate=True)).hexdigest()


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools", type=Path, default=root / ".build/artifacts/sparkle/Sparkle/bin")
    parser.add_argument("--public-key", type=Path, default=root / "Config/UpdatePublicKey.txt")
    args = parser.parse_args()
    print("Update signing preflight passed. Public key SHA-256: " + check(args.tools, args.public_key))
