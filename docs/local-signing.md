# 本地固定自签名

此方案免费，用于保持 Quick Translate 不同构建之间的身份一致。它不提供 Apple Developer ID 身份，也不包含公证；Apple 对代码身份和 Gatekeeper 分别执行策略，不能用自签名保证下载后免提示。参考 [Apple 代码签名说明](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) 和 [安全打开 Mac App](https://support.apple.com/en-us/102445)。

## 初始化与构建

```sh
python3 scripts/signing.py setup
sh scripts/build-app.sh
```

初始化仅需一次。脚本创建有效期 10 年的 RSA 3072 位代码签名证书和加密的 PKCS#12 备份，保存在 `~/Library/Application Support/Quick Translate Signing/`。重复初始化不会更换证书；发现不完整目录、错误身份或宽松文件权限会停止。不要为解决构建错误删除该目录重新生成身份。

签名约束使用 `local.quicktranslate.app` 与证书指纹，避免每次更新都将代码哈希当作应用身份。每次签署后都执行严格校验。私钥仅导入本工具专用的用户钥匙串，允许 Apple 签名工具访问；签署结束后锁定，不向系统信任列表添加证书。API Key 继续保存在项目 `.env`，不导入钥匙串。

构建入口先检查身份，再在临时目录完成编译、图标封装和签名。全部成功后替换 `build/Quick Translate.app`；普通构建失败保留原应用。需要区分构建时可使用 `QT_BUILD_NUMBER=2 sh scripts/build-app.sh`，它只改变包内构建号，不更换证书。

## 备份和恢复

首次初始化后，将 `identity.p12`、`password`、`certificate.pem` 和 `identity.json` 备份到自己的安全位置。`password` 可以解开私钥，不能连同备份公开发送或放入 GitHub；宜用加密存储保存，离机备份时把密码与 PKCS#12 分开保管。当前机器必须能读取密码以完成本地自动签名，目录 0700 和文件 0600 限制了其他本机用户的直接访问，不能替代安全备份。

换电脑时，将这四个原文件恢复到同一路径，目录设为 0700、文件设为 0600，再运行 `setup`。脚本会从原 PKCS#12 恢复专用钥匙串并核对指纹；无需备份整个钥匙串。若身份遗失，重新生成就属于换身份，可能需要重新授权。证书将来过期或更换也要按身份迁移处理。

公开代码可以包含这些脚本和公开指纹，不能包含签名私钥、密码、真实 `.env` 或用户文本。用户从源码自行构建时会创建自己的身份，它与作者发布包的身份不同；升级时应保持同一发布来源或同一签名身份。

## 首次授权和升级验证

从旧 ad-hoc 签名切换后，在系统设置的“隐私与安全性 → 辅助功能”重新添加当前应用并开启授权。如旧条目已开启仍无效，移除旧条目后重新添加。此操作由用户在系统界面完成，脚本不写权限数据库。

授权后，在相同应用路径替换另一个构建，退出并重新启动，验证 Option+D 仍能复制选区。程序提供只读诊断参数 `--accessibility-status`，不请求权限、不读取剪贴板、不调用 API；用 Launch Services 启动可检查该应用本身的状态：

```sh
open -n -W --stdout "$PWD/build/accessibility.json" \
  "build/Quick Translate.app" --args --accessibility-status
```

诊断结果 `true → true` 以及真实选区使用才是权限保留证据。两个未授权构建都返回 `false` 不能证明成功。

2026-11-08 本机复验：用户重新授权后，实际应用经 Launch Services 检查为 `true`；关闭应用，在同一路径用相同证书构建并替换 0.1.0（2）→ 0.1.0（3），再次启动检查仍为 `true`。两者代码哈希不同、签名约束一致，严格签名校验通过。这证明了本机此次升级的系统授权状态保留；本轮未执行跨应用选区与真实 API 全流程，不能据此扩大为全部兼容性验收。证据为 `build/signing-upgrade-result.json`，详细记录见 [验收文档](testing/M002.md#2026-11-08-固定自签名验证)。

```sh
python3 scripts/test-signing.py
```

回归脚本使用应用副本验证不同构建号产生不同代码哈希但保持相同身份约束、交叉校验、资源篡改拒绝、错误身份拒绝和失败时保留旧应用；不改变系统权限或使用真实模型。真实权限与下载安装验收另行记录。

## GitHub 发行边界

自签名应用仍可能被 Gatekeeper 拦截。确认下载来源可信后，用户可依照 Apple 说明在“隐私与安全性”中对该应用选择“仍要打开”；不要关闭全局 Gatekeeper 或要求用户信任自建根证书。

目前尚未完成可移植配置路径、发行归档、全新安装及升级验收；也尚未验证所有支持的系统和 CPU 架构。应用包已包含正式 qt 图标；系统辅助功能列表中的旧图标是否刷新，需在重新添加当前应用后实际确认。固定签名通过不代表这些发行条件已完成。
