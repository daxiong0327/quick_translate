#!/usr/bin/env python3
"""Build a portable app and the native macOS Continue / Install wizard."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.1.0"
NAME = f"Quick-Translate-{VERSION}-arm64.pkg"
PACKAGE_ID = "local.quicktranslate.installer"


def build_installer(app, folder):
    payload = folder / "payload"
    payload.mkdir()
    shutil.copytree(app, payload / app.name)
    # Otherwise Installer may find the development app and update it instead of /Applications.
    components = folder / "components.plist"
    components.write_bytes(plistlib.dumps([{
        "RootRelativeBundlePath": app.name,
        "BundleIsRelocatable": False,
        "BundleIsVersionChecked": True,
        "BundleHasStrictIdentifier": True,
        "BundleOverwriteAction": "upgrade",
    }]))
    component = folder / "QuickTranslate.pkg"
    subprocess.run(["/usr/bin/pkgbuild", "--root", str(payload), "--component-plist", str(components),
                    "--identifier", PACKAGE_ID, "--version", VERSION,
                    "--install-location", "/Applications", str(component)], check=True)
    requirements = folder / "requirements.plist"
    requirements.write_bytes(plistlib.dumps({"os": ["13.0"], "arch": ["arm64"]}))
    distribution = folder / "Distribution.xml"
    subprocess.run(["/usr/bin/productbuild", "--synthesize", "--product", str(requirements),
                    "--package", str(component), str(distribution)], check=True)
    tree = ET.parse(distribution)
    root = tree.getroot()
    ET.SubElement(root, "title").text = "Quick Translate"
    options = root.find("options")
    options.set("customize", "never")
    options.set("allow-external-scripts", "false")
    ET.SubElement(root, "domains", enable_anywhere="false", enable_currentUserHome="false",
                  enable_localSystem="true")
    for page in ("welcome", "conclusion"):
        ET.SubElement(root, page, file=f"{page}.html", **{"mime-type": "text/html"})
    close = ET.SubElement(ET.SubElement(root, "pkg-ref", id=PACKAGE_ID), "must-close")
    ET.SubElement(close, "app", id="local.quicktranslate.app")
    ET.indent(tree, space="  ")
    tree.write(distribution, encoding="utf-8", xml_declaration=True)
    resources = folder / "resources"
    shutil.copytree(ROOT / "packaging", resources)
    destination = folder / NAME
    subprocess.run(["/usr/bin/productbuild", "--distribution", str(distribution),
                    "--package-path", str(folder), "--resources", str(resources), str(destination)], check=True)
    # Read through Apple's installer before replacing the last good downloadable artifact.
    subprocess.run(["/usr/sbin/installer", "-pkginfo", "-pkg", str(destination)], check=True)
    return destination


def package():
    subprocess.run(["/bin/sh", str(ROOT / "scripts/build-app.sh"), "--distribution"], cwd=ROOT,
                   env={**os.environ, "QT_BUILD_NUMBER": os.environ.get("QT_BUILD_NUMBER", "5")}, check=True)
    build = ROOT / "build"
    app = build / "distribution/Quick Translate.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if "QTEnvironmentFile" in info or info["CFBundleShortVersionString"] != VERSION:
        raise ValueError("Distribution bundle contains a development path or the wrong version.")
    arch = subprocess.check_output(["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/QuickTranslate")], text=True).strip()
    if arch != "arm64":
        raise ValueError("This installer is labeled arm64 and must contain an arm64 executable.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix=".package-", dir=build) as temporary:
        folder = Path(temporary)
        temporary_package = build_installer(app, folder)
        digest = hashlib.sha256(temporary_package.read_bytes()).hexdigest()
        destination = build / NAME
        temporary_package.replace(destination)
        (build / (NAME + ".sha256")).write_text(f"{digest}  {NAME}\n")
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        (build / "package-build.json").write_text(json.dumps({
            "sourceRevision": revision, "version": VERSION, "build": info["CFBundleVersion"],
            "architecture": arch, "installer": NAME, "sha256": digest,
            "bytes": destination.stat().st_size, "appSigning": "fixed self-signed; not notarized",
            "installerSigning": "unsigned; no Developer ID Installer certificate",
        }, indent=2) + "\n")
    print(f"Installer: {destination}\nSHA256: {digest}")


if __name__ == "__main__":
    try:
        package()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
