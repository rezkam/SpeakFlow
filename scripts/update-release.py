#!/usr/bin/env python3
"""Configure the bundled updater and generate a signed release appcast."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def https_url(value):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("Update URLs must be HTTPS without credentials or fragments")
    return value


def configure(app, enabled, feed, public_key):
    plist = Path(app) / "Contents/Info.plist"
    data = plistlib.loads(plist.read_bytes())
    data["SpeakFlowUpdatesEnabled"] = enabled
    data["SUEnableAutomaticChecks"] = True
    data["SUAutomaticallyUpdate"] = False
    data["SUAllowsAutomaticUpdates"] = False
    data["SUEnableSystemProfiling"] = False
    data["SUVerifyUpdateBeforeExtraction"] = True
    data["SURequireSignedFeed"] = True
    if enabled:
        https_url(feed)
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError("An Ed25519 public update key is required")
        data["SUFeedURL"] = feed
        data["SUPublicEDKey"] = public_key
    plist.write_bytes(plistlib.dumps(data))


def create_appcast(archive, download_url, version, notes, signature, output):
    https_url(download_url)
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Stable updates require a three-part numeric version")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("A valid Ed25519 archive signature is required")
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "SpeakFlow Updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"SpeakFlow {version}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "26.0"
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}descriptionFormat": "plain-text"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": download_url,
        "length": str(Path(archive).stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(root)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


def signed_appcast(args):
    signer = str(Path(args.tools) / "sign_update")
    key = os.environ.get("SPEAKFLOW_UPDATE_PRIVATE_KEY_FILE", "")
    if not key or not Path(key).is_file():
        raise ValueError("SPEAKFLOW_UPDATE_PRIVATE_KEY_FILE must identify the release signing key")
    subprocess.run(["swift", str(Path(__file__).with_name("verify-update-key.swift")), key],
                   check=True, capture_output=True)
    signing = [signer, "--ed-key-file", key]
    result = subprocess.run(signing + ["-p", args.archive], check=True, capture_output=True, text=True)
    signature = result.stdout.strip()
    create_appcast(args.archive, args.download_url, args.version, Path(args.notes).read_text(), signature, args.output)
    subprocess.run(signing + ["--disable-signing-warning", args.output], check=True, capture_output=True)
    subprocess.run(signing + ["--verify", args.output], check=True, capture_output=True)
    subprocess.run(signing + ["--verify", args.archive, signature], check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    config = commands.add_parser("configure")
    config.add_argument("app")
    config.add_argument("--enabled", action="store_true")
    config.add_argument("--feed", default="")
    appcast = commands.add_parser("appcast")
    for field in ("archive", "download-url", "version", "notes", "tools", "output"):
        appcast.add_argument("--" + field, required=True)
    args = parser.parse_args()
    try:
        if args.command == "configure":
            configure(args.app, args.enabled, args.feed, os.environ.get("SPEAKFLOW_UPDATE_PUBLIC_KEY", ""))
        else:
            signed_appcast(args)
    except (ValueError, OSError, subprocess.CalledProcessError):
        print("Update metadata failed validation or signing. Check the feed, versions, and signing key configuration.", file=sys.stderr)
        return 1
    print("Update metadata verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
