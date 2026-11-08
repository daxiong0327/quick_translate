#!/usr/bin/env python3
"""Assemble and verify in staging before replacing the local development app."""
import fcntl
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

import signing

ROOT = Path(__file__).resolve().parent.parent


def build(*, distribution=False):
    directory = signing.signing_directory(signing.DEFAULT_DIRECTORY)
    signing.identity(directory)  # Fail before compiling or touching the existing app.
    number = os.environ.get("QT_BUILD_NUMBER", "1")
    if not re.fullmatch(r"[1-9][0-9]{0,8}", number):
        raise ValueError("QT_BUILD_NUMBER must be a positive integer of at most nine digits.")
    build_directory = ROOT / "build"
    build_directory.mkdir(exist_ok=True)
    output_directory = build_directory / "distribution" if distribution else build_directory
    output_directory.mkdir(exist_ok=True)
    with (build_directory / ".build-app.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        swift = [sys.executable, str(ROOT / "scripts/swift-tool.py"), "build", "-c", "release"]
        subprocess.run(swift, cwd=ROOT, check=True)
        binary_directory = Path(subprocess.check_output(swift + ["--show-bin-path"], cwd=ROOT, text=True).strip())
        with tempfile.TemporaryDirectory(prefix=".app-staging-", dir=output_directory) as temporary:
            staging = Path(temporary)
            application = staging / "Quick Translate.app"
            executable = application / "Contents/MacOS/QuickTranslate"
            resources = application / "Contents/Resources"
            executable.parent.mkdir(parents=True)
            resources.mkdir()
            shutil.copy2(binary_directory / "QuickTranslate", executable)
            iconset = staging / "QuickTranslate.iconset"
            subprocess.run([str(executable), "--export-icon", str(iconset)], check=True)
            subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o",
                            str(resources / "QuickTranslate.icns")], check=True)
            info = {
                "CFBundleIdentifier": signing.IDENTIFIER,
                "CFBundleName": "Quick Translate",
                "CFBundleDisplayName": "Quick Translate",
                "CFBundleExecutable": "QuickTranslate",
                "CFBundleIconFile": "QuickTranslate",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": number,
                "LSMinimumSystemVersion": "13.0",
                "LSUIElement": True,
                "NSHighResolutionCapable": True,
            }
            if not distribution:
                info["QTEnvironmentFile"] = str(ROOT / ".env")
            (application / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run([sys.executable, str(ROOT / "scripts/signing.py"), "sign", str(application)], check=True)
            destination = output_directory / "Quick Translate.app"
            previous = staging / "previous.app"
            if destination.exists():
                destination.rename(previous)
            try:
                application.rename(destination)
            except OSError:
                if previous.exists():
                    previous.rename(destination)
                raise
    print(f"Built: {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--distribution", action="store_true", help="Use a portable per-user .env; omit the project path")
    args = parser.parse_args()
    try:
        build(distribution=args.distribution)
    except (signing.SigningError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Build stopped: {error}", file=sys.stderr)
        sys.exit(1)
