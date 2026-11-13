# Pasteory 工作约定

- 每次交付正式身份的 Pasteory Beta 更新，递增 `Config/Info.plist` 的版本号和构建号。使用 Release 配置构建 Apple Silicon DMG，通过测试和打包校验后安装到构建 Mac 的 `/Applications/Pasteory.app`，再发布 GitHub。用户要求只编译、只打包或不要安装、发布时，按当次要求执行。隔离测试用的 QA 包不参与发布。
- 不要求用户预先提供稳定签名身份。默认由 macOS 构建脚本生成本地开发代码签名证书；若已配置 Apple Development 或 Developer ID 证书，也可指定使用。发布说明需如实标注签名类型和公证状态，本地生成的证书不能称为 Apple 颁发的开发者证书。
- 发布前确认要交付的源码均已暂存，排除个人数据、签名私钥和无关改动。准备 Markdown 版本说明，再运行 `make release RELEASE_NOTES=/absolute/path/to/notes.md`。该命令测试、构建、校验并安装同一个版本，更新 `release/beta/` 的最新 DMG，然后提交并推送源码及版本标签。Linux 可触发 `Build and release Pasteory Beta` 工作流，由 macOS runner 执行同一发布入口。
- 签名恢复私钥和明文恢复材料不得进入仓库或公开附件；仓库可保存恢复公钥证书及加密恢复包。首次发布自动创建更新密钥并固定公钥，后续更新复用已发布密钥，避免客户端无法验签。
- 交付前回读远端标签、Release 和附件，下载并核对 SHA-256。发布失败时报告具体阶段；同一标签只能重试同一个提交和安装包，禁止覆盖旧标签或附件。若 GitHub Actions 失败，在 GitHub 上重跑同一工作流。
- 这里的自动发布指交付流程。Pasteory 每天检查更新，只有用户确认后才下载和安装；不静默下载安装。发布流程在确认附件可用后再发布签名更新索引，细节见 `docs/UPDATES.md`。
