import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.remote = self.root / "origin.git"
        self.assets = self.root / "github" / "assets"
        self.assets.mkdir(parents=True)
        self.gh_root = self.assets.parent
        tools = self.root / "tools"
        tools.mkdir()
        gh = tools / "gh"
        gh.write_text('''#!/usr/bin/env python3
import os, sys, pathlib, shutil
root = pathlib.Path(os.environ['FAKE_GH_ROOT'])
assets = root / 'assets'
a = sys.argv[1:]
command = a[1]
if command == 'view':
    if not (root / 'exists').exists(): sys.exit(1)
    print('\\n'.join(p.name for p in assets.iterdir()))
elif command in ['create','upload']:
    if command == 'create': (root / 'exists').touch()
    for name in a[3:]:
        if name.startswith('--'): break
        source = pathlib.Path(name)
        target = assets / source.name
        if target.exists(): sys.exit(2)
        shutil.copyfile(source, target)
elif command == 'download':
    if (root / 'fail-download').exists():
        (root / 'fail-download').unlink()
        sys.exit(22)
    name = a[a.index('--pattern') + 1]
    target = pathlib.Path(a[a.index('--dir') + 1]) / name
    shutil.copyfile(assets / name, target)
else: sys.exit(3)
''')
        gh.chmod(0o755)
        self.env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"], "FAKE_GH_ROOT": str(self.gh_root)}
        self.run_command(["git", "init", "--bare", str(self.remote)])
        self.run_command(["git", "init", "-b", "main"])
        self.run_command(["git", "config", "user.name", "Publication Test"])
        self.run_command(["git", "config", "user.email", "test@example.invalid"])
        (self.repo / "Config").mkdir()
        (self.repo / "Config/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.31"}))
        beta = self.repo / "release/beta"
        beta.mkdir(parents=True)
        (beta / "Pasteory-0.1.31-arm64.dmg").write_bytes(b"immutable package bytes")
        (beta / "appcast.xml").write_text("placeholder")
        (beta / "appcast-0.1.31.xml").write_text("signed appcast")
        scripts = self.repo / "scripts"
        scripts.mkdir()
        shutil.copyfile(Path(__file__).parents[1] / "publish_beta.sh", scripts / "publish_beta.sh")
        self.run_command(["git", "add", "."])
        self.run_command(["git", "commit", "-m", "Prepared release"])
        self.run_command(["git", "tag", "-a", "v0.1.31", "-m", "Release notes"])
        self.run_command(["git", "remote", "add", "origin", str(self.remote)])
        self.run_command(["git", "push", "--tags", "origin", "main"])

    def tearDown(self):
        self.temporary.cleanup()

    def run_command(self, command, check=True):
        return subprocess.run(command, cwd=self.repo, env=self.env, check=check, capture_output=True, text=True)

    def publish(self):
        return self.run_command(["bash", "scripts/publish_beta.sh", "v0.1.31"], check=False)

    def remote_feed(self):
        return self.run_command(["git", "--git-dir", str(self.remote), "show", "main:release/beta/appcast.xml"]).stdout

    def test_readback_failure_keeps_old_feed_and_retry_completes_same_package(self):
        (self.gh_root / "fail-download").touch()
        first = self.publish()
        self.assertNotEqual(first.returncode, 0)
        self.assertEqual(self.remote_feed(), "placeholder")
        second = self.publish()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.remote_feed(), "signed appcast")
        self.assertEqual((self.assets / "Pasteory-0.1.31-arm64.dmg").read_bytes(), b"immutable package bytes")

    def test_retry_adds_a_missing_checksum_without_replacing_existing_assets(self):
        first = self.publish()
        self.assertEqual(first.returncode, 0, first.stderr)
        checksum = self.assets / "Pasteory-0.1.31-arm64.dmg.sha256"
        expected = checksum.read_bytes()
        checksum.unlink()
        second = self.publish()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(checksum.read_bytes(), expected)

    def test_changed_existing_package_is_rejected_and_never_overwritten(self):
        first = self.publish()
        self.assertEqual(first.returncode, 0, first.stderr)
        package = self.assets / "Pasteory-0.1.31-arm64.dmg"
        package.write_bytes(b"changed outside the publisher")
        second = self.publish()
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(package.read_bytes(), b"changed outside the publisher")
