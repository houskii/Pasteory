# Developing Pasteory

Pasteory uses Swift 6, SwiftUI, and AppKit. Open `Package.swift` in Xcode 26 or use the commands below on an Apple Silicon Mac. End-user instructions are in the [README](../README.md).

`PasteoryCore` contains storage, search, rules, and archiving. `Pasteory` contains the native app. Product and interaction references: [product](PRODUCT.md), [Settings](SETTINGS_UI.md), [Quick Panel](QUICK_PANEL_INTERACTIONS.md), and [file icons](FILE_ICON_SYSTEM.md).

## 构建与安装

```bash
make test
make app
make qa-verify
make dmg
make verify
make install
```

构建产物位于 `dist/Pasteory.app` 和 `dist/Pasteory-<版本号>-arm64.dmg`。本机构建不使用 ad-hoc 签名，也没有经过 Apple 公证。

QA 包通过 `make qa-app` 构建为 `dist/Pasteory-QA.app`，通过 `make qa-install` 安装到 `/Applications/Pasteory QA.app`。正式包与 QA 包分别使用 `app.pasteory.Pasteory` 和 `app.pasteory.Pasteory.qa`，数据目录分别为 `Pasteory` 和 `Pasteory QA`。`make qa-verify` 会同时校验 Bundle ID、显示名称、数据目录、Chrome 原生消息桥和签名 requirement，防止测试包再次复用正式身份。QA 包默认不注册 Chrome 原生消息桥。

首次执行 `make app`、`make install` 或 `make signing` 时，脚本会在 `~/Library/Application Support/Pasteory/Signing/` 自动创建隔离的 `Pasteory Local Build` 签名身份。钥匙串、加密恢复文件和随机密码仅对当前用户可读，不会进入仓库。本机已有其他稳定代码签名证书时，也可以通过环境变量指定身份：

```bash
PASTEORY_SIGN_IDENTITY="Apple Development: …" make install
```

后续构建持续使用同一证书和 Bundle ID。脚本会锁定证书指纹，并在构建、安装和产物验证三个阶段拒绝 ad-hoc 签名或身份意外变化，避免更新后再次丢失辅助功能授权。不要删除签名目录，也不要把证书、私钥或密码放进仓库。

更新时如需跳过本次启动的存量整理、归档和旧链接重试，使用 `PASTEORY_SKIP_EXISTING_MAINTENANCE=1 make install`。新复制的内容和快捷工具转换结果仍正常入库。

从 ad-hoc 签名首次切换到 `Pasteory Local Build` 后，需要在“系统设置 → 隐私与安全性 → 辅助功能”中重新授权一次。之后只要保留签名目录，更新安装无需重复授权。

## Localization

The first-launch language is English. Settings → General switches between English and Simplified Chinese immediately and saves the choice for later launches. UI labels use `L10n.tr` with the original Chinese template as their key and translations in `Sources/PasteoryCore/Resources/en.json`. Interpolated values are kept separate so user content is never translated. Persistent identifiers, user text, and URL matching tokens must remain unchanged.

Run `python3 scripts/check_localizations.py` after adding UI text. The packaged app must include the SwiftPM resource bundle and both localized permission descriptions; `make qa-verify` checks the resulting bundles. Native screenshot fixtures use only public demo content with monitoring and network resolution disabled.

## Releases

Release is the optimized build configuration; it does not choose a signing identity. From Linux, trigger the GitHub macOS workflow to use Apple’s SDK and tools. Official packaging still needs the publisher’s existing code-signing certificate and private key (Developer ID, Apple Development, or the established local identity), plus the stable Sparkle key. Keep those in the publisher Mac’s keychain or an approved secure CI configuration.

See [UPDATES.md](UPDATES.md) for the stable signing identity, Sparkle key, and publishing workflow. Follow [AGENTS.md](../AGENTS.md) for delivery checks. CI generates disposable identities only for validation; its packages are not official releases.
