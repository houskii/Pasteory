import Foundation

public struct FileIconDescriptor: Equatable, Sendable {
    public var assetName: String
    public var label: String

    public init(assetName: String, label: String) {
        self.assetName = assetName
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
}
