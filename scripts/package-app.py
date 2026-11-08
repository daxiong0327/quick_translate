#!/usr/bin/env python3
"""Build the portable, self-signed Apple Silicon preview and a drag-to-install DMG."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.1.0"
NAME = f"Quick-Translate-{VERSION}-arm64.dmg"


def package():
    subprocess.run(["/bin/sh", str(ROOT / "scripts/build-app.sh"), "--distribution"], cwd=ROOT,
                   env={**os.environ, "QT_BUILD_NUMBER": os.environ.get("QT_BUILD_NUMBER", "4")}, check=True)
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
        payload = folder / "payload"
        payload.mkdir()
        shutil.copytree(app, payload / app.name)
        (payload / "Applications").symlink_to("/Applications")
        shutil.copy2(ROOT / "LICENSE", payload / "LICENSE.txt")
        (payload / "安装说明.txt").write_text("""Quick Translate 0.1.0 预览版 · Apple Silicon · macOS 13+

1. 将 Quick Translate 拖到 Applications（应用程序），再从应用程序打开。
2. 此版本为免费自签名，未经 Apple 公证。确认来自本仓库后，如果系统拦截，
   先尝试打开，再在 系统设置 → 隐私与安全性 中选择“仍要打开”。
3. 在菜单栏 qt 图标的设置中填写自己的接口地址、模型和 API Key。
   配置只保存在 ~/.config/quick-translate/.env，不使用系统钥匙串。
4. 在 系统设置 → 隐私与安全性 → 辅助功能 中添加并允许 Quick Translate。
5. 选中可复制英文，按 Option+D；点击窗口外、× 或 Esc 关闭。

更新前退出旧版，再用新版替换应用。用户配置保留在应用包外。
应用通过复制取得选区，会覆盖剪贴板；选区发送至你配置的服务地址。
应用不设置每日次数限制，服务商的费用和限额按你的账号执行。
目前实测 macOS 15.3.1 / Apple Silicon，完整跨应用兼容性验收仍在进行。

项目：https://github.com/daxiong0327/quick_translate
macOS 首次打开说明：https://support.apple.com/en-us/102445
""", encoding="utf-8")
        temporary_image = folder / NAME
        subprocess.run(["/usr/bin/hdiutil", "create", "-volname", f"Quick Translate {VERSION}",
                        "-srcfolder", str(payload), "-format", "UDZO", str(temporary_image)], check=True)
        subprocess.run(["/usr/bin/hdiutil", "verify", str(temporary_image)], check=True)
        digest = hashlib.sha256(temporary_image.read_bytes()).hexdigest()
        destination = build / NAME
        temporary_image.replace(destination)
        (build / (NAME + ".sha256")).write_text(f"{digest}  {NAME}\n")
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        (build / "package-build.json").write_text(json.dumps({
            "sourceRevision": revision, "version": VERSION, "build": info["CFBundleVersion"],
            "architecture": arch, "installer": NAME, "sha256": digest,
            "bytes": destination.stat().st_size, "signing": "fixed self-signed; not notarized",
        }, indent=2) + "\n")
    print(f"Installer: {destination}\nSHA256: {digest}")


if __name__ == "__main__":
    try:
        package()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
