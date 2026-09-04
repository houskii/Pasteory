import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationReference: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL?

    var id: String { bundleIdentifier }
}

@MainActor
enum ApplicationCatalog {
    private static let customPathsKey = "customApplicationPaths"
    private static var cachedApplications: [ApplicationReference]?
    private static var discoveryTask: Task<[ApplicationReference], Never>?
    private static var persistentCache: ApplicationDataCache?

    static func configure(cacheDirectory: URL) {
        persistentCache = ApplicationDataCache(directory: cacheDirectory)
    }

    static func discover(additional: [ApplicationReference] = []) async -> [ApplicationReference] {
        if let cachedApplications { return merge(cachedApplications + additional) }
        if let discoveryTask {
            let applications = await discoveryTask.value
            return merge(applications + additional)
        }
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let customURLs = (UserDefaults.standard.stringArray(forKey: customPathsKey) ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let task = Task.detached(priority: .utility) {
            scan(roots: roots, customURLs: customURLs)
        }
        discoveryTask = task
        let discovered = await task.value
        cachedApplications = discovered
        discoveryTask = nil
        return merge(discovered + additional)
    }

    static func reference(for url: URL) -> ApplicationReference? {
        guard let reference = makeReference(url: url) else { return nil }
        persistentCache?.remember(reference)
        return reference
    }

    static func reference(forBundleIdentifier bundleIdentifier: String) -> ApplicationReference? {
        guard !bundleIdentifier.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let reference = makeReference(url: url) else { return nil }
        persistentCache?.remember(reference)
        return reference
    }

    static func rememberCustomApplication(_ url: URL) {
        var paths = Set(UserDefaults.standard.stringArray(forKey: customPathsKey) ?? [])
        paths.insert(url.standardizedFileURL.path)
        UserDefaults.standard.set(paths.sorted(), forKey: customPathsKey)
        cachedApplications = nil
        if let reference = makeReference(url: url) {
            persistentCache?.remember(reference)
        }
    }

    static func icon(
        for bundleIdentifier: String?,
        fallbackName: String,
        applicationURL: URL? = nil
    ) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let persistentCache {
            return persistentCache.icon(
                bundleIdentifier: bundleIdentifier,
                fallbackName: fallbackName,
                applicationURL: applicationURL
            )
        }
        guard let url = applicationURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private nonisolated static func scan(roots: [URL], customURLs: [URL]) -> [ApplicationReference] {
        let fileManager = FileManager()
        var urls = customURLs
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                urls.append(url)
            }
        }
        return merge(urls.compactMap(makeReference(url:)))
    }

    private nonisolated static func makeReference(url: URL) -> ApplicationReference? {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty else { return nil }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ApplicationReference(bundleIdentifier: bundleIdentifier, name: name, url: url.standardizedFileURL)
    }

    private nonisolated static func merge(_ applications: [ApplicationReference]) -> [ApplicationReference] {
        var values = [String: ApplicationReference]()
        for application in applications {
            if let existing = values[application.bundleIdentifier] {
                if existing.url == nil, application.url != nil { values[application.bundleIdentifier] = application }
            } else {
                values[application.bundleIdentifier] = application
            }
        }
        return values.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
        }
    }
}

struct ApplicationIdentityView: View {
    let application: ApplicationReference
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            applicationIcon
                .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(application.name).lineLimit(1)
                Text(application.bundleIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !compact, let url = application.url {
                    Text(url.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var applicationIcon: some View {
        if let icon = ApplicationCatalog.icon(
            for: application.bundleIdentifier,
            fallbackName: application.name,
            applicationURL: application.url
        ) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(3)
        }
    }
}

@MainActor
private final class ApplicationDataCache {
    private struct Record: Codable {
        let bundleIdentifier: String
        var name: String
        var applicationPath: String?
        var applicationModifiedAt: Date?
        var iconFileName: String?
        var cachedAt: Date
    }

    private let iconsDirectory: URL
    private let metadataFile: URL
    private var records: [String: Record]
    private var images: [String: NSImage] = [:]

    init(directory: URL) {
        self.iconsDirectory = directory.appendingPathComponent("Icons", isDirectory: true)
        self.metadataFile = directory.appendingPathComponent("applications.json")
        try? FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataFile),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func remember(_ application: ApplicationReference) {
        let normalizedURL = application.url?.standardizedFileURL
        let modifiedAt = normalizedURL.flatMap(applicationModifiedAt)
        let existing = records[application.bundleIdentifier]
        records[application.bundleIdentifier] = Record(
            bundleIdentifier: application.bundleIdentifier,
            name: application.name,
            applicationPath: normalizedURL?.path ?? existing?.applicationPath,
            applicationModifiedAt: modifiedAt ?? existing?.applicationModifiedAt,
            iconFileName: existing?.iconFileName,
            cachedAt: Date()
        )
        persistMetadataLater()
    }

    func icon(bundleIdentifier: String, fallbackName: String, applicationURL: URL?) -> NSImage? {
        if let image = images[bundleIdentifier] { return image }

        let record = records[bundleIdentifier]
        let resolvedURL = resolveApplicationURL(
            bundleIdentifier: bundleIdentifier,
            explicitURL: applicationURL,
            cachedPath: record?.applicationPath
        )
        let modifiedAt = resolvedURL.flatMap(applicationModifiedAt)

        if let record,
           let fileName = record.iconFileName,
           modifiedAt == nil || modifiedAt == record.applicationModifiedAt,
           let cachedImage = NSImage(contentsOf: iconsDirectory.appendingPathComponent(fileName)) {
            images[bundleIdentifier] = cachedImage
            if record.applicationPath != resolvedURL?.path {
                remember(ApplicationReference(
                    bundleIdentifier: bundleIdentifier,
                    name: record.name,
                    url: resolvedURL
                ))
            }
            return cachedImage
        }

        guard let resolvedURL else {
            if let record,
               let fileName = record.iconFileName,
               let cachedImage = NSImage(contentsOf: iconsDirectory.appendingPathComponent(fileName)) {
                images[bundleIdentifier] = cachedImage
                return cachedImage
            }
            return nil
        }

        let image = NSWorkspace.shared.icon(forFile: resolvedURL.path)
        images[bundleIdentifier] = image
        let fileName = iconFileName(for: bundleIdentifier)
        records[bundleIdentifier] = Record(
            bundleIdentifier: bundleIdentifier,
            name: applicationName(at: resolvedURL) ?? fallbackName,
            applicationPath: resolvedURL.path,
            applicationModifiedAt: modifiedAt,
            iconFileName: fileName,
            cachedAt: Date()
        )
        persist(image: image, fileName: fileName)
        return image
    }

    private func resolveApplicationURL(
        bundleIdentifier: String,
        explicitURL: URL?,
        cachedPath: String?
    ) -> URL? {
        if let explicitURL, FileManager.default.fileExists(atPath: explicitURL.path) {
            return explicitURL.standardizedFileURL
        }
        if let workspaceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           FileManager.default.fileExists(atPath: workspaceURL.path) {
            return workspaceURL.standardizedFileURL
        }
        if let cachedPath, FileManager.default.fileExists(atPath: cachedPath) {
            return URL(fileURLWithPath: cachedPath).standardizedFileURL
        }
        return nil
    }

    private func applicationModifiedAt(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func applicationName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        return (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func iconFileName(for bundleIdentifier: String) -> String {
        let encoded = bundleIdentifier.utf8.map { String(format: "%02x", $0) }.joined()
        return "\(encoded).png"
    }

    private func persist(image: NSImage, fileName: String) {
        let imageData = pngData(for: image)
        let imageURL = iconsDirectory.appendingPathComponent(fileName)
        Task { @MainActor [weak self] in
            if let imageData { try? imageData.write(to: imageURL, options: .atomic) }
            self?.persistMetadata()
        }
    }

    private func persistMetadataLater() {
        Task { @MainActor [weak self] in self?.persistMetadata() }
    }

    private func persistMetadata() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: metadataFile, options: .atomic)
    }

    private func pngData(for image: NSImage) -> Data? {
        let size = 128
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:])
    }
}

struct ApplicationPickerSheet: View {
    @Environment(\.pasteoryAccentColor) private var pasteoryAccentColor
    let title: String
    let selectedBundleIdentifiers: Set<String>
    var additionalApplications: [ApplicationReference] = []
    let onSelect: (ApplicationReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var applications = [ApplicationReference]()
    @State private var query = ""
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用名称、Bundle ID 或路径", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            List(filteredApplications) { application in
                Button {
                    onSelect(application)
                    dismiss()
                } label: {
                    HStack {
                        ApplicationIdentityView(application: application)
                        Spacer(minLength: 8)
                        if selectedBundleIdentifiers.contains(application.bundleIdentifier) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(pasteoryAccentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if isLoading {
                    ProgressView("正在读取应用…")
                } else if applications.isEmpty {
                    ContentUnavailableView("没有找到应用", systemImage: "app.dashed")
                } else if filteredApplications.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("选择其他 App…") { chooseOtherApplication() }
                Spacer()
                Button("取消") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            applications = await ApplicationCatalog.discover(additional: additionalApplications)
            isLoading = false
        }
    }

    private var filteredApplications: [ApplicationReference] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(value)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(value)
                || ($0.url?.path.localizedCaseInsensitiveContains(value) == true)
        }
    }

    private func chooseOtherApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let application = ApplicationCatalog.reference(for: url) else {
            error = "无法读取这个 App 的 Bundle ID"
            return
        }
        ApplicationCatalog.rememberCustomApplication(url)
        onSelect(application)
        dismiss()
    }
}

struct ApplicationSelectionControl: View {
    @Binding var bundleIdentifier: String
    let additionalApplications: [ApplicationReference]
    var placeholder = "选择来源 App"
    var pickerTitle = "选择来源 App"

    @State private var applications = [ApplicationReference]()
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 8) {
                if let selectedApplication {
                    ApplicationIdentityView(application: selectedApplication, compact: true)
                } else {
                    Image(systemName: "app.badge.checkmark")
                    Text(placeholder)
                    Spacer()
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPicker) {
            ApplicationPickerSheet(
                title: pickerTitle,
                selectedBundleIdentifiers: bundleIdentifier.isEmpty ? [] : [bundleIdentifier],
                additionalApplications: applications
            ) { application in
                bundleIdentifier = application.bundleIdentifier
                if !applications.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
                    applications.append(application)
                }
            }
        }
        .task { applications = await ApplicationCatalog.discover(additional: additionalApplications) }
    }

    private var selectedApplication: ApplicationReference? {
        applications.first { $0.bundleIdentifier == bundleIdentifier }
            ?? additionalApplications.first { $0.bundleIdentifier == bundleIdentifier }
            ?? ApplicationCatalog.reference(forBundleIdentifier: bundleIdentifier)
            ?? (bundleIdentifier.isEmpty ? nil : ApplicationReference(bundleIdentifier: bundleIdentifier, name: bundleIdentifier, url: nil))
    }
}
