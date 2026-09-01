# Passte

Passte 是一个本地优先的 macOS 剪贴板资料库。它运行在菜单栏，通过 `⌘⇧B` 打开快捷面板，支持文字、图片、链接、颜色、代码和文件引用。唤起快捷键可以在设置中修改。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon Mac
- Xcode 26 或兼容的 Swift 6 工具链

## 构建与安装

```bash
make test
make app
make dmg
make verify
make install
```

构建产物位于 `dist/Passte.app` 和 `dist/Passte-0.1.0-arm64.dmg`。默认使用 ad-hoc 签名，没有经过 Apple 公证。ad-hoc 签名的代码身份会随构建变化，重新安装后 macOS 可能要求再次授予辅助功能权限。

构建脚本会优先使用 `~/Library/Application Support/Passte/Signing/` 中隔离的 `Passte Local Build` 签名身份。钥匙串和随机密码文件仅对当前用户可读，不会进入仓库。本机已有其他稳定代码签名证书时，也可以通过环境变量指定身份：

```bash
PASSTE_SIGN_IDENTITY="Apple Development: …" make install
```

后续构建持续使用同一证书和 Bundle ID，辅助功能授权才能稳定复用。不要把证书或私钥放进仓库。

## 首次使用

1. 启动 Passte。应用会自动记录之后新复制的内容，已有剪贴板不会被导入。
2. 需要临时停止时，从菜单栏选择“暂停监控”。
3. 复制一段测试文字，按 `⌘⇧B` 打开快捷面板。
4. Return 会尝试直接粘贴；`⌘Return` 只复制；`⌥Return` 使用纯文本。
5. 直接粘贴需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Passte。首次尝试直接粘贴时会主动打开授权提示；没有权限时，内容仍会复制到系统剪贴板。

## 隐私边界

- 所有数据保存在 `~/Library/Application Support/Passte/`。
- v0.1 不包含网络请求、AI 分析或云同步。
- 默认忽略钥匙串、密码应用及隐藏或临时剪贴板类型。
- 文件只保存引用和元数据，不复制原始文件。
- 自动归档不会删除内容；废纸篓内容保留 30 天。

## 开发

直接在 Xcode 中打开 `Package.swift`。核心数据、存储、搜索、规则和归档位于 `PassteCore`，AppKit／SwiftUI 应用壳位于 `Passte`。
