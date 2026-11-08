#!/usr/bin/env python3
"""Use installed Swift, with project-local fixes for two stale CLT files if present."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
compiler = Path(subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip())
prefix = compiler.parent.parent
manifest = prefix / "lib/swift/pm/ManifestAPI"
cache = root / ".build/toolchain-compatibility"
environment = os.environ.copy()


def compiler_line(path):
    return next((line for line in path.read_text().splitlines() if line.startswith("// swift-compiler-version:")), "")


mismatched = any(
    compiler_line(private) != compiler_line(Path(str(private).replace(".private.swiftinterface", ".swiftinterface")))
    for private in manifest.glob("*/*.private.swiftinterface")
    if Path(str(private).replace(".private.swiftinterface", ".swiftinterface")).exists()
)
if mismatched:
    local = cache / "libraries/ManifestAPI"
    shutil.copytree(manifest, local, dirs_exist_ok=True, ignore=shutil.ignore_patterns("*.private.swiftinterface"))
    environment["SWIFTPM_CUSTOM_LIBS_DIR"] = str(local.parent)

flags = []
old_map = prefix / "include/swift/module.modulemap"
new_map = prefix / "include/swift/bridging.modulemap"
def declarations(path):
    return re.sub(r"\s+", "", re.sub(r"//[^\n]*", "", path.read_text()))


if old_map.exists() and new_map.exists() and declarations(old_map) == declarations(new_map):
    cache.mkdir(parents=True, exist_ok=True)
    empty = cache / "empty.modulemap"
    empty.write_text("// Duplicate legacy module map hidden in this build only.\n")
    overlay = cache / "overlay.json"
    overlay.write_text(json.dumps({"version": 0, "roots": [{
        "type": "file", "name": str(old_map), "external-contents": str(empty)
    }]}))
    flags = ["-Xswiftc", "-vfsoverlay", "-Xswiftc", str(overlay), "-Xcc", "-ivfsoverlay", "-Xcc", str(overlay)]

arguments = sys.argv[1:]
if not arguments or arguments[0] not in {"build", "test", "run"}:
    sys.exit("Usage: python3 scripts/swift-tool.py build|test|run [SwiftPM arguments]")
if arguments[0] == "run":
    arguments = [arguments[0], *flags, *arguments[1:]]
else:
    arguments += flags
os.chdir(root)
os.execve(str(compiler), [str(compiler), *arguments], environment)
