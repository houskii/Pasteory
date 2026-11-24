# Pasteory for Windows

**Windows 10 22H2 / Windows 11 x64** · **Windows 11 Arm64**

## 下载与使用

从仓库 [Windows verification](https://github.com/houskii/Pasteory/actions/workflows/windows.yml) 的成功运行下载 **Pasteory-Windows-preview**，再解压对应架构的 ZIP。双击 `Pasteory.exe`，保留同目录中的运行时文件。预览包内含 .NET 运行时，使用未签名的便携式构建。

- 复制文本、HTML/RTF、网页链接、图片或资源管理器里的文件。文件只保存原路径。
- 从目标应用按 **Ctrl+Shift+V** 打开 Pasteory，输入关键词搜索，用 **↑↓** 选择。**Enter** 粘贴，**Alt+Enter** 粘贴纯文本，**Ctrl+C** 只复制。
- 如果快捷键被占用，可在设置中切换到 **Ctrl+Alt+V**，也可从系统托盘打开历史。若直接粘贴受目标应用的权限或焦点限制，剪贴板仍保留选中内容，可切换到目标应用按 **Ctrl+V**。
- 可编辑标题、备注和手动分组，也可收藏、置顶、删除或筛选内容。应用会按容量自动移除最旧的普通记录。

历史、图片和设置存放在 `%LOCALAPPDATA%\Pasteory`，由当前 Windows 用户账户访问。Pasteory 会过滤无法识别来源的复制、内置密码管理器名单、系统隐私标记，以及你在设置中排除的进程。可从托盘暂停记录或退出应用。界面跟随 Windows 显示语言，提供英文和简体中文。

Windows 预览版的范围是本地剪贴板管理。AI 整理、智能分组、Mac 历史导入和自动更新仍属于后续移植范围。

## Build and verify

Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). From the repository root on Windows:

```powershell
dotnet run --project Windows/Pasteory
dotnet run --project Windows/Tests/Pasteory.Core.Tests -c Release
dotnet run --project Windows/Tests/Pasteory.Windows.Tests -c Release
dotnet publish Windows/Pasteory/Pasteory.csproj -c Release -r win-x64 --self-contained -o dist/win-x64
```

Use `win-arm64` for the Arm64 package. The portable build includes the executable and its supporting files. The Windows CI job runs the native WPF and clipboard-format tests on x64 and packages both architectures.

For an interactive check, copy text in Notepad and use the shortcut to paste it into a second Notepad window. Repeat with an image and a file copied in Explorer. Check that pausing capture prevents new entries, then exit and reopen Pasteory to confirm history persists.
