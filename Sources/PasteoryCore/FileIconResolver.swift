import Foundation

public struct FileIconDescriptor: Equatable, Sendable {
    public var assetName: String
    public var label: String

    public init(assetName: String, label: String) {
        self.assetName = assetName
        self.label = label
    }
}

public struct FileTypeDescriptor: Identifiable, Equatable, Sendable {
    public var assetName: String
    private var displayNameKey: String
    public var displayName: String {
        get { L10n.text(displayNameKey) }
        set { displayNameKey = newValue }
    }
    public var label: String
    public var fileExtensions: [String]
    public var exactFileNames: [String]

    public var id: String { assetName }

    public var suffixSummary: String {
        let values = fileExtensions.map { ".\($0)" } + exactFileNames
        guard !values.isEmpty else { return label }
        let visible = values.prefix(4).joined(separator: " · ")
        return values.count > 4 ? visible + " · …" : visible
    }

    public var primaryPattern: String {
        if let fileExtension = fileExtensions.first { return ".\(fileExtension)" }
        if let exactFileName = exactFileNames.first { return exactFileName }
        return label
    }

    public var coverageSummary: String {
        if fileExtensions.count > 1 {
            return L10n.tr("\(displayName) · 共 \(fileExtensions.count) 种后缀")
        }
        if fileExtensions.isEmpty, exactFileNames.count > 1 {
            return L10n.tr("\(displayName) · 共 \(exactFileNames.count) 种文件名")
        }
        return displayName
    }

    public var sortName: String {
        if assetName == "generic" { return "\u{10ffff}" }
        return fileExtensions.first ?? exactFileNames.first ?? label.lowercased()
    }

    public init(
        assetName: String,
        displayName: String,
        label: String,
        fileExtensions: [String] = [],
        exactFileNames: [String] = []
    ) {
        self.assetName = assetName
        self.displayNameKey = displayName
        self.label = label
        self.fileExtensions = fileExtensions
        self.exactFileNames = exactFileNames
    }
}

public struct FileExtensionDescriptor: Identifiable, Equatable, Sendable {
    public var fileExtension: String
    public var assetName: String
    private var displayNameKey: String
    public var displayName: String {
        get { L10n.text(displayNameKey) }
        set { displayNameKey = newValue }
    }
    public var label: String

    public var id: String { fileExtension }
    public var pattern: String { ".\(fileExtension)" }

    public init(fileExtension: String, assetName: String, displayName: String, label: String) {
        self.fileExtension = fileExtension
        self.assetName = assetName
        self.displayNameKey = displayName
        self.label = label
    }
}

public enum FileIconResolver {
    public static let allAssetNames = [
        "android-library", "android-package", "api", "archive", "arkts", "audio", "binary", "build",
        "certificate", "config", "cpp", "dart", "database", "diagnostic", "diff", "document", "font",
        "generic", "git", "go", "harmony-package", "image", "installer", "ios-package", "java", "javascript",
        "json", "kotlin", "lock", "log", "lua", "markdown", "network", "objc", "pdf", "presentation",
        "python", "ruby", "rust", "shell", "spreadsheet", "swift", "txt", "typescript", "video", "web",
        "xcode", "xml", "yaml"
    ]

    public static let allFileTypes: [FileTypeDescriptor] = allAssetNames
        .map { assetName in
            FileTypeDescriptor(
                assetName: assetName,
                displayName: assetDisplayNames[assetName] ?? assetName,
                label: assetLabels[assetName] ?? "FILE",
                fileExtensions: catalogExtensions(for: assetName),
                exactFileNames: catalogExactFileNames[assetName] ?? []
            )
        }
        .sorted {
            $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending
        }

    public static let allFileExtensions: [FileExtensionDescriptor] = {
        var mappings = extensionAssetNames
        mappings["har"] = "harmony-package"
        mappings["key"] = "certificate"
        mappings["tar.gz"] = "archive"
        mappings["perfetto-trace"] = "diagnostic"
        return mappings.map { fileExtension, assetName in
            FileExtensionDescriptor(
                fileExtension: fileExtension,
                assetName: assetName,
                displayName: assetDisplayNames[assetName] ?? assetName,
                label: assetLabels[assetName] ?? "FILE"
            )
        }
        .sorted {
            $0.fileExtension.localizedStandardCompare($1.fileExtension) == .orderedAscending
        }
    }()

    public static func fileType(assetName: String) -> FileTypeDescriptor? {
        allFileTypes.first { $0.assetName == assetName }
    }

    public static func fileExtension(_ value: String) -> FileExtensionDescriptor? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return allFileExtensions.first { $0.fileExtension == normalized }
    }

    public static func preferredFileExtension(assetName: String) -> FileExtensionDescriptor? {
        if let preferred = preferredAssetExtensions[assetName],
           let descriptor = fileExtension(preferred) {
            return descriptor
        }
        guard let first = fileType(assetName: assetName)?.fileExtensions.first else { return nil }
        return fileExtension(first)
    }

    public static func descriptor(fileName: String, uti: String? = nil) -> FileIconDescriptor {
        let normalizedName = normalizedFileName(fileName)
        let lowerName = normalizedName.lowercased()

        if let descriptor = exactFileNameDescriptors[lowerName] { return descriptor }
        if lowerName.hasSuffix(".tar.gz") { return descriptor(named: "archive") }
        if lowerName.hasSuffix(".perfetto-trace") { return descriptor(named: "diagnostic") }

        let fileExtension = URL(fileURLWithPath: normalizedName).pathExtension.lowercased()
        if fileExtension == "har" {
            let lowerUTI = uti?.lowercased() ?? ""
            if lowerUTI.contains("zip") || lowerUTI.contains("archive") {
                return descriptor(named: "harmony-package")
            }
            return descriptor(named: "network")
        }
        if fileExtension == "key" {
            let lowerUTI = uti?.lowercased() ?? ""
            if lowerUTI.contains("keynote") || lowerUTI.contains("presentation") {
                return descriptor(named: "presentation")
            }
            return descriptor(named: "certificate")
        }
        guard let assetName = extensionAssetNames[fileExtension] else {
            return descriptor(named: "generic")
        }
        return descriptor(named: assetName)
    }

    public static func normalizedFileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), url.isFileURL, !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func descriptor(named assetName: String) -> FileIconDescriptor {
        FileIconDescriptor(assetName: assetName, label: assetLabels[assetName] ?? "FILE")
    }

    private static let exactFileNameDescriptors: [String: FileIconDescriptor] = {
        var values = [String: FileIconDescriptor]()
        for name in ["makefile", "cmakelists.txt", "dockerfile", "build.gradle", "settings.gradle", "gradlew", "hvigorfile.ts", "podfile", "cartfile", "gemfile"] {
            values[name] = descriptor(named: "build")
        }
        for name in ["podfile.lock", "package.resolved", "yarn.lock", "pnpm-lock.yaml", "package-lock.json", "gradle.lockfile"] {
            values[name] = descriptor(named: "lock")
        }
        for name in ["fastfile", "appfile", "matchfile", "deliverfile"] {
            values[name] = descriptor(named: "ruby")
        }
        values["package.swift"] = descriptor(named: "swift")
        values["oh-package.json5"] = descriptor(named: "config")
        values["module.json5"] = descriptor(named: "config")
        for name in [".gitignore", ".gitattributes", ".gitmodules"] {
            values[name] = descriptor(named: "git")
        }
        for name in [".env", ".npmrc", ".swiftlint.yml", ".editorconfig"] {
            values[name] = descriptor(named: "config")
        }
        return values
    }()

    private static let catalogExactFileNames: [String: [String]] = [
        "build": ["Makefile", "Dockerfile"],
        "config": [".env", ".editorconfig"],
        "git": [".gitignore", ".gitattributes"],
        "lock": ["Podfile.lock", "Package.resolved"],
        "ruby": ["Fastfile", "Gemfile"],
        "swift": ["Package.swift"]
    ]

    private static let catalogAmbiguousExtensions: [String: [String]] = [
        "certificate": ["key"],
        "harmony-package": ["har"],
        "network": ["har"],
        "presentation": ["key"]
    ]

    private static let preferredAssetExtensions: [String: String] = [
        "android-library": "aar", "android-package": "apk", "api": "proto", "archive": "zip",
        "arkts": "ets", "audio": "mp3", "binary": "so", "build": "gradle", "certificate": "pem",
        "config": "plist", "cpp": "cpp", "dart": "dart", "database": "db", "diagnostic": "crash",
        "diff": "diff", "document": "docx", "font": "ttf", "go": "go", "harmony-package": "hap",
        "image": "png", "installer": "dmg", "ios-package": "ipa", "java": "java",
        "javascript": "js", "json": "json", "kotlin": "kt", "lock": "lock", "log": "log",
        "lua": "lua", "markdown": "md", "network": "har", "objc": "m", "pdf": "pdf",
        "presentation": "pptx", "python": "py", "ruby": "rb", "rust": "rs", "shell": "sh",
        "spreadsheet": "xlsx", "swift": "swift", "txt": "txt", "typescript": "ts", "video": "mp4",
        "web": "html", "xcode": "xcodeproj", "xml": "xml", "yaml": "yaml"
    ]

    private static func catalogExtensions(for assetName: String) -> [String] {
        let direct = extensionAssetNames.compactMap { fileExtension, mappedAssetName in
            mappedAssetName == assetName ? fileExtension : nil
        }
        return Array(Set(direct + (catalogAmbiguousExtensions[assetName] ?? [])))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static let extensionAssetNames: [String: String] = [
        "txt": "txt", "text": "txt",
        "md": "markdown", "markdown": "markdown",
        "pdf": "pdf",
        "doc": "document", "docx": "document", "pages": "document", "rtf": "document", "epub": "document",
        "xls": "spreadsheet", "xlsx": "spreadsheet", "numbers": "spreadsheet", "csv": "spreadsheet", "tsv": "spreadsheet",
        "ppt": "presentation", "pptx": "presentation",
        "png": "image", "jpg": "image", "jpeg": "image", "heic": "image", "heif": "image", "gif": "image", "webp": "image", "svg": "image", "tif": "image", "tiff": "image", "bmp": "image",
        "mp3": "audio", "m4a": "audio", "wav": "audio", "aac": "audio", "flac": "audio", "ogg": "audio",
        "mp4": "video", "mov": "video", "m4v": "video", "mkv": "video", "webm": "video", "avi": "video",
        "zip": "archive", "7z": "archive", "rar": "archive", "tar": "archive", "gz": "archive", "tgz": "archive", "bz2": "archive", "xz": "archive",
        "dmg": "installer", "pkg": "installer", "iso": "installer",
        "ttf": "font", "otf": "font", "woff": "font", "woff2": "font",

        "json": "json", "json5": "json",
        "yaml": "yaml", "yml": "yaml",
        "xml": "xml",
        "toml": "config", "ini": "config", "conf": "config", "config": "config", "plist": "config", "entitlements": "config", "properties": "config", "env": "config", "pro": "config", "cfg": "config",
        "db": "database", "sqlite": "database", "sqlite3": "database", "realm": "database", "sql": "database",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell",
        "proto": "api", "thrift": "api", "graphql": "api", "gql": "api",
        "patch": "diff", "diff": "diff",
        "log": "log", "trace": "log",
        "lock": "lock", "resolved": "lock",

        "swift": "swift", "swiftinterface": "swift", "swiftmodule": "swift",
        "m": "objc", "mm": "objc",
        "c": "cpp", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "h": "cpp", "hpp": "cpp",
        "xcodeproj": "xcode", "xcworkspace": "xcode", "pbxproj": "xcode", "xcconfig": "xcode", "storyboard": "xcode", "xib": "xcode", "strings": "xcode", "stringsdict": "xcode",
        "app": "ios-package", "ipa": "ios-package", "xcarchive": "ios-package", "xcresult": "ios-package", "dsym": "ios-package",
        "mobileprovision": "certificate", "p12": "certificate", "pfx": "certificate", "cer": "certificate", "crt": "certificate", "pem": "certificate", "keystore": "certificate", "jks": "certificate",

        "kt": "kotlin", "kts": "kotlin",
        "java": "java",
        "apk": "android-package", "aab": "android-package",
        "aar": "android-library", "jar": "android-library",
        "so": "binary", "dex": "binary", "wasm": "binary",
        "crash": "diagnostic", "ips": "diagnostic", "hprof": "diagnostic", "profraw": "diagnostic", "profdata": "diagnostic",
        "pcap": "network", "pcapng": "network",

        "ets": "arkts",
        "hap": "harmony-package", "hsp": "harmony-package",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "html": "web", "htm": "web", "css": "web", "scss": "web", "sass": "web", "less": "web", "vue": "web", "svelte": "web",
        "dart": "dart",
        "py": "python", "pyi": "python",
        "go": "go",
        "rs": "rust",
        "rb": "ruby",
        "lua": "lua",
        "gradle": "build", "podspec": "build", "gemspec": "build"
    ]

    private static let assetLabels: [String: String] = [
        "android-library": "AAR", "android-package": "APK", "api": "API", "archive": "ZIP", "arkts": "ETS", "audio": "AUD", "binary": "BIN", "build": "BUILD",
        "certificate": "CERT", "config": "CFG", "cpp": "C++", "dart": "DART", "database": "DB", "diagnostic": "DEBUG", "diff": "DIFF", "document": "DOC", "font": "FONT",
        "generic": "FILE", "git": "GIT", "go": "GO", "harmony-package": "HAP", "image": "IMG", "installer": "PKG", "ios-package": "IPA", "java": "JAVA", "javascript": "JS",
        "json": "JSON", "kotlin": "KT", "lock": "LOCK", "log": "LOG", "lua": "LUA", "markdown": "MD", "network": "NET", "objc": "OBJ-C", "pdf": "PDF", "presentation": "PPT",
        "python": "PY", "ruby": "RB", "rust": "RS", "shell": "SH", "spreadsheet": "XLS", "swift": "SWIFT", "txt": "TXT", "typescript": "TS", "video": "VID", "web": "WEB",
        "xcode": "XCODE", "xml": "XML", "yaml": "YAML"
    ]

    private static let assetDisplayNames: [String: String] = [
        "android-library": "Android 库", "android-package": "Android 安装包", "api": "接口定义", "archive": "压缩包",
        "arkts": "ArkTS", "audio": "音频", "binary": "二进制", "build": "构建脚本", "certificate": "证书与密钥",
        "config": "配置文件", "cpp": "C/C++", "dart": "Dart", "database": "数据库", "diagnostic": "诊断文件",
        "diff": "差异文件", "document": "文档", "font": "字体", "generic": "其他文件", "git": "Git 配置",
        "go": "Go", "harmony-package": "Harmony 安装包", "image": "图片文件", "installer": "磁盘镜像与安装包",
        "ios-package": "Apple 安装包", "java": "Java", "javascript": "JavaScript", "json": "JSON", "kotlin": "Kotlin",
        "lock": "依赖锁定文件", "log": "日志", "lua": "Lua", "markdown": "Markdown", "network": "网络抓包",
        "objc": "Objective-C", "pdf": "PDF", "presentation": "演示文稿", "python": "Python", "ruby": "Ruby",
        "rust": "Rust", "shell": "Shell 脚本", "spreadsheet": "电子表格", "swift": "Swift", "txt": "纯文本",
        "typescript": "TypeScript", "video": "视频", "web": "网页前端", "xcode": "Xcode 工程", "xml": "XML", "yaml": "YAML"
    ]
}
