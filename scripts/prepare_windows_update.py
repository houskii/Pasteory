"""Prepare a signed Windows index from the two portable ZIPs."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
ACCOUNT = "app.pasteory.Pasteory.updates"


def asset_entry(directory, version, architecture, notes):
    name = f"Pasteory-win-{architecture}.zip"
    archive = directory / name
    with zipfile.ZipFile(archive) as package:
        if "Pasteory.exe" not in package.namelist() or package.testzip() is not None:
            raise ValueError(f"Invalid portable package {archive}")
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    return {
        "version": version,
        "architecture": architecture,
        "downloadUrl": f"https://github.com/houskii/Pasteory/releases/download/windows-v{version}/{name}",
        "length": archive.stat().st_size,
        "sha256": digest,
        "notes": notes,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--packages", required=True, type=Path)
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--tools", required=True, type=Path, help="Sparkle bin directory")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", args.version):
        raise ValueError("Expected a three-component Windows version")
    public_key = subprocess.check_output(
        [str(args.tools / "generate_keys"), "--account", ACCOUNT, "-p"], text=True
    ).strip()
    if public_key != (ROOT / "Config/UpdatePublicKey.txt").read_text(encoding="utf-8-sig").strip():
        raise ValueError("The signing identity does not match the embedded update key")
    notes = args.notes.read_text(encoding="utf-8").strip()
    if len(notes) > 15000:
        raise ValueError("Update notes exceed the Windows index limit")
    releases = [asset_entry(args.packages, args.version, arch, notes) for arch in ("x64", "arm64")]
    payload = json.dumps({"formatVersion": 1, "releases": releases}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with tempfile.TemporaryDirectory(prefix="pasteory-windows-feed-") as temp:
        path = Path(temp) / "payload.json"
        path.write_bytes(payload)
        signature = subprocess.check_output(
            [str(args.tools / "sign_update"), "--account", ACCOUNT, "-p", str(path)], text=True
        ).strip()
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Invalid Ed25519 signature")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        "payload": base64.b64encode(payload).decode("ascii"),
        "signature": signature,
    }, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
