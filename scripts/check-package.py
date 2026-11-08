#!/usr/bin/env python3
"""Mount a DMG read-only, copy its app, verify it and exercise portable first-run settings."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def detach(mount):
    # Finder/metadata services can briefly retain a freshly mounted image after copying finishes.
    for attempt in range(5):
        result = subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], capture_output=True, text=True)
        if result.returncode == 0:
            return
        if result.returncode != 16 or attempt == 4:
            raise RuntimeError(f"Unable to detach test image (exit {result.returncode}): {mount}")
        time.sleep(1)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("image", type=Path)
args = parser.parse_args()
installer = args.image.resolve(strict=True)
digest = hashlib.sha256(installer.read_bytes()).hexdigest()
assert installer.with_name(installer.name + ".sha256").read_text().split()[0] == digest
evidence = Path(tempfile.mkdtemp(prefix="package-check-", dir=ROOT / "build"))
mount = evidence / "mounted"
mount.mkdir()
attached = False
try:
    subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount),
                    str(installer)], check=True)
    attached = True
    assert (mount / "Applications").is_symlink()
    assert (mount / "Applications").readlink() == Path("/Applications")
    assert (mount / "LICENSE.txt").is_file() and (mount / "安装说明.txt").is_file()
    app = mount / "Quick Translate.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "local.quicktranslate.app"
    assert "QTEnvironmentFile" not in info
    assert (app / "Contents/Resources/QuickTranslate.icns").stat().st_size > 0
    assert not any(p.name == ".env" or p.suffix in {".p12", ".pem", ".key", ".keychain-db"}
                   for p in app.rglob("*"))
    installed = evidence / "Applications/Quick Translate.app"
    installed.parent.mkdir()
    shutil.copytree(app, installed)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(installed)], check=True)
finally:
    if attached:
        detach(mount)
subprocess.run([sys.executable, str(ROOT / "scripts/smoke-settings.py"),
                "--application", str(installed), "--portable"], check=True)
(evidence / "result.json").write_text(json.dumps({
    "result": "passed", "installer": installer.name, "sha256": digest,
    "mountAndCopy": "passed", "signatureAfterCopy": "passed", "bundledIcon": "passed",
    "portableFirstSaveAndRestart": "passed", "configurationOutsideApp": "passed",
    "scope": "isolated installation and user directory; no real API request or Gatekeeper override",
}, indent=2) + "\n")
print(f"PASS: installer checks. Evidence: {evidence / 'result.json'}")
