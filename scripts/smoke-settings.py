#!/usr/bin/env python3
"""Launch the built app twice with isolated settings; no GUI automation permissions required."""
import json
import argparse
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--application", type=Path, default=root / "build/Quick Translate.app")
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--translation", action="store_true")
mode.add_argument("--portable", action="store_true")
args = parser.parse_args()
application = args.application.resolve() / "Contents/MacOS/QuickTranslate"
folder = Path(tempfile.mkdtemp(prefix="quick-translate-smoke-", dir=root / "build"))
phases = ["translation"] if args.translation else ["portable-save", "portable-reload"] if args.portable else ["save", "reload"]
for phase in phases:
    subprocess.run([str(application), "--smoke-test", str(folder), phase], check=True, timeout=30)
    report = phase.removeprefix("portable-")
    assert json.loads((folder / f"{report}.json").read_text())["result"] == "passed"
configuration = folder / ".config/quick-translate/.env" if args.portable else folder / ".env"
assert configuration.stat().st_mode & 0o777 == 0o600
if args.portable:
    assert configuration.parent.stat().st_mode & 0o777 == 0o700
    assert not (folder / ".env").exists()
print(f"PASS: app smoke phases {', '.join(phases)}. Evidence: {folder}")
