#!/usr/bin/env python3
"""Persistent, project-local-purpose signing identity; no API credentials are involved."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIRECTORY = Path.home() / "Library/Application Support/Quick Translate Signing"
IDENTIFIER = "local.quicktranslate.app"
NAME = "Quick Translate Local Signing"


class SigningError(Exception):
    pass


def run(arguments, *, input_text=None, label="Signing command"):
    result = subprocess.run(arguments, input=input_text, text=True, capture_output=True)
    if result.returncode:
        # Do not echo commands, input or security's output: those may contain a passphrase.
        raise SigningError(f"{label} failed (exit {result.returncode}).")
    return result.stdout + result.stderr


def security(arguments, label):
    # Interactive command input keeps passwords out of the process argument list.
    return run(["/usr/bin/security", "-i"], input_text=shlex.join(arguments) + "\n", label=label)


def private_file(path):
    if path.is_symlink() or not path.is_file():
        raise SigningError(f"Missing signing file: {path.name}. Run signing.py setup or restore your backup.")
    stat = path.stat()
    if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        raise SigningError(f"Signing file must be owned by you and private (0600): {path.name}.")
    return path


def write_private(path, value):
    with path.open("x") as output:
        os.chmod(path, 0o600)
        output.write(value)


def signing_directory(value):
    directory = Path(value).expanduser().absolute()
    if directory.is_symlink() or ROOT == directory.resolve() or ROOT in directory.resolve().parents:
        raise SigningError("Keep the signing identity outside the repository, in a private user directory.")
    if directory.exists():
        stat = directory.stat()
        if not directory.is_dir() or stat.st_uid != os.getuid() or stat.st_mode & 0o077:
            raise SigningError("Signing directory must be owned by you and private (0700).")
    return directory


def certificate_fingerprint(directory):
    output = run([
        "/usr/bin/openssl", "x509", "-in", str(private_file(directory / "certificate.pem")),
        "-noout", "-fingerprint", "-sha1",
    ], label="Read signing certificate")
    fingerprint = output.strip().split("=")[-1].replace(":", "").upper()
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
        raise SigningError("Invalid signing certificate fingerprint.")
    return fingerprint


def identity(directory, *, require_keychain=True):
    try:
        metadata = json.loads(private_file(directory / "identity.json").read_text())
        fingerprint = metadata["sha1"]
    except (ValueError, KeyError, TypeError):
        raise SigningError("Invalid signing metadata; restore the original identity backup.") from None
    if metadata.get("schema") != 1 or fingerprint != certificate_fingerprint(directory):
        raise SigningError("Signing identity does not match its recorded certificate; refusing to rotate it.")
    private_file(directory / "identity.p12")
    private_file(directory / "password")
    run(["/usr/bin/openssl", "x509", "-in", str(directory / "certificate.pem"),
         "-noout", "-checkend", "0"], label="Check certificate expiry")
    if require_keychain:
        keychain = private_file(directory / "codesigning.keychain-db")
        matches = security(["find-identity", "-p", "codesigning", str(keychain)], "Locate signing key")
        if fingerprint not in matches.upper():
            raise SigningError("The recorded private key is missing from the signing keychain; run setup to restore it.")
    return fingerprint


def detach_keychain(keychain):
    paths = shlex.split(security(["list-keychains", "-d", "user"], "Read keychain search list"))
    if str(keychain) in paths:
        security(["list-keychains", "-d", "user", "-s", *[p for p in paths if p != str(keychain)]],
                 "Remove dedicated keychain from general search list")


def setup(directory):
    os.umask(0o077)
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    metadata = directory / "identity.json"
    if not metadata.exists():
        if any(path.name != ".signing.lock" for path in directory.iterdir()):
            raise SigningError("Incomplete signing directory exists. Preserve it and restore its backup; no new key was generated.")
        password = secrets.token_hex(32)
        with tempfile.TemporaryDirectory(prefix=".create-", dir=directory) as temporary:
            temporary = Path(temporary)
            write_private(temporary / "password", password + "\n")
            config = temporary / "certificate.cnf"
            config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Quick Translate Local Signing
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
""")
            key = temporary / "private.pem"
            password_option = "file:" + str(temporary / "password")
            run(["/usr/bin/openssl", "genrsa", "-aes256", "-passout", password_option,
                 "-out", str(key), "3072"], label="Generate encrypted signing key")
            run(["/usr/bin/openssl", "req", "-new", "-x509", "-sha256", "-days", "3650",
                 "-key", str(key), "-passin", password_option, "-config", str(config),
                 "-out", str(temporary / "certificate.pem")], label="Create code-signing certificate")
            run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key),
                 "-in", str(temporary / "certificate.pem"), "-name", NAME,
                 "-passin", password_option, "-passout", "stdin",
                 "-out", str(temporary / "identity.p12")], input_text=password + "\n",
                label="Create encrypted identity backup")
            run(["/usr/bin/openssl", "pkcs12", "-in", str(temporary / "identity.p12"),
                 "-passin", password_option, "-noout"], label="Verify encrypted identity backup")
            write_private(temporary / "identity.json", json.dumps(
                {"schema": 1, "sha1": certificate_fingerprint(temporary)}, indent=2) + "\n")
            for name in ["password", "certificate.pem", "identity.p12", "identity.json"]:
                (temporary / name).rename(directory / name)

    fingerprint = identity(directory, require_keychain=False)
    password = private_file(directory / "password").read_text().strip()
    keychain = directory / "codesigning.keychain-db"
    if not keychain.exists():
        try:
            security(["create-keychain", "-p", password, str(keychain)], "Create dedicated signing keychain")
        finally:
            if keychain.exists():
                detach_keychain(keychain)
    private_file(keychain)
    security(["unlock-keychain", "-p", password, str(keychain)], "Unlock signing keychain")
    try:
        matches = security(["find-identity", "-p", "codesigning", str(keychain)], "Locate signing key")
        if fingerprint not in matches.upper():
            security(["import", str(directory / "identity.p12"), "-k", str(keychain),
                      "-P", password, "-T", "/usr/bin/codesign"], "Import fixed signing identity")
        security(["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password,
                  str(keychain)], "Grant Apple signing tools access to this dedicated key")
        identity(directory)
    finally:
        security(["lock-keychain", str(keychain)], "Lock signing keychain")
    print(f"Fixed signing identity ready: {fingerprint}\nPrivate backup directory: {directory}")


def requirement(fingerprint):
    return f'identifier "{IDENTIFIER}" and certificate leaf = H"{fingerprint}"'


def sign(directory, application):
    fingerprint = identity(directory)
    application = application.resolve(strict=True)
    with (application / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != IDENTIFIER:
        raise SigningError("Refusing to sign an application with a different bundle identifier.")
    password = private_file(directory / "password").read_text().strip()
    keychain = directory / "codesigning.keychain-db"
    security(["unlock-keychain", "-p", password, str(keychain)], "Unlock signing keychain")
    added = False
    try:
        paths = shlex.split(security(["list-keychains", "-d", "user"], "Read keychain search list"))
        added = str(keychain) not in paths
        # codesign also searches for the private key through the user search list.
        if added:
            security(["list-keychains", "-d", "user", "-s", *paths, str(keychain)],
                     "Temporarily expose dedicated signing keychain to codesign")
        run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain),
             "--identifier", IDENTIFIER, "--timestamp=none", "--requirements",
             "=designated => " + requirement(fingerprint), str(application)], label="Sign application")
        run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement(fingerprint),
             str(application)], label="Verify signed application and identity")
    finally:
        try:
            if added:
                detach_keychain(keychain)
        finally:
            security(["lock-keychain", str(keychain)], "Lock signing keychain")
    print("Signed and verified with the fixed self-signed identity.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", default=str(DEFAULT_DIRECTORY))
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("setup", help="Create once, or restore/reuse the existing identity")
    subcommands.add_parser("check", help="Verify the fixed identity exists; never create one")
    signing = subcommands.add_parser("sign", help="Sign an assembled Quick Translate.app")
    signing.add_argument("application", type=Path)
    args = parser.parse_args()
    try:
        directory = signing_directory(args.directory)
        if args.command == "setup":
            directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        if not directory.exists():
            raise SigningError("Signing identity is missing. Run python3 scripts/signing.py setup first.")
        lock_path = directory / ".signing.lock"
        with os.fdopen(os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "w") as lock:
            private_file(lock_path)
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.command == "setup":
                setup(directory)
            elif args.command == "check":
                print("Fixed signing identity available:", identity(directory))
            else:
                sign(directory, args.application)
    except (SigningError, OSError, ValueError) as error:
        print(f"Signing setup: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
