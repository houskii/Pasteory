using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Pasteory.Windows;

internal sealed record FileType(string Icon, string EnglishName, string ChineseName, string Suffixes = "", string Names = "")
{
    internal string Name => Labels.Chinese ? ChineseName : EnglishName;
}

internal static class FileTypes
{
    private static readonly FileType Generic = new("generic", "Other files", "其他文件");
    // These are the same icon families and filename overrides used by FileIconResolver.swift.
    internal static IReadOnlyList<FileType> Catalog { get; } =
    [
        new("android-library", "Android library", "Android 库", "aar jar"),
        new("android-package", "Android package", "Android 安装包", "apk aab"),
        new("api", "API definition", "接口定义", "proto thrift graphql gql"),
        new("archive", "Archive", "压缩包", "zip 7z rar tar gz tar.gz tgz bz2 xz"),
        new("arkts", "ArkTS", "ArkTS", "ets"),
        new("audio", "Audio", "音频", "mp3 m4a wav aac flac ogg"),
        new("binary", "Binary", "二进制", "so dex wasm dll exe"),
        new("build", "Build script", "构建脚本", "gradle podspec gemspec",
            "makefile cmakelists.txt dockerfile build.gradle settings.gradle gradlew hvigorfile.ts podfile cartfile gemfile"),
        new("certificate", "Certificate or key", "证书与密钥", "mobileprovision p12 pfx cer crt pem keystore jks key"),
        new("config", "Configuration", "配置文件", "toml ini conf config plist entitlements properties env pro cfg",
            "oh-package.json5 module.json5 .env .npmrc .swiftlint.yml .editorconfig"),
        new("cpp", "C/C++", "C/C++", "c cc cpp cxx h hpp"),
        new("dart", "Dart", "Dart", "dart"),
        new("database", "Database", "数据库", "db sqlite sqlite3 realm sql"),
        new("diagnostic", "Diagnostic file", "诊断文件", "crash ips hprof profraw profdata perfetto-trace"),
        new("diff", "Diff", "差异文件", "patch diff"),
        new("document", "Document", "文档", "doc docx pages rtf epub"),
        new("font", "Font", "字体", "ttf otf woff woff2"),
        Generic,
        new("git", "Git configuration", "Git 配置", Names: ".gitignore .gitattributes .gitmodules"),
        new("go", "Go", "Go", "go"),
        new("harmony-package", "Harmony package", "Harmony 安装包", "hap hsp"),
        new("image", "Image file", "图片文件", "png jpg jpeg heic heif gif webp svg tif tiff bmp"),
        new("installer", "Disk image or installer", "磁盘镜像与安装包", "dmg pkg iso msi msix"),
        new("ios-package", "Apple package", "Apple 安装包", "app ipa xcarchive xcresult dsym"),
        new("java", "Java", "Java", "java"),
        new("javascript", "JavaScript", "JavaScript", "js jsx mjs cjs"),
        new("json", "JSON", "JSON", "json json5"),
        new("kotlin", "Kotlin", "Kotlin", "kt kts"),
        new("lock", "Dependency lock", "依赖锁定文件", "lock resolved",
            "podfile.lock package.resolved yarn.lock pnpm-lock.yaml package-lock.json gradle.lockfile"),
        new("log", "Log", "日志", "log trace"),
        new("lua", "Lua", "Lua", "lua"),
        new("markdown", "Markdown", "Markdown", "md markdown"),
        new("network", "Network capture", "网络抓包", "har pcap pcapng"),
        new("objc", "Objective-C", "Objective-C", "m mm"),
        new("pdf", "PDF", "PDF", "pdf"),
        new("presentation", "Presentation", "演示文稿", "ppt pptx"),
        new("python", "Python", "Python", "py pyi"),
        new("ruby", "Ruby", "Ruby", "rb", "fastfile appfile matchfile deliverfile"),
        new("rust", "Rust", "Rust", "rs"),
        new("shell", "Shell script", "Shell 脚本", "sh bash zsh fish ps1 bat cmd"),
        new("spreadsheet", "Spreadsheet", "电子表格", "xls xlsx numbers csv tsv"),
        new("swift", "Swift", "Swift", "swift swiftinterface swiftmodule", "package.swift"),
        new("txt", "Plain text", "纯文本", "txt text"),
        new("typescript", "TypeScript", "TypeScript", "ts tsx"),
        new("video", "Video", "视频", "mp4 mov m4v mkv webm avi"),
        new("web", "Web frontend", "网页前端", "html htm css scss sass less vue svelte"),
        new("xcode", "Xcode project", "Xcode 工程", "xcodeproj xcworkspace pbxproj xcconfig storyboard xib strings stringsdict"),
        new("xml", "XML", "XML", "xml"),
        new("yaml", "YAML", "YAML", "yaml yml")
    ];

    private static readonly Dictionary<string, FileType> BySuffix = Patterns(type => type.Suffixes);
    private static readonly Dictionary<string, FileType> ByName = Patterns(type => type.Names);
    private static readonly Dictionary<(string, bool), BitmapSource> Icons = [];
    internal static IEnumerable<string> Suffixes => BySuffix.Keys.Order(StringComparer.OrdinalIgnoreCase);

    private static Dictionary<string, FileType> Patterns(Func<FileType, string> patterns) =>
        Catalog.SelectMany(type => patterns(type).Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(pattern => (pattern, type)))
        .ToDictionary(pair => pair.pattern, pair => pair.type, StringComparer.OrdinalIgnoreCase);

    internal static FileType ForName(string name)
    {
        if (ByName.TryGetValue(name, out var exact)) return exact;
        for (int dot = name.IndexOf('.'); dot >= 0; dot = name.IndexOf('.', dot + 1))
            if (BySuffix.TryGetValue(name[(dot + 1)..], out var type)) return type;
        return Generic;
    }

    internal static FileType ForSuffix(string suffix) => BySuffix.GetValueOrDefault(suffix.TrimStart('.'), Generic);

    internal static BitmapSource Image(FileType type, bool dimmed = false)
    {
        var key = (type.Icon, dimmed);
        if (Icons.TryGetValue(key, out var cached)) return cached;
        if (!dimmed)
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.UriSource = new Uri($"pack://application:,,,/Pasteory;component/FileIcons/{type.Icon}.png");
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.EndInit();
            bitmap.Freeze();
            return Icons[key] = bitmap;
        }

        var original = new FormatConvertedBitmap(Image(type), PixelFormats.Bgra32, null, 0);
        int stride = original.PixelWidth * 4;
        var pixels = new byte[stride * original.PixelHeight];
        original.CopyPixels(pixels, stride, 0);
        for (int offset = 0; offset < pixels.Length; offset += 4)
        {
            byte gray = (byte)((pixels[offset] * 11 + pixels[offset + 1] * 59 + pixels[offset + 2] * 30) / 100);
            pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = gray;
        }
        var grayIcon = BitmapSource.Create(original.PixelWidth, original.PixelHeight, original.DpiX, original.DpiY,
            PixelFormats.Bgra32, null, pixels, stride);
        grayIcon.Freeze();
        return Icons[key] = grayIcon;
    }
}
