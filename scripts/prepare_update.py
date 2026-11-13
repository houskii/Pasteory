#!/usr/bin/env python3
"""Prepare a signed GitHub release and appcast, without publishing either."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ACCOUNT = "app.pasteory.Pasteory.updates"
REPOSITORY = "https://github.com/houskii/Pasteory"


def verify_dmg_contents(app, dmg, info, verifier):
    """Make sure the asset being signed actually contains the app we inspected."""
    attached = plistlib.loads(subprocess.check_output([
        "hdiutil", "attach", "-readonly", "-nobrowse", "-plist", str(dmg)
    ]))
    mounts = [Path(e["mount-point"]) for e in attached["system-entities"] if "mount-point" in e]
    try:
        if len(mounts) != 1:
            raise ValueError("DMG 必须只包含一个可挂载卷")
        packaged_app = mounts[0] / "Pasteory.app"
        packaged_info = plistlib.loads((packaged_app / "Contents/Info.plist").read_bytes())
        if packaged_info != info:
            raise ValueError("DMG 内应用信息与待发布应用不一致，请重新打包")
        subprocess.run([str(verifier), str(packaged_app)], check=True)

        def cdhash(bundle):
            details = subprocess.run(["codesign", "-d", "--verbose=4", str(bundle)],
                                     check=True, capture_output=True, text=True)
            match = re.search(r"^CDHash=(.+)$", details.stderr, re.MULTILINE)
            if match is None:
                raise ValueError("无法读取应用签名摘要")
            return match.group(1)

        if cdhash(app) != cdhash(packaged_app):
            raise ValueError("DMG 内应用代码与待发布应用不一致，请重新打包")
    finally:
        for mount in mounts:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True)


def appcast_bytes(info, tag, notes, asset_name, size, signature, published_at):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
        raise ValueError("发布 tag 只能包含字母、数字、点、下划线和连字符")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("无效的 Ed25519 安装包签名")
    ET.register_namespace("sparkle", SPARKLE)
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Pasteory Beta"
    ET.SubElement(channel, "link").text = f"{REPOSITORY}/releases"
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Pasteory {info['CFBundleShortVersionString']}"
    ET.SubElement(item, "link").text = f"{REPOSITORY}/releases/tag/{tag}"
    ET.SubElement(item, "pubDate").text = format_datetime(published_at)
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}descriptionFormat": "plain-text"}).text = notes
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "enclosure", {
        "url": f"{REPOSITORY}/releases/download/{tag}/{asset_name}",
        "length": str(size), "type": "application/octet-stream",
        f"{{{SPARKLE}}}version": info["CFBundleVersion"],
        f"{{{SPARKLE}}}shortVersionString": info["CFBundleShortVersionString"],
        f"{{{SPARKLE}}}edSignature": signature,
        f"{{{SPARKLE}}}os": "macos",
    })
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def prepare(args):
    root = Path(__file__).resolve().parent.parent
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "app.pasteory.Pasteory" or info.get("PasteoryBuildVariant") != "production":
        raise ValueError("只能发布正式应用身份，不能发布 QA 包")
    if not re.fullmatch(r"\d+", info["CFBundleVersion"]):
        raise ValueError("CFBundleVersion 必须是递增的数字")
    expected_name = f"Pasteory-{info['CFBundleShortVersionString']}-arm64.dmg"
    if args.dmg.name != expected_name:
        raise ValueError(f"安装包名称应为 {expected_name}")
    notes = args.notes.read_text(encoding="utf-8").strip()
    if not notes:
        raise ValueError("更新说明不能为空")
    previous = args.previous_appcast or root / "release/beta/appcast.xml"
    if previous.exists():
        previous_items = ET.fromstring(previous.read_bytes()).findall("./channel/item/enclosure")
        builds = [int(e.attrib[f"{{{SPARKLE}}}version"]) for e in previous_items]
        if builds and int(info["CFBundleVersion"]) <= max(builds):
            raise ValueError("Build 必须大于当前发布索引中的所有版本")
    local_key = subprocess.check_output([
        str(args.tools / "generate_keys"), "--account", ACCOUNT, "-p"
    ], text=True).strip()
    if len(base64.b64decode(local_key, validate=True)) != 32 or local_key != info.get("SUPublicEDKey"):
        raise ValueError("安装包内公钥与发布钥匙串不一致，已拒绝发布")
    subprocess.run([str(root / "scripts/verify_signing.sh"), str(args.app)], check=True)
    subprocess.run(["hdiutil", "verify", str(args.dmg)], check=True)
    verify_dmg_contents(args.app, args.dmg, info, root / "scripts/verify_signing.sh")
    signature = subprocess.check_output([
        str(args.tools / "sign_update"), "--account", ACCOUNT, "-p", str(args.dmg)
    ], text=True).strip()
    args.output.mkdir(parents=True, exist_ok=True)
    feed = args.output / "appcast.xml"
    feed.write_bytes(appcast_bytes(info, args.tag, notes, args.dmg.name, args.dmg.stat().st_size,
                                   signature, datetime.now(timezone.utc)))
    subprocess.run([str(args.tools / "sign_update"), "--account", ACCOUNT, str(feed)], check=True)
    subprocess.run([str(args.tools / "sign_update"), "--account", ACCOUNT, "--verify", str(feed)], check=True)
    shutil.copyfile(args.notes, args.output / "release-notes.md")
    (args.output / "release-tag.txt").write_text(args.tag + "\n", encoding="utf-8")
    print(f"已生成并验证 {feed}；尚未上传安装包或修改线上更新索引。")


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=root / "dist/Pasteory.app")
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--tools", type=Path, default=root / ".build/artifacts/sparkle/Sparkle/bin")
    parser.add_argument("--output", type=Path, default=root / "dist/update")
    parser.add_argument("--previous-appcast", type=Path,
                        help="Previous published appcast; verification may use an isolated baseline")
    prepare(parser.parse_args())
