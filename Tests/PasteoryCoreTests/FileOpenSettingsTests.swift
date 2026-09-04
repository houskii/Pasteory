import AppKit
import Foundation
import Testing
@testable import Pasteory
@testable import PasteoryCore

@MainActor
@Test func customExtensionRuleTakesPriorityOverBuiltInFileTypeRule() {
    let suiteName = "FileOpenSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)

    settings.addFileOpenRule()
    let builtInID = settings.fileOpenRules[0].id
    settings.updateFileOpenRuleCatalogExtension(
        id: builtInID,
        descriptor: FileIconResolver.fileExtension("hap")!
    )
    var builtIn = settings.fileOpenRules[0]
    builtIn.bundleIdentifier = "built-in-app"
    settings.updateFileOpenRule(builtIn)

    settings.addCustomFileOpenRule()
    let customID = settings.fileOpenRules.last!.id
    settings.updateFileOpenRuleExtension(id: customID, fileExtension: "hap")
    var custom = settings.fileOpenRules.last!
    custom.bundleIdentifier = "custom-app"
    settings.updateFileOpenRule(custom)

    #expect(settings.fileOpenRule(fileName: "demo.hap", uti: nil)?.bundleIdentifier == "custom-app")
    #expect(settings.fileOpenRule(fileName: "demo.hsp", uti: nil) == nil)
}

@MainActor
@Test func updatingCommandPreservesTypedSpaces() {
    let suiteName = "FileOpenCommandTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    settings.addFileOpenRule()
    let id = settings.fileOpenRules[0].id

    settings.updateFileOpenRuleCommand(id: id, command: "open -a Xcode \"$file\"")

    #expect(settings.fileOpenRules[0].command == "open -a Xcode \"$file\"")
}

@MainActor
@Test func storedFileTypeRuleMigratesToOneRepresentativeExtension() throws {
    let suiteName = "FileOpenMigrationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let stored = FileOpenRule(matchKind: .fileType, fileType: "swift", command: "tool \"$file\"")
    defaults.set(try JSONEncoder().encode([stored]), forKey: "fileOpenRules")

    let settings = AppSettings(defaults: defaults)

    #expect(settings.fileOpenRules[0].matchKind == .catalogExtension)
    #expect(settings.fileOpenRules[0].normalizedFileExtension == "swift")
    #expect(settings.fileOpenRule(fileName: "Demo.swift", uti: nil) != nil)
    #expect(settings.fileOpenRule(fileName: "Demo.swiftinterface", uti: nil) == nil)
}

@Test func terminalLaunchOnlyShowsShortTemporaryRunnerCommand() throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("PasteoryTerminalLaunchTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let fileURL = URL(fileURLWithPath: "/Users/test/Downloads/private build.hap")
    let command = "hdc install \"$file\""
    let invocation = FileCommandInvocation.make(
        shell: .zsh,
        command: command,
        fileURL: fileURL,
        inheritedEnvironment: ["PATH": "/usr/bin:/bin:/a/very/long/private/path"]
    )
    let launch = try FileCommandTerminalLaunch.prepare(
        invocation: invocation,
        temporaryRootURL: temporaryRoot,
        identifier: UUID(uuidString: "AD127DF4-E967-4F1F-BCEE-1E230E09FEB8")!
    )
    defer { launch.cleanup() }

    #expect(launch.terminalCommand == "'\(launch.launcherURL.path)'")
    #expect(!launch.terminalCommand.contains(fileURL.path))
    #expect(!launch.terminalCommand.contains(command))
    #expect(!launch.terminalCommand.contains(invocation.environment["PATH"]!))
    #expect(try String(contentsOf: launch.commandURL, encoding: .utf8) == command)

    let launcher = try String(contentsOf: launch.launcherURL, encoding: .utf8)
    #expect(!launcher.contains(command))
    #expect(launcher.contains("command_text=$(/bin/cat"))
    let commandPermissions = try fileManager.attributesOfItem(atPath: launch.commandURL.path)[.posixPermissions] as? NSNumber
    let launcherPermissions = try fileManager.attributesOfItem(atPath: launch.launcherURL.path)[.posixPermissions] as? NSNumber
    #expect(commandPermissions?.intValue == 0o600)
    #expect(launcherPermissions?.intValue == 0o700)
}

@MainActor
@Test func terminalWindowAutomationScriptCompiles() {
    let script = NSAppleScript(source: ClipOpenCoordinator.terminalAppleScript)
    var errorInfo: NSDictionary?

    #expect(script?.compileAndReturnError(&errorInfo) == true)
    #expect(errorInfo == nil)
}
