#!/usr/bin/env python3
"""Inspect the actual PKG and launch its extracted app with isolated first-run settings."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check(installer):
    digest = hashlib.sha256(installer.read_bytes()).hexdigest()
    expected = installer.with_name(installer.name + ".sha256").read_text().split()
    require(expected == [digest, installer.name], "Installer checksum or filename does not match.")
    evidence = Path(tempfile.mkdtemp(prefix="package-check-", dir=ROOT / "build"))
    expanded = evidence / "expanded"
    subprocess.run(["/usr/sbin/pkgutil", "--expand-full", str(installer), str(expanded)], check=True)
    distribution = ET.parse(expanded / "Distribution").getroot()
    require(distribution.tag == "installer-gui-script", "A native Installer wizard is required.")
    require(distribution.findtext("title") == "Quick Translate", "Missing wizard title.")
    for page in ("welcome", "conclusion"):
        entry = distribution.find(page)
        require(entry is not None, f"Missing {page} page.")
        resource = expanded / "Resources" / entry.get("file", "")
        require(resource.read_bytes() == (ROOT / "packaging" / f"{page}.html").read_bytes(),
                f"The {page} page is missing or out of date.")
    options = distribution.find("options")
    require(options.get("hostArchitectures") == "arm64", "Wrong supported architecture.")
    require(options.get("customize") == "never", "Unexpected custom installation choices.")
    require(options.get("require-scripts") == "false" and options.get("allow-external-scripts") == "false",
            "Unexpected installer scripts.")
    require(distribution.find("volume-check/allowed-os-versions/os-version").get("min") == "13.0",
            "Missing macOS 13 requirement.")
    domains = distribution.find("domains")
    require(domains.attrib == {"enable_anywhere": "false", "enable_currentUserHome": "false",
                               "enable_localSystem": "true"}, "Unexpected installation domain.")
    require(distribution.find("pkg-ref/must-close/app").get("id") == "local.quicktranslate.app",
            "Updating must ask to close the running app.")
    components = list(expanded.glob("*.pkg"))
    require(len(components) == 1, "Expected only the application component.")
    component = components[0]
    metadata = ET.parse(component / "PackageInfo").getroot()
    require(metadata.get("identifier") == "local.quicktranslate.installer", "Wrong package identity.")
    require(metadata.get("install-location") == "/Applications", "Wrong installation destination.")
    require(metadata.get("relocatable") == "false" and len(metadata.find("relocate")) == 0,
            "Installer must not redirect updates to a development copy.")
    require(metadata.find("upgrade-bundle/bundle").get("id") == "local.quicktranslate.app",
            "Updates must replace the application bundle.")
    require(not any(p.name == "Scripts" for p in expanded.rglob("*")), "Unexpected installation scripts.")
    payload = component / "Payload"
    require([p.name for p in payload.iterdir()] == ["Quick Translate.app"], "Unexpected payload files.")
    app = payload / "Quick Translate.app"
    require((app / "Contents/Resources/LICENSE.txt").read_bytes() == (ROOT / "LICENSE").read_bytes(),
            "Missing MIT license in the installed application.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "local.quicktranslate.app", "Wrong application identity.")
    require("QTEnvironmentFile" not in info, "Development configuration path found in the release.")
    require(info["LSMinimumSystemVersion"] == "13.0", "App and installer system requirements differ.")
    require(metadata.get("version") == info["CFBundleShortVersionString"], "App and package versions differ.")
    require(info["CFBundleIconFile"] == "QuickTranslate" and
            (app / "Contents/Resources/QuickTranslate.icns").stat().st_size > 0, "Missing application icon.")
    require(not any(p.name.startswith(".env") or p.suffix in {".p12", ".pem", ".key", ".keychain-db"}
                    for p in expanded.rglob("*")), "Private configuration or signing material found.")
    arch = subprocess.check_output(["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/QuickTranslate")],
                                   text=True).strip()
    require(arch == "arm64", "App and installer architectures differ.")
    installed = evidence / "Applications/Quick Translate.app"
    installed.parent.mkdir()
    shutil.copytree(app, installed)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(installed)], check=True)
    choices = subprocess.check_output(["/usr/sbin/installer", "-showChoicesXML", "-pkg", str(installer),
                                       "-target", "/"])
    plistlib.loads(choices)
    (evidence / "choices.plist").write_bytes(choices)
    domains = subprocess.check_output(["/usr/sbin/installer", "-dominfo", "-pkg", str(installer)], text=True)
    require(domains.strip() == "LocalSystem", "System Installer rejected the installation domain.")
    subprocess.run([sys.executable, str(ROOT / "scripts/smoke-settings.py"),
                    "--application", str(installed), "--portable"], check=True)
    (evidence / "result.json").write_text(json.dumps({
        "result": "passed", "installer": installer.name, "sha256": digest,
        "wizardResources": "passed", "destinationAndNoRelocation": "passed",
        "systemInstallerChoices": "passed", "appSignatureAfterExtraction": "passed",
        "bundledIcon": "passed", "portableFirstSaveAndRestart": "passed",
        "configurationOutsideApp": "passed", "administratorInstallation": "not run",
        "scope": "extracted payload in isolated directories; no actual system install or real API request",
    }, indent=2) + "\n")
    print(f"PASS: installer checks. Evidence: {evidence / 'result.json'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installer", type=Path)
    args = parser.parse_args()
    try:
        check(args.installer.resolve(strict=True))
    except (OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"Installer check failed: {error}", file=sys.stderr)
        sys.exit(1)
