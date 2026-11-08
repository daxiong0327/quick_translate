#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/swift-tool.py build -c release
bin_dir=$(python3 scripts/swift-tool.py build -c release --show-bin-path)
app_dir="$PWD/build/Quick Translate.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/QuickTranslate" "$app_dir/Contents/MacOS/QuickTranslate"
python3 - "$app_dir/Contents/Info.plist" "$PWD/.env" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.quicktranslate.app',
    'CFBundleName': 'Quick Translate',
    'CFBundleDisplayName': 'Quick Translate',
    'CFBundleExecutable': 'QuickTranslate',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
    'QTEnvironmentFile': sys.argv[2],
}))
PY
codesign --force --sign - --identifier local.quicktranslate.app "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
