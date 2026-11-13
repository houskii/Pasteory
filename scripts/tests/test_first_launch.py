import errno
import importlib.util
import json
import os
from pathlib import Path
import pty
import plistlib
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("prepare_first_launch", Path(__file__).parents[1] / "prepare_first_launch.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
METADATA = {"EXPECTED_VERSION": "0.1.31", "EXPECTED_BUILD": "36", "EXPECTED_CDHASH": "a" * 40,
            "EXPECTED_REQUIREMENT": 'identifier "app.pasteory.Pasteory" and certificate leaf = H"1234"'}


def run_interactively(helper, answer):
    master, slave = pty.openpty()
    process = subprocess.Popen(["/bin/bash", "-p", str(helper)], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    os.write(master, answer.encode() + b"\n")
    output = bytearray()
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    data = os.read(master, 4096)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                output.extend(data)
            elif process.poll() is not None:
                break
        process.wait(timeout=1)
        return process.returncode, output.decode(errors="replace")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


class FirstLaunchGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pasteory helper ")
        self.root = Path(self.temporary.name)
        self.app = self.root / "Pasteory's app.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").touch()
        self.log = self.root / "calls.jsonl"
        self.state = self.root / "state.json"
        self.settings = {"identifier": "app.pasteory.Pasteory", "version": "0.1.31", "build": "36", "hash": "a" * 40, "valid": True}
        stub = self.root / "mac tool"
        stub.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
state=json.loads(pathlib.Path(STATE_PATH).read_text())
arguments=sys.argv[1:]
name=pathlib.Path(sys.argv[0]).name
if name=='plist':
 key=arguments[1].split(':')[-1]
 print(state[{'CFBundleIdentifier':'identifier','CFBundleShortVersionString':'version','CFBundleVersion':'build'}[key]])
elif name=='codesign':
 if '--verify' in arguments:
  requirement=arguments[arguments.index('--test-requirement')+1]
  sys.exit(0 if state['valid'] and requirement.startswith('=') else 1)
 print('Executable=fixture\\nCDHash='+state['hash'],file=sys.stderr)
else:
 with pathlib.Path(LOG_PATH).open('a') as log: log.write(json.dumps([name,arguments])+'\\n')
'''.replace('STATE_PATH', repr(str(self.state))).replace('LOG_PATH', repr(str(self.log))))
        stub.chmod(0o755)
        self.commands = {}
        for key, name in [("CODESIGN", "codesign"), ("PLIST_BUDDY", "plist"), ("XATTR", "xattr"), ("OPEN", "open")]:
            executable = self.root / name
            executable.symlink_to(stub)
            self.commands[key] = str(executable)
        self.helper = self.root / module.HELPER_NAME
        self.helper.write_text(module.render_helper(METADATA, self.app, self.commands))
        self.helper.chmod(0o755)
        self.save_state()

    def tearDown(self):
        self.temporary.cleanup()

    def save_state(self):
        self.state.write_text(json.dumps(self.settings))

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_confirmation_changes_only_the_expected_app_then_opens_it(self):
        code, output = run_interactively(self.helper, "OPEN")
        self.assertEqual(code, 0, output)
        self.assertEqual(self.calls(), [["xattr", ["-drs", "com.apple.quarantine", str(self.app)]], ["open", [str(self.app)]]])

    def test_decline_and_noninteractive_invocation_make_no_changes(self):
        code, output = run_interactively(self.helper, "cancel")
        self.assertEqual(code, 0, output)
        result = subprocess.run(["/bin/bash", "-p", str(self.helper)], stdin=subprocess.DEVNULL, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_wrong_version_identifier_hash_or_signature_cannot_be_allowed(self):
        for field, value in [("version", "9.9.9"), ("build", "999"), ("identifier", "other.app"), ("hash", "b" * 40), ("valid", False)]:
            with self.subTest(field=field):
                original = self.settings[field]
                self.settings[field] = value
                self.save_state()
                code, _ = run_interactively(self.helper, "OPEN")
                self.assertNotEqual(code, 0)
                self.assertEqual(self.calls(), [])
                self.settings[field] = original
        self.save_state()

    def test_readonly_check_allows_a_bundle_path_but_cannot_launch_or_remove_flags(self):
        result = subprocess.run(["/bin/bash", "-p", str(self.helper), "--check-bundle", str(self.app)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        rejected = subprocess.run(["/bin/bash", "-p", str(self.helper), "--target", "/"], capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_symlink_target_is_rejected(self):
        link = self.root / "Linked.app"
        link.symlink_to(self.app)
        self.helper.write_text(module.render_helper(METADATA, link, self.commands))
        code, _ = run_interactively(self.helper, "OPEN")
        self.assertNotEqual(code, 0)
        self.assertEqual(self.calls(), [])

    def test_packaged_helper_has_fixed_target_and_correctly_quoted_constants(self):
        rendered = module.render_helper({**METADATA, "EXPECTED_VERSION": "a'b $(false)"})
        self.assertIn("TARGET_APP='/Applications/Pasteory.app'", rendered)
        self.assertIn("EXPECTED_VERSION='a'\\''b $(false)'", rendered)
        self.assertNotIn("sudo", rendered)
        self.assertNotIn("spctl", rendered)
        self.assertNotIn("@@", rendered)


@unittest.skipUnless(sys.platform == "darwin", "macOS-specific quarantine and codesign integration")
class NativeFirstLaunchTests(unittest.TestCase):
    def test_signed_copy_quarantine_is_removed_without_touching_an_external_file(self):
        source = module.ROOT / "dist/Pasteory.app"
        if not source.is_dir() and os.environ.get("GITHUB_ACTIONS") != "true":
            self.skipTest("A signed app is produced by the native packaging job")
        with tempfile.TemporaryDirectory(prefix="Pasteory first launch ") as temporary:
            root = Path(temporary)
            app = root / "Pasteory.app"
            if source.is_dir():
                shutil.copytree(source, app, symlinks=True)
            else:
                # The early CI check uses a small certificate-signed fixture; the later packaging
                # check repeats this test with the real app, including Sparkle and its symlinks.
                binary = app / "Contents/MacOS/Fixture"
                binary.parent.mkdir(parents=True)
                shutil.copyfile("/usr/bin/true", binary)
                binary.chmod(0o755)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "app.pasteory.Pasteory", "PasteoryBuildVariant": "production",
                    "CFBundleShortVersionString": "0.1.31", "CFBundleVersion": "36",
                    "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
                }))
                resources = app / "Contents/Resources"
                resources.mkdir()
                (resources / "fixture.txt").write_text("Fixture")
                (resources / "linked.txt").symlink_to("fixture.txt")
                identity = subprocess.check_output([str(module.ROOT / "scripts/ensure_local_signing_identity.sh")], text=True).strip()
                subprocess.run(["/usr/bin/xattr", "-cr", str(app)], check=True)
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, str(app)], check=True)
            outside = root / "unrelated.txt"
            outside.write_text("unrelated")
            token = "0081;66000000;Pasteory First Launch Test;"
            for target in [app, app / "Contents/Info.plist", outside]:
                subprocess.run(["/usr/bin/xattr", "-w", "com.apple.quarantine", token, str(target)], check=True)
            metadata = module.bundle_metadata(app)
            helper = root / module.HELPER_NAME
            helper.write_text(module.render_helper(metadata, app, {**module.COMMANDS, "OPEN": "/usr/bin/true"}))
            helper.chmod(0o755)
            code, output = run_interactively(helper, "OPEN")
            self.assertEqual(code, 0, output)
            for target in [app, app / "Contents/Info.plist"]:
                result = subprocess.run(["/usr/bin/xattr", "-p", "com.apple.quarantine", str(target)], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
            result = subprocess.run(["/usr/bin/xattr", "-p", "com.apple.quarantine", str(outside)], check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), token)
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
