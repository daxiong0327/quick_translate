# Quick Translate

个人使用的轻量 macOS 划词翻译工具：选中英文，按快捷键，在浮窗对照原文与中文译文，点击窗口外自动关闭。使用自己的阿里云大模型 API，通过 OpenAI 兼容接口请求翻译，不设置应用侧每日次数限制。

## 下载与安装

**[下载安装包：Quick Translate 0.1.0（Apple Silicon · 安装向导）](https://raw.githubusercontent.com/daxiong0327/quick_translate/main/build/Quick-Translate-0.1.0-arm64.pkg)**

[SHA256 校验文件](https://raw.githubusercontent.com/daxiong0327/quick_translate/main/build/Quick-Translate-0.1.0-arm64.pkg.sha256) · [安装包目录](build/)

预览版，适用于 **Apple Silicon（M 系列）**。最低编译目标 macOS 13，当前实测 macOS 15.3.1；暂不提供 Intel 安装包。已实现菜单栏、Option+D 划词、流式翻译和逐段对照；完整跨应用兼容性验收仍在进行。

1. 点击上面的链接下载 **`.pkg`**，双击进入 macOS 安装向导，按 **“继续 → 安装”**。系统可能要求用 Mac 登录密码或 Touch ID 确认，完成后应用位于 **“应用程序”**，无需自己拖拽或复制。
2. 从“应用程序”打开 **Quick Translate**。安装包或应用首次打开若被系统拦截，确认来自本仓库后，在“系统设置 → 隐私与安全性”中选择“仍要打开”。安装包本身未签署 Developer ID Installer，包内应用使用固定免费自签名，两者均未公证；参见 [Apple 首次打开说明](https://support.apple.com/en-us/102445)。
3. 点击菜单栏的 **qt** 图标进入设置，填写自己的接口地址、模型和 API Key，保存配置。
4. 在“系统设置 → 隐私与安全性 → 辅助功能”添加并启用 Quick Translate。
5. 在其他应用选中可复制英文，按 **Option+D** 查看翻译。点击窗口外、右上角 × 或 Esc 关闭。

更新时先退出旧版，再运行新版安装包，安装器会更新“应用程序”中的 Quick Translate，无需卸载。安装版配置保存在 **`~/.config/quick-translate/.env`**，与应用包分开，更新不会覆盖；首次保存自动建立目录，目录权限 0700、文件权限 0600。安装包不包含开发者的配置或 Key，也不使用系统钥匙串保存 API Key。

应用通过复制取得选区，会覆盖剪贴板；选中的内容发送到你配置的服务地址。应用不设每日次数限制，服务商的费用和限额按你的账号执行。

## 项目与验收

当前配置曾通过公开短句的真实请求检查，用户也确认可以翻译；三类应用的完整兼容性验收尚未完成。原安装包交付见 [M003-T001](docs/tasks/tasks/M003-T001.md)，系统安装向导改进见 [Fix001-T001](docs/tasks/tasks/Fix001-T001.md)。

- [需求与验收](docs/requirements.md)
- [开发规范](docs/development-standards.md)
- [编码工具规则](AGENTS.md)
- [规范迁移记录](docs/tasks/tasks/M001-T001.md)
- [第一版实现规划](docs/tasks/milestones/M002.md)
- [第一版验收计划](docs/testing/M002.md)

源码主分支为 `main`，远端为 `git@github.com:daxiong0327/quick_translate.git`。菜单栏、翻译界面和固定签名成果已集成；完整兼容性验收继续跟踪在 [M002-T002](docs/tasks/tasks/M002-T002.md)，不把预览包发布视为所有环境都已验证。

## 本地构建与配置

使用本机 Swift 6 工具链，无第三方依赖：

```sh
python3 scripts/signing.py setup
sh scripts/build-app.sh
open "build/Quick Translate.app"
```

产物为 `build/Quick Translate.app`，使用固定的免费自签名身份，不是 Apple Developer ID 签名，也没有公证。`setup` 初次创建证书，重复运行复用原证书；后续构建无需重复初始化。构建在临时目录完成图标生成和严格签名校验后才替换原应用，缺少签名身份时停止，不退回临时签名。此命令生成开发包，从构建时登记的项目绝对路径读取 `.env`；移动项目目录后重新构建。

制作可移植的发行安装包：

```sh
python3 scripts/package-app.py
python3 scripts/check-package.py build/Quick-Translate-0.1.0-arm64.pkg
```

发行应用位于 `build/distribution/Quick Translate.app`，不包含开发机的配置路径；PKG 与 SHA256 文件直接放在 `build/`。使用系统自带的 `pkgbuild` / `productbuild` 制作欢迎、安装与完成流程，中文资源位于 `packaging/`；目标固定为 `/Applications`，不运行自定义安装脚本。本仓库仅收录这两个发行文件，展开的应用、编译缓存、烟测报告和签名材料继续忽略。校验入口检查真实包结构、安装器选项及展开应用的隔离配置保存/重启，不会自动执行管理员安装。更新正式下载文件时需重新验证并更新校验文件。

签名身份保存在用户目录 `~/Library/Application Support/Quick Translate Signing/`，目录权限 0700、文件 0600。它包含加密的 `identity.p12`、`password`、公开证书、身份记录和专用签名钥匙串。该钥匙串只保存签名私钥，与翻译 API Key 无关；脚本仅在签署期间临时加入钥匙串搜索列表，结束后移除并锁定，不修改系统信任设置。详情和备份步骤见 [本地签名说明](docs/local-signing.md)。

从旧临时签名首次切换到自签名，可能需要重新添加辅助功能授权。以后的构建绑定相同证书与应用标识，不再绑定每次变化的代码哈希。本机已验证：用户授权后，同一路径从构建 2 替换为构建 3，代码哈希变化，重启后的辅助功能授权仍保留；其他系统和安装环境尚未验证。单纯退出或重启不会更换签名。下载自签名包时仍可能遇到系统拦截，不能把自签名等同于 Apple 认可或公证。

在设置窗口或当前构建所使用的 `.env` 填写 `OPENAI_BASE_URL`、`OPENAI_MODEL`、`DASHSCOPE_API_KEY`。接口地址填写兼容接口基础路径，不包含 `/chat/completions`。地址和模型以所选地域的阿里云控制台为准，参考 [阿里官方兼容接口说明](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope)。`.env.example` 中的地址和模型仅供参考，API Key 留空；真实 `.env` 被 Git 忽略，文件保存权限为 0600。API Key 不写入系统钥匙串或系统偏好。

`.env` 支持普通键值、单引号、JSON 风格双引号、注释与 `export` 前缀，不执行变量替换或 shell 命令。设置保存会保留无关条目与独立注释；在外部编辑后，关闭设置再从菜单栏重新打开，即可读取最新配置；已打开时重复激活设置会保留当前编辑。外部修改冲突仍会阻止保存。保存成功后按钮显示“已保存”，只表示本地文件已写入，不代表模型已连通。设置页不显示文件路径和常驻说明，必要错误仍会提示。

## 本地试用

没有 API 配置也可打开应用检查设置界面；普通运行不会显示模拟译文。配置完成后：

1. 从菜单栏进入设置，点击“打开辅助功能权限设置”，允许 Quick Translate 获取选区。
2. 在其他应用选中可复制英文，按默认 **Option+D（`⌥D`）**，松开按键。工具通过 `⌘C` 获取本次文本，覆盖剪贴板。
3. 浮窗在当前屏幕可见区域正中间显示，英文为较浅的小字、中文为较大的正文。生成中显示完整原文和逐步收到的译文，完成后按段落对照；若模型改变了分段，保留全文对照。多屏时使用触发快捷键时鼠标所在的屏幕，初始位置不跟随鼠标坐标。短文按内容收紧，长文内部滚动；生成中不反复调整窗口大小。
4. 可以选择文字、点击“复制译文”复制全部已收到的译文；点击窗口外、右上角的“×”或 Esc 关闭。失败时“重试”使用当前原文，设置仍从菜单栏进入。

默认配置为 `.env` 的 `QT_SHORTCUT="option-d"`（`⌥D`）。设置还保留 `⌃⌥T`、`⌘⇧Y`、`⌃⌥空格`，对应 `control-option-t`、`command-shift-y`、`control-option-space`。界面会显示实际启用的组合；发生冲突时保留旧组合并提示。外部修改快捷键后重启，或关闭并重新打开设置，再保存使其生效。

单次上限为 12,000 个字符，不自动截断或拆分；网络等待采用 30 秒无网络数据、120 秒请求总时限。实际延迟及兼容应用仍待验证。无辅助功能权限时会显示引导；不能复制的图片、扫描 PDF 不支持。

## 开发检查

```sh
python3 scripts/swift-tool.py test --enable-code-coverage --disable-xctest
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
sh scripts/build-app.sh
python3 scripts/smoke-settings.py
python3 scripts/smoke-settings.py --translation
python3 scripts/test-signing.py
```

本机为 macOS 15.3.1 arm64、Swift 6.0.3，仅安装 Command Line Tools。测试使用 Swift Testing；无完整 Xcode 的环境未运行 XCTest。构建包装器只对检测到的旧接口文件及重复模块声明进行项目内兼容处理，不修改系统文件。完整 Xcode 环境仍可打开 `Package.swift`。

设置烟测使用独立临时 `.env` 和非真实凭据，启动实际应用两次，验证菜单、保存、错误处理、退出与重启。翻译烟测在实际应用内注入模拟选区和响应，验证并发、重试、部分失败，以及本应用内外部窗口的点击事件；并检查真实系统热键注册与冲突。仅显式测试参数启用替身，不请求真实模型。报告和本应用截图在被忽略的 `build/quick-translate-smoke-*` 中；不替代真实 API、跨应用复制、物理点击和多屏验收。

## 图标

应用采用最新确认的轻笔画、分离式小写 `qt`，保留 q 的自然下伸和 t 的弧度。应用图标为浅色圆角底与黑色字形；菜单栏和翻译页采用适配系统外观的单色标识，18 点菜单栏图形有轻微笔画补偿。批准参考保存在 [qt-logo-flowing-reference.png](docs/design/qt-logo-flowing-reference.png)，原生曲线实现位于 `Sources/QuickTranslate/BrandIcon.swift`。窗口与构建导出的多尺寸图标共用同一定义，运行时不依赖参考图片或字体。构建时在临时目录导出 iconset，再生成应用内的 `QuickTranslate.icns`。

## 许可证

本项目采用远端仓库已有的 [MIT 许可证](LICENSE)。
