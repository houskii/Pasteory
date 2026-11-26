# Pasteory for Windows

支持 Windows 10 22H2 / Windows 11 x64 和 Windows 11 Arm64。下载或构建对应架构的便携包，解压后运行同目录中的 Pasteory.exe。

- 使用 Ctrl+Shift+V 唤起快捷面板。方向键选择内容或切换分组，Enter 粘贴，Ctrl+C 复制，Space 打开，Ctrl+F 切换搜索。长按 Ctrl 查看当前快捷键。
- Ctrl+L 打开设置中的资料库，Ctrl+, 进入通用设置。资料库可搜索文字、图像、链接、颜色、代码、文件与混合内容，并管理收藏、置顶、普通分组、智能分组、聚合、归档和废纸篓。
- 在设置中选择主题、快捷键和打开方式。Windows 的文件命令使用 PowerShell，应用通过环境变量传入文件路径。
- 图像 OCR 使用已安装的 Windows OCR 语言。链接的登录会话使用 WebView2，网页来源使用仓库中的 Chrome 插件。首次加载 Chrome 插件从高级诊断进入。
- 某些链接会在本地生成兜底标题。链接解析设置提供按路由查看未解析链接、创建兜底规则和查看最近解析记录的入口。
- AI 整理和 Story 使用你配置的 OpenAI 兼容服务。AI 总开关默认关闭，密钥由 Windows DPAPI 加密。可以使用本机 Magpie 或 Ollama。
- 数据保存在 `%LOCALAPPDATA%\Pasteory`。存储与清理可以导入、导出 Windows 备份，也可以选择包含 `manifest.json` 的 Mac 备份目录。Mac 文件引用保留原路径，路径在 Windows 上可用时才能直接打开。
- 旧版 Windows 历史首次打开时迁移到 `history.sqlite3`，保留原 `history.json` 供迁移恢复。资料库即时搜索全库，并按每页 100 项加载卡片。

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
```

Arm64 将 `win-x64` 替换为 `win-arm64`。在装有 Windows OCR 的本机可额外添加 `--ocr` 测试系统识别。便携包验证使用临时数据目录。

## Windows 更新索引

客户端读取 `release/windows/appcast.json`，使用仓库中已有的 Pasteory 公钥验证更新索引，并按签名索引中的 SHA-256 校验 ZIP。把两个架构的 ZIP 放在同一目录，在持有 Pasteory 更新签名身份的发布机器上运行 `scripts/prepare_windows_update.py --help` 查看参数。发布附件命名为 `Pasteory-win-x64.zip` 和 `Pasteory-win-arm64.zip`，标签为 `windows-v<版本>`。附件发布并校验可下载后再提交索引。
