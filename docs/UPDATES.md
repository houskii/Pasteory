# 应用更新与发布

Pasteory 使用 Sparkle 2.10.1 校验并安装更新。更新索引位于
`release/beta/appcast.xml`，客户端通过 GitHub Raw 读取；安装包必须来自
`https://github.com/houskii/Pasteory/releases/download/<tag>/`。
当前分发目标仍为 macOS 14 及以上、Apple Silicon。QA 身份不启动正式更新器。

## 用户体验

- 默认每 24 小时检查一次，Sparkle 保存检查时间并负责调度。启动、唤醒或重新激活应用时会恢复到期调度；退出期间不运行检查。手动检查不受每日间隔限制。
- 自动检查只读取版本信息；发现新版后缓存可用版本，在快捷面板齿轮左侧显示 `更新 ↓`。没有新版时不预留按钮宽度。中文按钮为 56 × 26 pt、英文 `Update ↓` 为 70 × 26 pt，与齿轮间距 6 pt，保留面板右侧原有 12 pt 留白。
- 更新入口使用独立语义色：橙色主题采用青色，其余六种主题采用琥珀金；两套颜色分别定义浅色、深色外观。文字对比度至少为 4.5:1，并通过文字、箭头和胶囊轮廓辅助识别。
- 悬停说明为“发现新版本 v<版本>，查看更新内容”。按钮打开更新说明和当前／目标版本；选择“稍后”不下载，选择“下载并安装”后自动下载、验签、安装并重启。
- 下载阶段可取消；校验／安装期间不允许关闭确认窗口。取消或失败保留旧应用，可重新检查和重试。安装目录需要额外权限时，由 Sparkle 请求系统授权。
- “设置 → 关于”保留“检查更新…”链接、上次检查时间和“每天自动检查更新”开关。
- 更新请求不携带剪贴板内容，不启用系统信息上报。发布说明按文字展示，不执行网页脚本。

## 签名与首次配置

默认使用 macOS 构建脚本自动生成的本地开发代码签名，无需用户预先提供稳定身份。该证书不是 Apple 颁发的 Apple Development 或 Developer ID 证书；当前 Beta 未经过 Apple 公证。已有 Apple 证书时可通过 `PASTEORY_SIGN_IDENTITY` 指定。

应用代码签名和更新包的 Ed25519 密钥承担不同职责。首次发布自动创建两者，之后保留恢复材料以便复用；已安装客户端信任的更新公钥不能随意替换。
`make app` 会嵌入 Sparkle.framework、按从内到外的顺序签名辅助程序和宿主应用，并写入更新公钥。

更新公钥按以下优先级读取：

1. 环境变量 `PASTEORY_UPDATE_PUBLIC_KEY`。
2. 仓库文件 `Config/UpdatePublicKey.txt`。
3. 发布 Mac 登录钥匙串中的 `app.pasteory.Pasteory.updates` 账户。没有现有密钥时，构建脚本用 Sparkle `generate_keys` 创建一次；后续构建复用同一密钥。

在本地 Mac 首次发布时，可先构建，然后将该公钥保存到 `Config/UpdatePublicKey.txt` 并提交，保证不同构建机器嵌入相同公钥：

```bash
make app
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account app.pasteory.Pasteory.updates -p > Config/UpdatePublicKey.txt
```

公钥可以进入仓库。私钥保存在发布者钥匙串和仓库外的受限备份目录中，不进入仓库、安装包、发布说明或日志。
发布工具会拒绝本地签名密钥与应用内公钥不一致的安装包。不要因为缺少密钥而重新生成并替换已发布公钥。
迁移发布机器时，按 Sparkle 官方流程转移现有密钥，并继续使用原有应用代码签名身份。

## 从 Linux 触发 macOS 发布

运行 GitHub Actions 的 `Build and release Pasteory Beta`（`build-beta.yml`），输入 main 已准备好的版本，例如 `0.1.31`。也可将当前 main 推送到 `release-build/v0.1.31` 触发同一流程。首次发布无需预置证书或 Secret。

工作流会生成本地开发签名和 Sparkle 更新密钥，执行 `make release`，并将公钥、DMG、签名索引及加密恢复包与版本标签一起提交。发布脚本直接上传 GitHub 附件、回读核对，再更新当前索引；因此即使 `GITHUB_TOKEN` 推送标签不触发其他工作流，也能完成发布。已存在的标签只恢复同一安装包的发布，不重新构建或覆盖附件。

恢复包位于 `release/signing/recovery-<版本>.cms`，采用 CMS AES-256-GCM 和 RSA-OAEP 加密，接收方公钥证书为 `Config/SigningRecovery.crt`。恢复私钥留在仓库外的受限目录；私钥、P12、密码和明文更新密钥不进入 Git 或公开附件。`Config/SigningRecoveryArchive.txt` 指向当前恢复包。

后续发布可将恢复 PEM 私钥安全配置到 GitHub Actions Secret `PASTEORY_RECOVERY_PRIVATE_KEY`。工作流先解密恢复已发布身份和更新密钥，并核对固定更新公钥，再构建新版。也可在自己的 Mac 或受限工作区恢复：

```bash
python3 scripts/signing_recovery.py restore \
  --certificate Config/SigningRecovery.crt \
  --private-key /secure/path/recovery-private.pem \
  --encrypted release/signing/recovery-0.1.31.cms \
  --signing-directory "$HOME/Library/Application Support/Pasteory/Signing" \
  --update-key /secure/path/update-key \
  --update-public-key Config/UpdatePublicKey.txt
```

只有首次发布会创建新的更新密钥；没有恢复材料时，不自动替换客户端已信任的公钥。需要更换密钥时，必须明确安排客户端迁移。

## 换机与密钥备份

更新密钥可以导出、导入，不绑定某一台 Mac。目前保存方式如下：

| 位置 | 保存内容 | 用途 |
| --- | --- | --- |
| 发布 Mac 登录钥匙串 | Sparkle 更新私钥 | 本机日常签名 |
| 仓库外 `~/Library/Application Support/Pasteory/ReleaseSecrets/` | 更新私钥、恢复私钥及公开证书 | 本机恢复和转移；目录权限 0700、私钥文件权限 0600 |
| 仓库 `release/signing/` | 加密恢复包 | 包含原代码签名身份和更新私钥，公开存放也需要恢复私钥才能解密 |
| GitHub Actions Secret `PASTEORY_RECOVERY_PRIVATE_KEY` | 解密恢复包的私钥 | GitHub 的新 macOS runner 无需访问发布 Mac，就能恢复同一签名身份 |

换机后可以直接通过 `Build and release Pasteory Beta` 工作流发布。`Verify signing recovery` 工作流单独验证 Secret、解密、代码签名身份恢复和真实 Ed25519 签名，不安装、不发布任何应用，也不上传明文密钥。

若要从新 Mac 本地发布，先取回独立保管的 `recovery-private.pem`，安装支持 CMS AES-256-GCM 的 OpenSSL 3 或更新版本，再恢复：

```bash
umask 077
mkdir -p "$HOME/Library/Application Support/Pasteory/ReleaseSecrets"
python3 scripts/signing_recovery.py restore \
  --certificate Config/SigningRecovery.crt \
  --private-key /secure/path/recovery-private.pem \
  --encrypted "$(cat Config/SigningRecoveryArchive.txt)" \
  --signing-directory "$HOME/Library/Application Support/Pasteory/Signing" \
  --update-key "$HOME/Library/Application Support/Pasteory/ReleaseSecrets/sparkle-update-private.key" \
  --update-public-key Config/UpdatePublicKey.txt
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account app.pasteory.Pasteory.updates \
  -f "$HOME/Library/Application Support/Pasteory/ReleaseSecrets/sparkle-update-private.key"
./scripts/ensure_local_signing_identity.sh >/dev/null
python3 scripts/check_release_signing.py
```

请将 `recovery-private.pem` 另存一份到密码管理器或离线盘。仓库已经包含所需公开证书和加密恢复包。GitHub Secret 设置后不能从网页直接读回；它可以供工作流使用，但不代替自己保管的备份。不要将恢复私钥提交 Git 或上传到 Release 附件。

丢失本机密钥时，使用备份恢复即可。若所有私钥和可解密备份都丢失，仍可生成新密钥、构建并发布 DMG。现有客户端的应用内更新需要迁移：当前 Pasteory 使用本地开发签名，用户须手动安装一次包含新公钥的版本，之后继续使用应用内升级。

## 0.1.49 的一次性密钥迁移

原更新私钥和原恢复私钥已无法找回。此次按用户确认的方案生成新更新密钥，保留原应用代码签名身份，并重新建立加密恢复包和 GitHub Secret。旧公开证书、旧公钥和旧加密包保留，迁移信息记录在 `Config/UpdateKeyMigration.json`。

0.1.48 及更早版本需要手动安装一次 0.1.49 或更新版本。旧客户端不会因为线上索引改用新密钥就自动信任它。新客户端嵌入新公钥，后续更新复用同一密钥签名。

## 准备发布

1. 在 `Config/Info.plist` 更新展示版本和递增的数字 Build；只修改展示版本无法触发 Sparkle 升级。
2. 将本次更新说明写入一个 UTF-8 文件；同一文件同时用作 GitHub Release 正文和应用内更新说明。
3. 在发布 Mac 执行测试和打包，再准备签名索引：

```bash
make test
make qa-verify
make dmg
make verify
python3 scripts/prepare_update.py \
  --tag v0.1.31 \
  --notes /path/to/release-notes.md \
  --dmg dist/Pasteory-0.1.31-arm64.dmg
```

工具验证正式 Bundle ID、签名、版本递增、DMG、发布公钥和更新说明，生成：

- `dist/update/appcast.xml`：包含版本、Build、系统要求、发布日期、说明、GitHub 下载地址、安装包签名和索引自身签名。
- `dist/update/release-notes.md`：GitHub Release 使用的同一份更新说明。
- `dist/update/release-tag.txt`：对应 tag。

这个命令只准备文件，不上传或发布。正式交付先在分支提交源码、测试、版本号和更新说明，通过 PR 检查并合入 `main`。发布 Mac 同步主干后，再执行单一发布入口：

```bash
git switch main
git pull --ff-only origin main
make release RELEASE_NOTES="$PWD/docs/releases/v<版本>.md"
```

`scripts/check_release_source.py` 要求本地 `main` 与刚拉取的 `origin/main` 完全一致，拒绝暂存的源码、未暂存改动和未跟踪文件。它逐一核对最近发布标签之后修改源码的主干提交，要求 GitHub 上有对应的已合并 PR；API 访问失败也会停止发布。GitHub CLI 必须已登录，发布工作流使用有 `pull-requests: read` 权限的 `GITHUB_TOKEN`。生成的安装包、签名索引及公开签名配置／加密恢复包不属于源码 PR；CI 暂存的签名配置和本次加密包可以继续随产物提交。

`release_beta.sh` 与最近发布标签比较版本和 Build，因此 main 已包含本次版本号时仍可打包。它会重新验证、构建、准备签名索引并安装正式应用，再仅提交生成的 DMG、版本化的 `release/beta/appcast-<版本>.xml` 和 CI 签名恢复文件，打 tag 并推送。GitHub Actions 先发布并核对 DMG、SHA-256 和版本化签名索引，确认附件完整后才将当前索引更新到 `release/beta/appcast.xml`。旧版本的恢复发布不会覆盖新版本索引；旧标签与既有附件不被覆盖。发布脚本最后回读远端索引并核对内容。

签名后修改索引中的任何内容都必须重新签名。首次从其他机器发布前必须导入现有发布私钥，不能用新密钥替代已发布的密钥。

仓库初始空索引用于占位，尚未签名。必须完成第一次正式发布，客户端才能验证更新源；不能把占位索引当作可用发布。
0.1.29 及更早版本不包含更新器，需要先手动安装一次包含更新器的新版本。

## 验证

运行 `swift test` 验证检查间隔、GitHub 资产地址限制、Build 排序、取消检查和全部主题／外观的文字对比度。
运行 `python3 -m unittest discover -s scripts/tests -v` 验证发布索引生成、说明转义和非法 tag／签名拒绝。

DEBUG 构建可在隔离数据环境中使用 `--debug-update-available` 显示演示更新按钮，配合
`--debug-theme=orange` 或任意主题枚举值（`blueViolet`、`blue`、`purple`、`pink`、`orange`、`green`、`graphite`）验收。
演示数据不执行下载和安装；其他隔离调试模式也不访问正式更新源。

真实安装验收另使用 DEBUG QA 测试包：只有 QA 身份、匹配 UUID 的本地标记、独立资料目录及 `127.0.0.1` 固定端口同时满足时，才允许连接测试更新源和下载该端口的 `/updates/` 文件。标记和资料目录随测试包保留，Sparkle 重启后仍使用相同隔离资料。正式 Release 不包含此入口。

发布前还需要在 macOS 实测已签名旧包到新包的完整升级：检查弹窗、取消、下载失败、无效签名、自动重启、正式／QA 隔离、资料与用户快捷键保留，以及辅助功能授权是否保留。

只发布、保留本机旧版以验收应用内升级时，使用：

```bash
PASTEORY_RELEASE_SKIP_INSTALL=1 make release RELEASE_NOTES="$PWD/docs/releases/v0.1.48.md"
```

此选项跳过发布脚本的本机安装步骤，测试、打包、验签和远端附件核对继续执行。不得将手动下载包发布成功等同于客户端更新索引已可用。
