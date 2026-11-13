# Pasteory 工作约定

- 每次交付正式身份的 Pasteory Beta 更新，递增 `Config/Info.plist` 的版本号和构建号。使用稳定签名构建 Apple Silicon DMG，通过测试和打包校验后安装到 `/Applications/Pasteory.app`，再发布到 GitHub。用户要求只编译、只打包或不要安装、发布时，按当次要求执行。隔离测试用的 QA 包不参与发布。
- 发布前确认要交付的源码均已暂存，排除个人数据、签名材料和无关改动。准备 Markdown 版本说明，再运行 `make release RELEASE_NOTES=/absolute/path/to/notes.md`。该命令测试、构建、校验并安装同一个版本，更新 `release/beta/` 的最新 DMG，然后提交并推送源码及版本标签。GitHub Actions 根据该标签发布 Beta Release 和 SHA-256 校验文件。
- 交付前回读远端标签、Release 和附件，下载并核对 SHA-256。发布失败时报告具体阶段；同一标签只能重试同一个提交和安装包，禁止覆盖旧标签或附件。若 GitHub Actions 失败，在 GitHub 上重跑同一工作流。
- 这里的自动发布指交付流程。Pasteory 本身不在后台下载或安装应用更新。
