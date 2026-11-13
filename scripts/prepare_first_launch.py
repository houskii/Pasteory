#!/usr/bin/env python3
"""Bind the optional first-launch helper to the exact signed app being packaged."""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
HELPER_NAME = "Allow Pasteory.command"
COMMANDS = {
    "CODESIGN": "/usr/bin/codesign", "PLIST_BUDDY": "/usr/libexec/PlistBuddy",
    "XATTR": "/usr/bin/xattr", "OPEN": "/usr/bin/open",
}


def shell_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def bundle_metadata(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "app.pasteory.Pasteory" or info.get("PasteoryBuildVariant") != "production":
        raise ValueError("The helper is only for the production Pasteory app")
    subprocess.run([COMMANDS["CODESIGN"], "--verify", "--deep", "--strict", str(app)], check=True)
    details = subprocess.run([COMMANDS["CODESIGN"], "-d", "--verbose=4", str(app)], check=True, capture_output=True, text=True)
    requirements = subprocess.run([COMMANDS["CODESIGN"], "-d", "-r-", str(app)], check=True, capture_output=True, text=True)
    cdhash = re.search(r"^CDHash=([0-9a-fA-F]{40,64})$", details.stderr, re.MULTILINE)
    requirement = re.search(r"^designated => (.+)$", requirements.stdout + requirements.stderr, re.MULTILINE)
    if not cdhash or not requirement:
        raise ValueError("Cannot read the app's code hash and designated requirement")
    return {"EXPECTED_VERSION": info["CFBundleShortVersionString"], "EXPECTED_BUILD": info["CFBundleVersion"],
            "EXPECTED_CDHASH": cdhash[1], "EXPECTED_REQUIREMENT": requirement[1]}


def render_helper(metadata, target_app="/Applications/Pasteory.app", commands=None):
    # Alternate paths/tools are used by isolated tests; the packaging CLI fixes the production path.
    values = {**metadata, "TARGET_APP": str(target_app), **(commands or COMMANDS)}
    template = (ROOT / "Resources/FirstLaunch/Allow Pasteory.command.in").read_text()
    for key, value in values.items():
        template = template.replace("@@" + key + "@@", shell_quote(value))
    if re.search(r"@@[A-Z_]+@@", template):
        raise ValueError("Unfilled first-launch helper token")
    return template


def prepare(app, destination):
    metadata = bundle_metadata(app)
    destination.mkdir(parents=True, exist_ok=True)
    helper = destination / HELPER_NAME
    helper.write_text(render_helper(metadata))
    helper.chmod(0o755)
    shutil.copyfile(ROOT / "Resources/FirstLaunch/Read Me First.txt", destination / "Read Me First.txt")
    subprocess.run(["/bin/bash", "-n", str(helper)], check=True)
    subprocess.run([str(helper), "--check-bundle", str(app)], check=True)
    return helper


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    arguments = parser.parse_args()
    prepare(arguments.app, arguments.destination)
