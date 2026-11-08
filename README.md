# Quick Translate

个人使用的轻量 macOS 划词翻译工具：选中英文，按快捷键，在浮窗对照原文与中文译文，点击窗口外自动关闭。使用自己的阿里云大模型 API，通过 OpenAI 兼容接口请求翻译，不设置应用侧每日次数限制。

当前开发分支已实现菜单栏、`.env` 设置、快捷键选区、流式翻译和原译文浮窗，已通过本地自动化检查。尚未配置真实 API，跨应用与真实翻译验收未完成，不能视为第一版正式交付。

- [需求与验收](docs/requirements.md)
- [开发规范](docs/development-standards.md)
- [编码工具规则](AGENTS.md)
- [规范迁移记录](docs/tasks/tasks/M001-T001.md)
- [第一版实现规划](docs/tasks/milestones/M002.md)
- [第一版验收计划](docs/testing/M002.md)

本地 Git 仓库已建立，主分支为 `main`，尚未配置远程仓库。菜单栏与配置任务 M002-T001 已合并；翻译任务 M002-T002 在 `feat/m002-t002-selection-translation` 分支验证中，已按用户要求保存本地阶段提交 `ce8c7a7`，尚未合并。

## 本地构建与配置

使用本机 Swift 6 工具链，无第三方依赖：

```sh
sh scripts/build-app.sh
open "build/Quick Translate.app"
```

产物为 `build/Quick Translate.app`，本地临时签名，不作为已公证的公开发行包。应用从构建时登记的项目绝对路径读取 `.env`；移动项目目录后重新构建。

在设置窗口或项目 `.env` 填写 `OPENAI_BASE_URL`、`OPENAI_MODEL`、`DASHSCOPE_API_KEY`。接口地址填写兼容接口基础路径，不包含 `/chat/completions`。地址和模型以所选地域的阿里云控制台为准，参考 [阿里官方兼容接口说明](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope)。`.env.example` 的服务配置为空，只预填默认快捷键；真实 `.env` 被 Git 忽略，文件保存权限为 0600。API Key 不写入系统钥匙串或系统偏好。

`.env` 支持普通键值、单引号、JSON 风格双引号、注释与 `export` 前缀，不执行变量替换或 shell 命令。设置保存会保留无关条目与独立注释；在外部编辑后，先点击“重新读取”再保存，避免覆盖。设置保存成功只表示本地文件已写入，不代表模型已连通。

## 本地试用

没有 API 配置也可打开应用检查设置界面；普通运行不会显示模拟译文。配置完成后：

1. 从菜单栏进入设置，点击“打开辅助功能权限设置”，允许 Quick Translate 获取选区。
2. 在其他应用选中可复制英文，按默认 **Option+D（`⌥D`）**，松开按键。工具通过 `⌘C` 获取本次文本，覆盖剪贴板。
3. 浮窗上方显示原文，下方逐步显示译文。可以滚动、选择文字、复制译文；点击窗口外关闭。失败时“重试”使用当前原文。

默认配置为 `.env` 的 `QT_SHORTCUT="option-d"`（`⌥D`）。设置还保留 `⌃⌥T`、`⌘⇧Y`、`⌃⌥空格`，对应 `control-option-t`、`command-shift-y`、`control-option-space`。界面会显示实际启用的组合；发生冲突时保留旧组合并提示。外部修改快捷键后重启，或重新读取再保存使其生效。

单次上限为 12,000 个字符，不自动截断或拆分；网络等待采用 30 秒无网络数据、120 秒请求总时限。实际延迟及兼容应用仍待验证。无辅助功能权限时会显示引导；不能复制的图片、扫描 PDF 不支持。

## 开发检查

```sh
python3 scripts/swift-tool.py test --enable-code-coverage --disable-xctest
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
sh scripts/build-app.sh
python3 scripts/smoke-settings.py
python3 scripts/smoke-settings.py --translation
```

本机为 macOS 15.3.1 arm64、Swift 6.0.3，仅安装 Command Line Tools。测试使用 Swift Testing；无完整 Xcode 的环境未运行 XCTest。构建包装器只对检测到的旧接口文件及重复模块声明进行项目内兼容处理，不修改系统文件。完整 Xcode 环境仍可打开 `Package.swift`。

设置烟测使用独立临时 `.env` 和非真实凭据，启动实际应用两次，验证菜单、保存、错误处理、退出与重启。翻译烟测在实际应用内注入模拟选区和响应，验证并发、重试、部分失败，以及本应用内外部窗口的点击事件；并检查真实系统热键注册与冲突。仅显式测试参数启用替身，不请求真实模型。报告和本应用截图在被忽略的 `build/quick-translate-smoke-*` 中；不替代真实 API、跨应用复制、物理点击和多屏验收。
