import Foundation

public enum FileOpenAction: String, CaseIterable, Codable, Sendable {
    case application
    case command

    public var displayName: String {
        switch self {
        case .application: L10n.tr("使用 App 打开")
        case .command: L10n.tr("执行命令")
        }
    }
}

public enum FileCommandShell: String, CaseIterable, Codable, Sendable {
    case bash
    case zsh

    public var displayName: String { rawValue }
    public var executableURL: URL { URL(fileURLWithPath: "/bin/\(rawValue)") }
}

public enum FileCommandPresentation: String, CaseIterable, Codable, Sendable {
    case terminalWindow
    case silent

    public var displayName: String {
        switch self {
        case .terminalWindow: L10n.tr("显示终端窗口")
        case .silent: L10n.tr("静默执行")
        }
    }
}

public enum FileOpenRuleMatchKind: String, CaseIterable, Codable, Sendable {
    case fileType
    case catalogExtension
    case fileExtension
}

public struct FileOpenRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var matchKind: FileOpenRuleMatchKind
    public var fileType: String
    public var fileExtension: String
    public var action: FileOpenAction
    public var bundleIdentifier: String
    public var command: String

    public init(
        id: UUID = UUID(),
        matchKind: FileOpenRuleMatchKind = .fileType,
        fileType: String = "generic",
        fileExtension: String = "",
        action: FileOpenAction = .application,
        bundleIdentifier: String = "",
        command: String = ""
    ) {
        self.id = id
        self.matchKind = matchKind
        self.fileType = fileType
        self.fileExtension = fileExtension
        self.action = action
        self.bundleIdentifier = bundleIdentifier
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matchKind
        case fileType
        case fileExtension
        case action
        case bundleIdentifier
        case command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let storedType = try container.decodeIfPresent(String.self, forKey: .fileType),
           FileIconResolver.allAssetNames.contains(storedType) {
            fileType = storedType
            matchKind = try container.decodeIfPresent(FileOpenRuleMatchKind.self, forKey: .matchKind) ?? .fileType
            fileExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
        } else if let legacyExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension) {
            matchKind = .fileExtension
            fileExtension = legacyExtension
            fileType = "generic"
        } else {
            matchKind = .fileType
            fileType = "generic"
            fileExtension = ""
        }
        action = try container.decodeIfPresent(FileOpenAction.self, forKey: .action) ?? .application
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(matchKind, forKey: .matchKind)
        try container.encode(fileType, forKey: .fileType)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(action, forKey: .action)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(command, forKey: .command)
    }

    public var normalizedFileExtension: String {
        fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || ".-_+".contains($0) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    public var matchIdentifier: String {
        switch matchKind {
        case .fileType: "type:\(fileType)"
        case .catalogExtension, .fileExtension: "extension:\(normalizedFileExtension)"
        }
    }

    public func matches(fileName: String, uti: String? = nil) -> Bool {
        switch matchKind {
        case .fileType:
            return FileIconResolver.descriptor(fileName: fileName, uti: uti).assetName == fileType
        case .catalogExtension, .fileExtension:
            let suffix = normalizedFileExtension
            guard !suffix.isEmpty else { return false }
            return FileIconResolver.normalizedFileName(fileName)
                .lowercased()
                .hasSuffix(".\(suffix)")
        }
    }
}

public struct FileCommandInvocation: Equatable, Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectoryURL: URL

    public static func make(
        shell: FileCommandShell,
        command: String,
        fileURL: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FileCommandInvocation {
        var environment = inheritedEnvironment
        environment["file"] = fileURL.path
        let standardExecutableDirectories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let inheritedExecutableDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        environment["PATH"] = (standardExecutableDirectories + inheritedExecutableDirectories)
            .reduce(into: [String]()) { result, directory in
                if !directory.isEmpty, !result.contains(directory) { result.append(directory) }
            }
            .joined(separator: ":")
        return FileCommandInvocation(
            executableURL: shell.executableURL,
            arguments: ["-c", command],
            environment: environment,
            currentDirectoryURL: fileURL.deletingLastPathComponent()
        )
    }
}
