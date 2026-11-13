#!/usr/bin/env python3
"""Encrypt signing recovery material to a public certificate; restore only exact known files."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

SIGNING_FILES = ("PasteoryLocalBuild.p12", "PasteoryLocalBuild.pem", "keychain-password", "identity-sha1")
UPDATE_MEMBER = "updates/private-key"
EXPECTED_MEMBERS = {"metadata.json", UPDATE_MEMBER, *("signing/" + name for name in SIGNING_FILES)}
MAX_MEMBER_SIZE = 512 * 1024


def seal(signing_directory, update_key, certificate, output, version, public_key=None):
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        archive = temporary / "recovery.tar.gz"
        metadata = temporary / "metadata.json"
        metadata.write_text(json.dumps({"format": 1, "version": version, "updatePublicKey": public_key}) + "\n")
        sources = [(metadata, "metadata.json"), (update_key, UPDATE_MEMBER)]
        sources += [(signing_directory / name, "signing/" + name) for name in SIGNING_FILES]
        with tarfile.open(archive, "w:gz") as bundle:
            for source, name in sources:
                if not source.is_file() or source.is_symlink() or source.stat().st_size > MAX_MEMBER_SIZE:
                    raise ValueError(f"Invalid recovery input: {name}")
                bundle.add(source, arcname=name, recursive=False)
        encrypted = temporary / "recovery.cms"
        subprocess.run([
            "openssl", "cms", "-encrypt", "-binary", "-aes-256-gcm", "-in", str(archive),
            "-outform", "DER", "-out", str(encrypted), "-recip", str(certificate),
            "-keyopt", "rsa_padding_mode:oaep", "-keyopt", "rsa_oaep_md:sha256",
        ], check=True)
        output.write_bytes(encrypted.read_bytes())


def restore(encrypted, private_key, certificate, signing_directory, update_key, expected_public_key=None):
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / "recovery.tar.gz"
        subprocess.run([
            "openssl", "cms", "-decrypt", "-binary", "-inform", "DER", "-in", str(encrypted),
            "-recip", str(certificate), "-inkey", str(private_key), "-out", str(archive),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        with tarfile.open(archive, "r:gz") as bundle:
            members = bundle.getmembers()
            if len(members) != len(EXPECTED_MEMBERS) or {m.name for m in members} != EXPECTED_MEMBERS:
                raise ValueError("Unexpected recovery archive entries")
            contents = {}
            for member in members:
                if not member.isfile() or member.size > MAX_MEMBER_SIZE:
                    raise ValueError("Invalid recovery archive entry")
                contents[member.name] = bundle.extractfile(member).read()
        metadata = json.loads(contents["metadata.json"])
        if metadata.get("format") != 1:
            raise ValueError("Unknown recovery format")
        if expected_public_key is not None and metadata.get("updatePublicKey") != expected_public_key:
            raise ValueError("Recovery archive does not match the published update public key")
        signing_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        update_key.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        targets = [(signing_directory / name, contents["signing/" + name]) for name in SIGNING_FILES]
        targets.append((update_key, contents[UPDATE_MEMBER]))
        for path, data in targets:
            if path.is_symlink():
                raise ValueError("Refusing to overwrite a symbolic link")
            path.write_bytes(data)
            path.chmod(0o600)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["seal", "restore"])
    parser.add_argument("--signing-directory", type=Path, required=True)
    parser.add_argument("--update-key", type=Path, required=True)
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--encrypted", type=Path, required=True)
    parser.add_argument("--private-key", type=Path)
    parser.add_argument("--version", default="")
    parser.add_argument("--update-public-key", type=Path)
    args = parser.parse_args()
    public_key = args.update_public_key.read_text().strip() if args.update_public_key else None
    if args.operation == "seal":
        seal(args.signing_directory, args.update_key, args.certificate, args.encrypted, args.version, public_key)
    elif args.private_key:
        restore(args.encrypted, args.private_key, args.certificate, args.signing_directory, args.update_key, public_key)
    else:
        parser.error("restore requires --private-key")


if __name__ == "__main__":
    main()
