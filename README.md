# Quick Translate

个人使用的轻量 macOS 划词翻译工具：选中英文，按快捷键，在浮窗对照原文与中文译文，点击窗口外自动关闭。使用自己的阿里云大模型 API，通过 OpenAI 兼容接口请求翻译，不设置应用侧每日次数限制。

当前已实现菜单栏和 `.env` 设置，划词翻译正在开发。

- [需求与验收](docs/requirements.md)
- [开发规范](docs/development-standards.md)
- [编码工具规则](AGENTS.md)
- [规范迁移记录](docs/tasks/tasks/M001-T001.md)
- [第一版实现规划](docs/tasks/milestones/M002.md)
- [第一版验收计划](docs/testing/M002.md)

本地 Git 仓库已建立，主分支为 `main`。需求与规范按独立 Task 分支审查、验证和合并；尚未配置远程仓库。技术方向为 Swift、SwiftUI 与 AppKit 的原生 macOS 工具；开始应用实现前需核实工具链、系统版本与实际检查入口。

## 本地构建与配置

使用本机 Swift 6 工具链，无第三方依赖：

```sh
sh scripts/build-app.sh
open "build/Quick Translate.app"
```

产物为 `build/Quick Translate.app`，本地临时签名，不作为已公证的公开发行包。应用从构建时登记的项目绝对路径读取 `.env`；移动项目目录后重新构建。

在设置窗口或项目 `.env` 填写 `OPENAI_BASE_URL`、`OPENAI_MODEL`、`DASHSCOPE_API_KEY`。接口地址填写兼容接口基础路径，不包含 `/chat/completions`。`.env.example` 只有空值；真实 `.env` 被 Git 忽略，文件保存权限为 0600。API Key 不写入系统钥匙串或系统偏好。

`.env` 支持普通键值、单引号、JSON 风格双引号、注释与 `export` 前缀，不执行变量替换或 shell 命令。设置保存会保留无关条目与独立注释；在外部编辑后，先点击“重新读取”再保存，避免覆盖。设置保存成功只表示本地文件已写入，不代表模型已连通。

## 开发检查

```sh
python3 scripts/swift-tool.py test --enable-code-coverage --disable-xctest
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
sh scripts/build-app.sh
python3 scripts/smoke-settings.py
```

本机为 macOS 15.3.1 arm64、Swift 6.0.3，仅安装 Command Line Tools。测试使用 Swift Testing；无完整 Xcode 的环境未运行 XCTest。构建包装器只对检测到的旧接口文件及重复模块声明进行项目内兼容处理，不修改系统文件。完整 Xcode 环境仍可打开 `Package.swift`。

烟测使用独立临时 `.env` 和非真实凭据，启动实际应用两次，验证菜单、保存、错误处理、退出与重启。报告和本应用截图在被忽略的 `build/quick-translate-smoke-*` 中；这不替代后续真实 API 与跨应用划词验收。
