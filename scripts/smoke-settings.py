#!/usr/bin/env python3
"""Launch the built app twice with isolated settings; no GUI automation permissions required."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
application = root / "build/Quick Translate.app/Contents/MacOS/QuickTranslate"
folder = Path(tempfile.mkdtemp(prefix="quick-translate-smoke-", dir=root / "build"))
for phase in ["save", "reload"]:
    subprocess.run([str(application), "--smoke-test", str(folder), phase], check=True, timeout=30)
    assert json.loads((folder / f"{phase}.json").read_text())["result"] == "passed"
assert (folder / ".env").stat().st_mode & 0o777 == 0o600
print(f"PASS: app launched twice, menu opened settings, saved, rejected invalid input, reloaded, and exited. Evidence: {folder}")
