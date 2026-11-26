# Pasteory for Windows

支持 Windows 10 22H2 / Windows 11 x64 和 Windows 11 Arm64。下载或构建对应架构的便携包，解压后运行同目录中的 Pasteory.exe。

- 使用 Ctrl+Shift+V 唤起快捷面板。方向键选择内容或切换分组，Enter 粘贴，Ctrl+C 复制，Space 打开，Ctrl+F 切换搜索。长按 Ctrl 查看当前快捷键。
- Ctrl+L 打开设置中的资料库，Ctrl+, 进入通用设置。资料库可搜索文字、图像、链接、颜色、代码、文件与混合内容，并管理收藏、置顶、普通分组、智能分组、聚合、归档和废纸篓。文字预览可切换 Markdown 和原文。
- Ctrl+B 聚合搜索结果，或从当前内容进入多选。用方向键移动光标、空格勾选、Enter 确认，Esc 返回上一级。快捷面板的分组栏支持顶部、左侧和右侧，可在通用设置中调整。
- 在设置中选择主题、快捷键和打开方式。Windows 的文件命令使用 PowerShell，应用通过环境变量传入文件路径。
- 图像 OCR 使用已安装的 Windows OCR 语言。识别文字以 `[OCR:…]` 追加到备注，编辑结果会同步到预览、搜索和纯文本复制。图片、文件及混合内容的纯文本操作优先使用当前备注。
- 在采集与隐私中可选择立即、0.1 秒、0.5 秒或 1 秒检测，单独开启 Chrome、微信和飞书的来源详情，并从应用列表选择要排除的 Windows 桌面应用。连接页提供 Chrome 插件安装入口，高级诊断可查看连接状态并重建搜索索引。
- 链接解析按资源汇总全部、待处理和已解析的链接，可按日期、状态或采集应用筛选。记录展示最近尝试、HTTP 状态、耗时和上次成功时间。可以直接重试、登录并解析，或从链接创建兜底规则。每条登录规则使用独立的 WebView2 会话，可选择 3、7、14 或 30 天自动刷新。
- AI 整理和 Story 使用你配置的 OpenAI 兼容服务。AI 总开关默认关闭，密钥由 Windows DPAPI 加密。可以使用本机 Magpie 或 Ollama。
- 数据保存在 `%LOCALAPPDATA%\Pasteory`。存储与清理可以导入、导出 Windows 备份，也可以选择包含 `manifest.json` 的 Mac 备份目录。Mac 文件引用保留原路径，路径在 Windows 上可用时才能直接打开。
- 旧版 Windows 历史首次打开时迁移到 `history.sqlite3`，保留原 `history.json` 供迁移恢复。资料库即时搜索全库，并按每页 100 项加载卡片。
- 剪贴板直接提供的 JPEG、TIFF 等编码可按原字节保存并随 Windows 备份恢复。文件引用保留完整路径。图片预览和 OCR 使用 Windows 可用的解码器。
- 在“存储与清理”按最后使用时间和大小预览待清理的历史。预览会计算独占附件的可回收空间。网页缓存使用 WebView2 的缓存清理接口，登录会话和已解析标题独立保存。

如果托盘中正在运行旧版，先从托盘退出再启动新版。需要并行调试时使用独立数据目录，并为测试实例设置不同的全局快捷键。

## 构建和验证

安装 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)，从仓库根目录运行。

```powershell
dotnet run --project Windows/Pasteory
dotnet run --project Windows/Tests/Pasteory.Core.Tests -c Release
dotnet run --project Windows/Tests/Pasteory.Windows.Tests -c Release
dotnet publish Windows/Pasteory/Pasteory.csproj -c Release -r win-x64 --self-contained -o dist/win-x64
dotnet run --project Windows/Tests/Pasteory.Windows.Tests -c Release -- --packaged-app dist/win-x64/Pasteory.exe
dotnet run --project Windows/Tests/Pasteory.Windows.Tests -c Release -- --benchmark-search
dotnet run --project Windows/Tests/Pasteory.Windows.Tests -c Release -- --link-engine
```

Arm64 将 `win-x64` 替换为 `win-arm64`。在装有 Windows OCR 的本机可额外添加 `--ocr` 测试系统识别。便携包验证使用临时数据目录。

## Windows 更新索引

客户端读取 `release/windows/appcast.json`，使用仓库中已有的 Pasteory 公钥验证更新索引，并按签名索引中的 SHA-256 校验 ZIP。把两个架构的 ZIP 放在同一目录，在持有 Pasteory 更新签名身份的发布机器上运行 `scripts/prepare_windows_update.py --help` 查看参数。发布附件命名为 `Pasteory-win-x64.zip` 和 `Pasteory-win-arm64.zip`，标签为 `windows-v<版本>`。附件发布并校验可下载后再提交索引。
