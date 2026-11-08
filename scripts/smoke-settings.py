#!/usr/bin/env python3
"""Launch the built app twice with isolated settings; no GUI automation permissions required."""
import json
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parent.parent
application = root / "build/Quick Translate.app/Contents/MacOS/QuickTranslate"
folder = Path(tempfile.mkdtemp(prefix="quick-translate-smoke-", dir=root / "build"))
phases = ["translation"] if "--translation" in sys.argv else ["save", "reload"]
for phase in phases:
    subprocess.run([str(application), "--smoke-test", str(folder), phase], check=True, timeout=30)
    assert json.loads((folder / f"{phase}.json").read_text())["result"] == "passed"
assert (folder / ".env").stat().st_mode & 0o777 == 0o600
print(f"PASS: app smoke phases {', '.join(phases)}. Evidence: {folder}")
