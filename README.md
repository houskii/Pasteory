# Pasteory

**Pasteory learns from what you copied.**

从复制过的内容里，学会你做事的习惯。

Pasteory 是一个本地优先的 macOS 剪贴板资料库。它运行在菜单栏，通过 `⌘⇧C` 打开快捷面板，支持文字、图片、链接、颜色、代码和文件引用。唤起快捷键可以在设置中修改。

产品的核心洞察和当前边界见 [`docs/PRODUCT.md`](docs/PRODUCT.md)，设置页布局规则见 [`docs/SETTINGS_UI.md`](docs/SETTINGS_UI.md)，快捷面板的打开与搜索规则见 [`docs/QUICK_PANEL_INTERACTIONS.md`](docs/QUICK_PANEL_INTERACTIONS.md)。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon Mac
- Xcode 26 或兼容的 Swift 6 工具链

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

从 ad-hoc 签名首次切换到 `Pasteory Local Build` 后，需要在“系统设置 → 隐私与安全性 → 辅助功能”中重新授权一次。之后只要保留签名目录，更新安装无需重复授权。

## 首次使用

1. 启动 Pasteory。应用会自动记录之后新复制的内容，已有剪贴板不会被导入。
2. 可以在“设置 → 采集与隐私”中把剪贴板检测频率设为 0.5 秒、1 秒或 3 秒，默认 1 秒。
3. 复制一段测试文字，按 `⌘⇧C` 打开快捷面板。
4. 面板打开后默认不聚焦搜索框。空格打开所选内容，`⌘F` 进入或退出搜索；网页、代码和文件需要先在“设置 → 打开方式”中配置应用。
5. Return 会尝试直接粘贴；`⌘Return` 只复制；`⌥Return` 使用纯文本。
6. 直接粘贴需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Pasteory。首次尝试直接粘贴时会主动打开授权提示；没有权限时，内容仍会复制到系统剪贴板。
7. 来源详情分为“浏览器”和“通信软件”：浏览器目前支持 Chrome，通信软件支持飞书和微信。请在“设置 → 采集与隐私”中逐个打开；Chrome 插件可在“高级诊断”中准备安装。
8. 单个合法 HTTP／HTTPS URL 被复制后会自动添加到资料库。也可以在“设置 → 链接解析 → 添加链接…”中手动输入 URL，选择仅保存、匿名解析或使用已登录 WebKit 会话解析。

## 隐私边界

- 所有数据保存在 `~/Library/Application Support/Pasteory/`。
- 默认不发起网络请求。用户在“设置 → 链接解析”中打开自动解析后，Pasteory 会先以不携带 Cookie 的普通请求获取网页标题。BITS、飞书等受保护站点只有在用户主动建立 Pasteory 独立 WebKit 登录会话后才会使用该会话；会话不读取 Chrome Cookie，也不会保存网页正文。WebKit Cookie、IndexedDB 和 WebCrypto 钥匙串账户按 Bundle ID 隔离，正式包与 QA 包互不共享。
- 当前版本不包含 AI 分析或云同步。
- 默认忽略钥匙串、密码应用及隐藏或临时剪贴板类型。
- 文件只保存引用和元数据，不复制原始文件。
- 自动归档不会删除内容；废纸篓内容保留 30 天。
- 网页和会话上下文默认关闭，并与用户填写的标题、备注分开保存。完整边界见 [`docs/SOURCE_CONTEXT.md`](docs/SOURCE_CONTEXT.md)。

## 开发

直接在 Xcode 中打开 `Package.swift`。核心数据、存储、搜索、规则和归档位于 `PasteoryCore`，AppKit／SwiftUI 应用壳位于 `Pasteory`。
