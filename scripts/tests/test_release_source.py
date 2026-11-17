import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("check_release_source", Path(__file__).parents[1] / "check_release_source.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.write("Config/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.1.54"}))
        self.write("Sources/Example.swift", "// previous source\n")
        self.commit("Previous release")
        self.git("tag", "v0.1.54")
        self.write("Config/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.1.55"}))
        self.write("Sources/Example.swift", "// reviewed source\n")
        self.source = self.commit("Reviewed source and version bump")
        self.sync()
        self.lookup = patch.object(module, "merged_pull_requests", side_effect=self.pulls).start()
        self.addCleanup(patch.stopall)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL).decode().strip()

    def write(self, name, content):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content if isinstance(content, bytes) else content.encode())

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD")

    def sync(self):
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def pulls(self, commit):
        return [{"number": 6, "merged_at": "2026-11-17T12:00:00Z", "merge_commit_sha": commit,
                 "base": {"ref": "main", "repo": {"full_name": module.REPOSITORY}}}]

    def test_clean_synced_source_with_merged_pr_can_release(self):
        self.assertEqual(module.check(self.root), (self.source, [6]))
        self.lookup.assert_called_once_with(self.source)

    def test_staged_source_is_rejected_before_contacting_github(self):
        self.write("Sources/Example.swift", "// unreviewed source\n")
        self.git("add", "Sources/Example.swift")
        with self.assertRaisesRegex(ValueError, "暂存的源码"):
            module.check(self.root)
        self.lookup.assert_not_called()

    def test_local_commit_ahead_of_remote_is_rejected(self):
        self.write("Sources/Example.swift", "// local only\n")
        self.commit("Not on remote")
        with self.assertRaisesRegex(ValueError, "完全一致"):
            module.check(self.root)
        self.lookup.assert_not_called()

    def test_unstaged_and_untracked_changes_are_rejected(self):
        self.write("Sources/Example.swift", "// unstaged\n")
        with self.assertRaisesRegex(ValueError, "未暂存"):
            module.check(self.root)
        self.git("restore", "Sources/Example.swift")
        self.write("private-data.txt", "not for release")
        with self.assertRaisesRegex(ValueError, "未跟踪"):
            module.check(self.root)

    def test_missing_unmerged_or_wrong_base_pr_is_rejected(self):
        for invalid in [[], [{**self.pulls(self.source)[0], "merged_at": None}],
                        [{**self.pulls(self.source)[0], "base": {"ref": "other"}}],
                        [{**self.pulls(self.source)[0], "base": {"ref": "main", "repo": {"full_name": "other/Pasteory"}}}],
                        [{**self.pulls(self.source)[0], "merge_commit_sha": "0" * 40}]]:
            with self.subTest(pr=invalid):
                self.lookup.side_effect = None
                self.lookup.return_value = invalid
                with self.assertRaisesRegex(ValueError, "没有已合入 main 的 PR"):
                    module.check(self.root)

    def test_later_direct_source_push_cannot_hide_behind_an_earlier_pr(self):
        self.write("Sources/Example.swift", "// direct push after reviewed version\n")
        later = self.commit("Direct source push")
        self.sync()
        self.lookup.side_effect = lambda commit: self.pulls(commit) if commit == self.source else []
        with self.assertRaisesRegex(ValueError, later[:12]):
            module.check(self.root)

    def test_ci_prepared_public_metadata_and_encrypted_archive_are_allowed(self):
        for name in ["Config/UpdatePublicKey.txt", "Config/SigningRecoveryArchive.txt", "release/signing/recovery-0.1.55.cms"]:
            self.write(name, "prepared signing fixture")
            self.git("add", name)
        self.assertEqual(module.check(self.root), (self.source, [6]))
        self.write("release/signing/private.pem", "private key fixture")
        self.git("add", "release/signing/private.pem")
        with self.assertRaisesRegex(ValueError, "暂存的源码"):
            module.check(self.root)

    def test_published_feed_commit_does_not_need_a_source_pr(self):
        self.write("release/beta/appcast.xml", "generated feed fixture")
        head = self.commit("Publish signed update feed")
        self.sync()
        self.assertEqual(module.check(self.root), (head, [6]))
        self.lookup.assert_called_once_with(self.source)

    def test_merge_commit_checks_the_complete_change_against_its_main_parent(self):
        self.git("switch", "-c", "feature")
        self.write("Sources/Merged.swift", "// source on a feature branch\n")
        self.commit("Feature source")
        self.git("switch", "main")
        self.git("merge", "--no-ff", "feature", "-m", "Merge source PR")
        self.sync()
        merge = self.git("rev-parse", "HEAD")
        self.assertEqual(module.check(self.root), (merge, [6]))
        self.assertEqual([call.args[0] for call in self.lookup.call_args_list], [self.source, merge])


if __name__ == "__main__":
    unittest.main()
