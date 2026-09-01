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

    static func discover(additional: [ApplicationReference] = []) async -> [ApplicationReference] {
        if let cachedApplications { return merge(cachedApplications + additional) }
        if let discoveryTask {
            let applications = await discoveryTask.value
            return merge(applications + additional)
        }
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
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
        makeReference(url: url)
    }

    static func rememberCustomApplication(_ url: URL) {
        var paths = Set(UserDefaults.standard.stringArray(forKey: customPathsKey) ?? [])
        paths.insert(url.standardizedFileURL.path)
        UserDefaults.standard.set(paths.sorted(), forKey: customPathsKey)
        cachedApplications = nil
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
        if let url = application.url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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

struct ApplicationPickerSheet: View {
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
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
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

    @State private var applications = [ApplicationReference]()
    @State private var showingPicker = false

    var body: some View {
        Button { showingPicker = true } label: {
            HStack(spacing: 8) {
                if let selectedApplication {
                    ApplicationIdentityView(application: selectedApplication, compact: true)
                } else {
                    Image(systemName: "app.badge.checkmark")
                    Text("选择来源 App")
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
                title: "选择来源 App",
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
            ?? (bundleIdentifier.isEmpty ? nil : ApplicationReference(bundleIdentifier: bundleIdentifier, name: bundleIdentifier, url: nil))
    }
}
