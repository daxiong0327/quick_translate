#!/usr/bin/env python3
"""Exercise real macOS signing on disposable app copies; never change TCC or call the API."""
import hashlib
import importlib.util
import json
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


def command(arguments, *, succeeds=True, env=None):
    result = subprocess.run(arguments, cwd=ROOT, capture_output=True, text=True, env=env, timeout=120)
    assert (result.returncode == 0) == succeeds, f"Unexpected exit status: {arguments[0]} ({result.returncode})"
    return result.stdout + result.stderr


def bundle_hash(application):
    digest = hashlib.sha256()
    for path in sorted(application.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(application)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def details(application):
    output = command(["/usr/bin/codesign", "-d", "-r-", "--verbose=4", str(application)])
    return {
        "cdhash": re.search(r"^CDHash=(.+)$", output, re.M)[1],
        "requirement": re.search(r"^designated => (.+)$", output, re.M)[1],
    }


def main():
    application = ROOT / "build/Quick Translate.app"
    original = bundle_hash(application)
    report = {}
    evidence = Path(tempfile.mkdtemp(prefix="signing-regression-", dir=ROOT / "build"))
    signer = [sys.executable, str(ROOT / "scripts/signing.py")]
    private = signing.DEFAULT_DIRECTORY
    before = {name: hashlib.sha256((private / name).read_bytes()).digest()
              for name in ["identity.json", "identity.p12", "certificate.pem", "password"]}
    search_list = command(["/usr/bin/security", "list-keychains", "-d", "user"])
    command(signer + ["setup"])
    assert all(hashlib.sha256((private / name).read_bytes()).digest() == value for name, value in before.items())
    report["repeatSetupPreservesIdentity"] = True

    # Public certificate only in the negative fixture; no private key copies enter the repo.
    with tempfile.TemporaryDirectory(prefix="quick-translate-signing-check-") as temporary:
        fixture = Path(temporary)
        missing = fixture / "missing"
        command(signer + ["--directory", str(missing), "check"], succeeds=False)
        assert not missing.exists()
        report["missingIdentityRejectedWithoutCreation"] = True
        shutil.copy2(private / "certificate.pem", fixture / "certificate.pem")
        signing.write_private(fixture / "identity.json", json.dumps({"schema": 1, "sha1": "0" * 40}))
        command(signer + ["--directory", str(fixture), "check"], succeeds=False)
        report["wrongCertificateRejected"] = True

        spec = importlib.util.spec_from_file_location("build_app", ROOT / "scripts/build-app.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        actual_directory = signing.DEFAULT_DIRECTORY
        signing.DEFAULT_DIRECTORY = missing
        try:
            try:
                builder.build()
                raise AssertionError("Build unexpectedly accepted missing identity")
            except signing.SigningError:
                pass
        finally:
            signing.DEFAULT_DIRECTORY = actual_directory
        assert original == bundle_hash(application)
        report["missingIdentityBuildPreservesExistingApp"] = True

    command(["/bin/sh", "scripts/build-app.sh"], succeeds=False,
            env={**os.environ, "QT_BUILD_NUMBER": "invalid"})
    assert original == bundle_hash(application)
    report["invalidBuildPreservesExistingApp"] = True

    # Exercise a failure after assembly, at the signing boundary that used to overwrite the live app.
    actual_run = builder.subprocess.run
    signing_failure_injected = False

    def fail_signing(arguments, *args, **kwargs):
        nonlocal signing_failure_injected
        if len(arguments) > 2 and str(arguments[1]).endswith("/signing.py") and arguments[2] == "sign":
            signing_failure_injected = True
            raise subprocess.CalledProcessError(1, arguments)
        return actual_run(arguments, *args, **kwargs)

    builder.subprocess.run = fail_signing
    try:
        try:
            builder.build()
            raise AssertionError("Expected injected signing failure")
        except subprocess.CalledProcessError:
            pass
    finally:
        builder.subprocess.run = actual_run
    assert signing_failure_injected, "Build failed before the intended signing-failure boundary"
    assert original == bundle_hash(application)
    report["signingFailurePreservesExistingApp"] = "passed: injected signing failure after real assembly"

    builds = []
    for number in [9001, 9002]:
        copy = evidence / f"build{number}.app"
        shutil.copytree(application, copy)
        plist = copy / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleVersion"] = str(number)
        plist.write_bytes(plistlib.dumps(info))
        command(signer + ["sign", str(copy)])
        builds.append((copy, details(copy)))
    assert builds[0][1]["cdhash"] != builds[1][1]["cdhash"]
    assert builds[0][1]["requirement"] == builds[1][1]["requirement"]
    for app, _ in builds:
        for _, other in builds:
            command(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + other["requirement"], str(app)])
    report["differentContentSameIdentityCrossVerification"] = [data for _, data in builds]

    with tempfile.TemporaryDirectory(prefix="quick-translate-signing-restore-") as temporary:
        restored = Path(temporary)
        for name in before:
            shutil.copy2(private / name, restored / name)
        try:
            command(signer + ["--directory", str(restored), "setup"])
            restored_app = evidence / "restored-identity.app"
            shutil.copytree(builds[0][0], restored_app)
            command(signer + ["--directory", str(restored), "sign", str(restored_app)])
            command(["/usr/bin/codesign", "--verify", "--strict", "-R",
                     "=" + builds[0][1]["requirement"], str(restored_app)])
            report["backupRestoresOriginalSigningIdentity"] = True
        finally:
            keychain = restored / "codesigning.keychain-db"
            if keychain.exists():
                signing.security(["delete-keychain", str(keychain)], "Remove disposable restored keychain")

    altered = evidence / "tampered.app"
    shutil.copytree(builds[0][0], altered)
    icon = altered / "Contents/Resources/QuickTranslate.icns"
    with icon.open("ab") as output:
        output.write(b"tampered")
    command(["/usr/bin/codesign", "--verify", "--strict", str(altered)], succeeds=False)
    report["tamperedResourceRejected"] = True

    wrong = evidence / "wrong-identifier.app"
    shutil.copytree(builds[1][0], wrong)
    plist = wrong / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info["CFBundleIdentifier"] = "test.unrelated.application"
    plist.write_bytes(plistlib.dumps(info))
    unchanged = bundle_hash(wrong)
    command(signer + ["sign", str(wrong)], succeeds=False)
    assert unchanged == bundle_hash(wrong)
    report["wrongBundleRejectedWithoutMutation"] = True
    assert search_list == command(["/usr/bin/security", "list-keychains", "-d", "user"])
    assert original == bundle_hash(application)
    report["keychainSearchListAndLiveAppUnchanged"] = True
    report["permissionRetention"] = "not-tested; requires real user authorization then replacement"
    (evidence / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: signing regression. Evidence: {evidence / 'result.json'}")


if __name__ == "__main__":
    main()
