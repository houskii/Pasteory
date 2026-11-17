#!/usr/bin/env python3
"""Require reviewed source on origin/main before building a public release."""

import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


REPOSITORY = "houskii/Pasteory"
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments]).decode().rstrip("\n")


def paths(root, *arguments):
    return set(filter(None, git(root, *arguments).split("\0")))


def generated(path):
    return path in {"Config/UpdatePublicKey.txt", "Config/SigningRecoveryArchive.txt"} or bool(
        re.fullmatch(rf"release/signing/recovery-{VERSION}\.cms", path)
        or re.fullmatch(rf"release/beta/Pasteory-{VERSION}-arm64\.dmg", path)
        or re.fullmatch(rf"release/beta/appcast(?:-{VERSION})?\.xml", path)
    )


def ancestor(root, earlier, later):
    return subprocess.run(
        ["git", "-C", str(root), "merge-base", "--is-ancestor", earlier, later],
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def merged_pull_requests(commit):
    pages = json.loads(subprocess.check_output([
        "gh", "api", "--paginate", "--slurp",
        f"repos/{REPOSITORY}/commits/{commit}/pulls?per_page=100",
    ]))
    return [pull for page in pages for pull in page]


def check(root):
    if git(root, "branch", "--show-current") != "main":
        raise ValueError("请先通过 PR 合入 main，再切换到 main 发布。")
    head = git(root, "rev-parse", "HEAD")
    if head != git(root, "rev-parse", "origin/main"):
        raise ValueError("本地 main 必须与 origin/main 完全一致；请先合并源码 PR 并同步主干。")
    if paths(root, "diff", "--name-only", "--no-renames", "-z"):
        raise ValueError("存在未暂存的改动；请先通过源码 PR 合并，再从干净的 main 发布。")
    if paths(root, "ls-files", "--others", "--exclude-standard", "-z"):
        raise ValueError("存在未跟踪的文件；请先整理工作区并通过源码 PR 合并。")
    version = plistlib.loads(git(root, "show", "HEAD:Config/Info.plist").encode())["CFBundleShortVersionString"]
    prepared_signing = {
        "Config/UpdatePublicKey.txt", "Config/SigningRecoveryArchive.txt",
        f"release/signing/recovery-{version}.cms",
    }
    pending_source = paths(root, "diff", "--cached", "--name-only", "--no-renames", "-z") - prepared_signing
    if pending_source:
        raise ValueError("发布不能夹带暂存的源码，请先提交 PR：" + ", ".join(sorted(pending_source)))

    baseline = subprocess.run(
        ["git", "-C", str(root), "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD"],
        check=False, capture_output=True, text=True,
    )
    # For the first release, the initial source tree must itself have a merged PR.
    if baseline.returncode == 0:
        commits = git(root, "rev-list", "--first-parent", "--reverse", f"{baseline.stdout.strip()}..HEAD").splitlines()
    else:
        commits = [head]
    reviewed = set()
    for commit in commits:
        parents = git(root, "rev-list", "--parents", "-n", "1", commit).split()[1:]
        if parents:
            changed = paths(root, "diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", parents[0], commit)
        else:
            changed = paths(root, "diff-tree", "--root", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", commit)
        if not any(not generated(path) for path in changed):
            continue
        for pull in merged_pull_requests(commit):
            base = pull.get("base", {})
            merge = pull.get("merge_commit_sha")
            if (pull.get("merged_at") and base.get("ref") == "main"
                    and base.get("repo", {}).get("full_name", "").lower() == REPOSITORY.lower()
                    and merge and ancestor(root, commit, merge) and ancestor(root, merge, head)):
                reviewed.add(pull["number"])
                break
        else:
            raise ValueError(f"源码提交 {commit[:12]} 没有已合入 main 的 PR；请先完成源码 PR，再发布安装包。")
    return head, sorted(reviewed)


if __name__ == "__main__":
    try:
        commit, pulls = check(Path(__file__).resolve().parents[1])
        print(f"已核对发布源码：{commit}；已合并 PR：{', '.join('#' + str(number) for number in pulls) or '仅生成的发布文件'}")
    except (ValueError, subprocess.CalledProcessError, KeyError, OSError) as error:
        print(f"发布源码检查失败：{error}", file=sys.stderr)
        sys.exit(1)
