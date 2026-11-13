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

应用的稳定代码签名身份和更新包的 Ed25519 密钥承担不同职责，两者都需要持续保留。
`make app` 会嵌入 Sparkle.framework、按从内到外的顺序签名辅助程序和宿主应用，并写入更新公钥。

更新公钥按以下优先级读取：

1. 环境变量 `PASTEORY_UPDATE_PUBLIC_KEY`。
2. 仓库文件 `Config/UpdatePublicKey.txt`。
3. 发布 Mac 登录钥匙串中的 `app.pasteory.Pasteory.updates` 账户。没有现有密钥时，构建脚本用 Sparkle `generate_keys` 创建一次；后续构建复用同一密钥。

首次正式发布前，在发布 Mac 上构建，然后将该公钥保存到 `Config/UpdatePublicKey.txt` 并提交，保证不同构建机器嵌入相同公钥：

```bash
make app
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account app.pasteory.Pasteory.updates -p > Config/UpdatePublicKey.txt
```

公钥可以进入仓库。私钥留在发布者钥匙串中，不进入仓库、安装包、发布说明或日志。
发布工具会拒绝本地签名密钥与应用内公钥不一致的安装包。不要因为缺少密钥而重新生成并替换已发布公钥。
迁移发布机器时，按 Sparkle 官方流程转移现有密钥，并继续使用原有应用代码签名身份。

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

这个命令只准备文件，不上传或发布。正式交付沿用仓库的单一发布入口：先暂存已验证的源码与公钥，再执行 `make release RELEASE_NOTES=/absolute/path/to/release-notes.md`。

源码与版本号也可以先通过 PR 合入 main，再在原发布 Mac 执行同一个 `make release` 命令；脚本此时与最近发布标签比较版本和 Build，不会因为 main 已包含本次版本号而拒绝打包。

`release_beta.sh` 会重新验证、构建、准备签名索引并安装正式应用，将 DMG 和版本化的 `release/beta/appcast-<版本>.xml` 一起提交、打 tag 和推送。GitHub Actions 先发布并核对 DMG、SHA-256 和版本化签名索引，确认附件完整后才将当前索引更新到 `release/beta/appcast.xml`。旧版本的恢复发布不会覆盖新版本索引；旧标签与既有附件不被覆盖。发布脚本最后回读远端索引并核对内容。

签名后修改索引中的任何内容都必须重新签名。首次从其他机器发布前必须导入现有发布私钥，不能用新密钥替代已发布的密钥。

仓库初始空索引用于占位，尚未签名。必须完成第一次正式发布，客户端才能验证更新源；不能把占位索引当作可用发布。
0.1.29 及更早版本不包含更新器，需要先手动安装一次包含更新器的新版本。

## 验证

运行 `swift test` 验证检查间隔、GitHub 资产地址限制、Build 排序、取消检查和全部主题／外观的文字对比度。
运行 `python3 -m unittest discover -s scripts/tests -v` 验证发布索引生成、说明转义和非法 tag／签名拒绝。

DEBUG 构建可在隔离数据环境中使用 `--debug-update-available` 显示演示更新按钮，配合
`--debug-theme=orange` 或任意主题枚举值（`blueViolet`、`blue`、`purple`、`pink`、`orange`、`green`、`graphite`）验收。
演示数据不执行下载和安装；其他隔离调试模式也不访问正式更新源。

发布前还需要在 macOS 实测已签名旧包到新包的完整升级：检查弹窗、取消、下载失败、无效签名、自动重启、正式／QA 隔离、资料与用户快捷键保留，以及辅助功能授权是否保留。
