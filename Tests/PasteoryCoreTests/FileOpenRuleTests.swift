import Foundation
import Testing
@testable import PasteoryCore

@Test func fileTypeCatalogMatchesPackagedIconCatalog() {
    #expect(FileIconResolver.allFileTypes.count == 49)
    #expect(Set(FileIconResolver.allFileTypes.map(\.assetName)) == Set(FileIconResolver.allAssetNames))
    #expect(FileIconResolver.fileType(assetName: "swift")?.displayName == "Swift")
    #expect(FileIconResolver.fileType(assetName: "swift")?.fileExtensions.contains("swift") == true)
    #expect(FileIconResolver.fileType(assetName: "harmony-package")?.suffixSummary.contains(".hap") == true)
    #expect(FileIconResolver.fileType(assetName: "generic")?.displayName == "其他文件")
    #expect(FileIconResolver.allFileTypes.last?.assetName == "generic")
    #expect(FileIconResolver.allFileExtensions.map(\.fileExtension).contains("hap"))
    #expect(FileIconResolver.allFileExtensions.map(\.fileExtension).contains("swiftinterface"))
    #expect(FileIconResolver.allFileExtensions.map(\.fileExtension) == FileIconResolver.allFileExtensions.map(\.fileExtension).sorted())
}

@Test func legacyExtensionRulePreservesItsExactExtensionMatch() throws {
    let data = Data(
        """
        {
          "id": "7A0EC92B-BF06-4A3F-9936-DF43B0B957B4",
          "fileExtension": "PDF",
          "bundleIdentifier": "com.apple.Preview"
        }
        """.utf8
    )

    let rule = try JSONDecoder().decode(FileOpenRule.self, from: data)

    #expect(rule.matchKind == .fileExtension)
    #expect(rule.normalizedFileExtension == "pdf")
    #expect(rule.action == .application)
    #expect(rule.bundleIdentifier == "com.apple.Preview")
    #expect(rule.command.isEmpty)
}

@Test func customExtensionRuleMatchesCaseInsensitivelyAndSupportsCompoundSuffixes() {
    let hap = FileOpenRule(matchKind: .fileExtension, fileExtension: ".HAP")
    let archive = FileOpenRule(matchKind: .fileExtension, fileExtension: "tar.gz")

    #expect(hap.matches(fileName: "/tmp/Demo.HAP"))
    #expect(!hap.matches(fileName: "/tmp/Demo.hsp"))
    #expect(archive.matches(fileName: "/tmp/source.TAR.GZ"))
    #expect(!archive.matches(fileName: "/tmp/source.gz"))
}

@Test func fileCommandInvocationPassesFileAsEnvironmentWithoutInterpolation() {
    let fileURL = URL(fileURLWithPath: "/tmp/Pasteory checks/a file; echo unsafe.txt")
    let invocation = FileCommandInvocation.make(
        shell: .zsh,
        command: "tool --input \"$file\"",
        fileURL: fileURL,
        inheritedEnvironment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(invocation.executableURL.path == "/bin/zsh")
    #expect(invocation.arguments == ["-c", "tool --input \"$file\""])
    #expect(invocation.environment["file"] == fileURL.path)
    #expect(invocation.environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(invocation.currentDirectoryURL.path == "/tmp/Pasteory checks")
}
