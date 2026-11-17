import Foundation
import PasteoryAI
import UniformTypeIdentifiers

public struct AIFileResource: Codable, Equatable, Sendable {
    public var kind: String
    public var path: String
    public var directory: String
    public var exists: Bool
    public var isDirectory: Bool
    public var encoding: String
    public var representationID: UUID?
    enum CodingKeys: String, CodingKey { case kind, path, directory, exists, encoding; case isDirectory = "is_directory", representationID = "representation_id" }
}

public struct AIFileTaskItem: Codable, Equatable, Sendable {
    public var lastCopiedAt: String?
    public var lastPastedAt: String?
    public var itemID: String
    public var clipID: UUID
    public var kind: String
    public var title: String
    public var body: String
    public var note: String
    public var source: String
    public var revision: String
    public var contentRevision: String
    public var imageReferences: [AIFileResource]
    public var fileReferences: [AIFileResource]
    public var sourceDirectories: [String]
    public var sharingExcluded: Bool
    public var originalHTMLRepresentationID: UUID?
    enum CodingKeys: String, CodingKey {
        case kind, title, body, note, source, revision
        case itemID = "item_id", clipID = "clip_id", contentRevision = "content_revision"
        case imageReferences = "image_references", fileReferences = "file_references", sourceDirectories = "source_directories"
        case sharingExcluded = "sharing_excluded", originalHTMLRepresentationID = "original_html_representation_id"
        case lastCopiedAt = "last_copied_at", lastPastedAt = "last_pasted_at"
    }
}

public struct AIFileTaskInput: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var taskID: UUID
    public var items: [AIFileTaskItem]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", taskID = "task_id", items }
}

public struct AIFileTaskPlan: Codable, Sendable {
    public struct Group: Codable, Sendable {
        public var key: String
        public var name: String
        public var definition: String
        public var existingGroupID: UUID?
        public var overview: String?
        public var overviewSourceItemIDs: [String]?
        enum CodingKeys: String, CodingKey {
            case key, name, definition, overview
            case existingGroupID = "existing_group_id", overviewSourceItemIDs = "overview_source_item_ids"
        }
    }
    public struct Assignment: Codable, Sendable {
        public var itemID: String
        public var groupKeys: [String]
        public var reason: String?
        enum CodingKeys: String, CodingKey { case itemID = "item_id", groupKeys = "group_keys", reason }
    }
    public var taskID: UUID
    public var preserveExistingMemberships: Bool
    public var groups: [Group]
    public var assignments: [Assignment]
    public var notes: [String]?
    enum CodingKeys: String, CodingKey { case taskID = "task_id", preserveExistingMemberships = "preserve_existing_memberships", groups, assignments, notes }

    public func changeSet(input: AIFileTaskInput, groups catalog: [UUID: AIGroupProfile],
                          reservedNames: Set<String> = [], policy: AIOrganizationPolicy = AIOrganizationPolicy()) throws -> AIChangeSet {
        guard taskID == input.taskID, preserveExistingMemberships else { throw AIError.invalid("Wrong task ID or membership policy") }
        let byID = Dictionary(uniqueKeysWithValues: input.items.map { ($0.itemID, $0) })
        let ids = assignments.map(\.itemID), keys = groups.map(\.key)
        guard ids.count == byID.count, Set(ids).count == ids.count, Set(ids) == Set(byID.keys), Set(keys).count == keys.count else {
            throw AIError.invalid("Every input item_id must appear exactly once; group keys must be unique")
        }
        guard groups.count <= input.items.count else { throw AIError.invalid("Empty or excessive groups") }
        let assignedCount = assignments.filter { !$0.groupKeys.isEmpty }.count
        let minimum = assignedCount >= 6 * policy.minimumThemeMembers ? 6 : 0
        let newCount = groups.filter { $0.existingGroupID == nil }.count
        guard groups.count <= policy.maximumGroupCount, catalog.count + newCount >= minimum else {
            throw AIError.invalid("The theme plan must respect the user's target of \(policy.targetGroupCount) groups: \(minimum)–\(policy.maximumGroupCount) groups for this input")
        }
        guard newCount == 0 || catalog.count + newCount <= policy.maximumGroupCount else {
            throw AIError.invalid("Creating these groups would exceed the user's maximum of \(policy.maximumGroupCount). Reuse existing groups or reorganize the selected themes.")
        }
        var members = [String: [UUID]](), mapped = [String: UUID](), names = Set<String>(), reused = Set<UUID>()
        var result = AIChangeSet(); result.fileTaskID = taskID; result.isThemeReview = true; result.inputCount = input.items.count
        let normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let reserved = Set(reservedNames.map(normalize))
        for group in groups {
            guard !group.key.isEmpty, !normalize(group.name).isEmpty, group.name.count <= 40,
                  !group.definition.isEmpty, group.definition.count <= 2000, (group.overview?.count ?? 0) <= 2000,
                  names.insert(normalize(group.name)).inserted else { throw AIError.invalid("Invalid or duplicate group name/definition") }
            if let id = group.existingGroupID {
                guard let profile = catalog[id], reused.insert(id).inserted else { throw AIError.invalid("existing_group_id is not an existing group. Draft themes must use null and be created as new groups.") }
                mapped[group.key] = id; result.groupRevisions[id] = profile.revision
            } else {
                guard !reserved.contains(normalize(group.name)) else { throw AIError.invalid("A collection with this name already exists; reuse its AI group or choose a distinct name") }
                let id = UUID(); mapped[group.key] = id
                result.commands.append(.init(kind: .createGroup, targetID: id, name: group.name, definition: group.definition))
            }
        }
        var decisions = [UUID: AIClassificationDecision]()
        for assignment in assignments {
            guard let item = byID[assignment.itemID], Set(assignment.groupKeys).count == assignment.groupKeys.count,
                  Set(assignment.groupKeys).isSubset(of: Set(keys)),
                  !assignment.groupKeys.isEmpty || !(assignment.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.sharingExcluded || assignment.groupKeys.isEmpty else { throw AIError.invalid("Invalid membership or missing unassigned reason for " + assignment.itemID) }
            var groupIDs = Set<UUID>()
            for key in assignment.groupKeys {
                guard let id = mapped[key], catalog[id]?.excludedClipIDs.contains(item.clipID) != true else { throw AIError.invalid("Membership conflicts with a user exclusion") }
                members[key, default: []].append(item.clipID); groupIDs.insert(id)
            }
            if !item.sharingExcluded { result.clipRevisions[item.clipID] = item.revision }
            decisions[item.clipID] = AIClassificationDecision(revision: item.contentRevision, groupIDs: groupIDs,
                outcome: groupIDs.isEmpty ? .unmatched : .assigned, reason: String((assignment.reason ?? "").prefix(1000)))
        }
        for group in groups {
            guard let id = mapped[group.key], let ids = members[group.key], !ids.isEmpty else { throw AIError.invalid("A group has no assigned members") }
            if group.existingGroupID == nil, ids.count < policy.minimumThemeMembers {
                throw AIError.invalid("A new theme needs at least \(policy.minimumThemeMembers) distinct supporting items; leave insufficient evidence ungrouped")
            }
            for offset in stride(from: 0, to: ids.count, by: 100) {
                result.commands.append(.init(kind: .addItems, targetID: id, clipIDs: Array(ids[offset..<min(offset + 100, ids.count)])))
            }
            if let overview = group.overview, !overview.isEmpty {
                let sources = group.overviewSourceItemIDs ?? []
                guard !sources.isEmpty, Set(sources).count == sources.count,
                      sources.allSatisfy({ byID[$0].map { ids.contains($0.clipID) } == true }) else { throw AIError.invalid("Overview needs explicit member item IDs") }
                result.commands.append(.init(kind: .updateOverview, targetID: id, clipIDs: sources.compactMap { byID[$0]?.clipID }, overview: overview))
            }
        }
        result.decisions = decisions
        return result
    }

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        func check(_ value: JSONValue, allowed: Set<String>) throws {
            guard case .object(let object) = value, Set(object.keys).isSubset(of: allowed) else { throw AIError.invalid("Unexpected plan fields") }
        }
        try check(value, allowed: ["task_id", "preserve_existing_memberships", "groups", "assignments", "notes"])
        for g in value["groups"].array ?? [] { try check(g, allowed: ["key", "name", "definition", "existing_group_id", "overview", "overview_source_item_ids"]) }
        for a in value["assignments"].array ?? [] { try check(a, allowed: ["item_id", "group_keys", "reason"]) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public enum AIFileTaskExporter {
    public static func input(clips: [Clip], taskID: UUID, configuration: AIConfiguration, directories: AppDirectories,
                             aliases: [UUID: String] = [:], includeActivityDates: Bool = false) async throws -> AIFileTaskInput {
        let store = AttachmentStore(directories: directories)
        let timestampFormatter = ISO8601DateFormatter()
        var records = [AIFileTaskItem]()
        let preference = ["public.utf8-plain-text", "public.utf16-plain-text", "public.url", "public.text", "NSStringPboardType", "public.html", "public.rtf"]
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            var text = [String](), images = [AIFileResource](), files = [AIFileResource](), htmlID: UUID?
            for item in clip.items.sorted(by: { $0.order < $1.order }) {
                let reps = item.representations
                let candidates = reps.filter { preference.contains($0.uti) || UTType($0.uti)?.conforms(to: .text) == true || UTType($0.uti)?.conforms(to: .sourceCode) == true }
                    .sorted { (preference.firstIndex(of: $0.uti) ?? 3) < (preference.firstIndex(of: $1.uti) ?? 3) }
                if let rep = candidates.first {
                    let data = try await store.data(for: rep)
                    guard let value = rep.uti == "public.utf16-plain-text" ? String(data: data, encoding: .utf16) : (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)) else { throw AIError.invalid("Undecodable source text") }
                    text.append(value); if rep.uti == "public.html" { htmlID = rep.id }
                } else if ![.image, .file].contains(clip.primaryKind) {
                    for rep in reps where UTType(rep.uti)?.conforms(to: .image) != true && rep.uti != "com.adobe.pdf" {
                        if let value = String(data: try await store.data(for: rep), encoding: .utf8) {
                            text.append("[Original representation: " + rep.uti + "]\n" + value)
                        }
                    }
                }
                let imagePreference = ["public.png", "public.jpeg", "public.heic", "public.tiff"]
                if let rep = reps.filter({ UTType($0.uti)?.conforms(to: .image) == true }).sorted(by: { (imagePreference.firstIndex(of: $0.uti) ?? 99) < (imagePreference.firstIndex(of: $1.uti) ?? 99) }).first,
                   let resource = originalResource(rep, directories: directories) { images.append(resource) }
                for rep in reps where ["public.file-url", "NSFilenamesPboardType"].contains(rep.uti) {
                    for url in FileReferenceDecoder.urls(from: try await store.data(for: rep), uti: rep.uti) {
                        if let path = FileReferenceDecoder.stablePath(for: url), !files.contains(where: { $0.path == path }) { files.append(fileResource(path)) }
                    }
                }
            }
            if files.isEmpty { files = (clip.effectiveFileMetadata?.filePaths ?? []).map(fileResource) }
            var body = text.isEmpty ? clip.previewText : text.joined(separator: "\n\n--- clipboard item ---\n\n")
            // Replace only HTML image data URIs. Preserve every text character
            // and identify the original representation for exact retrieval.
            if htmlID != nil, images.count == 1,
               let regex = try? NSRegularExpression(pattern: #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+"#) {
                let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
                if matches.count == 1, let range = Range(matches[0].range, in: body) { body.replaceSubrange(range, with: URL(fileURLWithPath: images[0].path).absoluteString) }
            }
            if configuration.includeImageText == true, !clip.recognizedImageText.isEmpty { body += "\n\n[Local image OCR]\n" + clip.recognizedImageText }
            let note = configuration.includeNotes ? (configuration.includeImageText == true ? clip.note : clip.noteWithoutAutomaticOCR) : ""
            let excluded = !clip.mayParticipateInAI || !Clip.isSafeAIText(body) || !Clip.isSafeAIText(note)
            records.append(AIFileTaskItem(lastCopiedAt: includeActivityDates && !excluded ? timestampFormatter.string(from: clip.lastCopiedAt) : nil,
                lastPastedAt: (includeActivityDates && !excluded ? clip.lastPastedAt : nil).map { timestampFormatter.string(from: $0) },
                itemID: aliases[clip.id] ?? String(format: "c%04d", index + 1), clipID: clip.id, kind: clip.primaryKind.rawValue,
                title: excluded ? "" : clip.displayTitle, body: excluded ? "[Excluded by content sharing policy]" : body,
                note: excluded ? "" : note, source: configuration.includeSource && !excluded ? clip.source.appName : "",
                revision: clip.aiRevision, contentRevision: clip.aiContentRevision, imageReferences: excluded ? [] : images,
                fileReferences: excluded ? [] : files, sourceDirectories: excluded ? [] : Array(Set(files.map(\.directory))).sorted(), sharingExcluded: excluded,
                originalHTMLRepresentationID: excluded ? nil : htmlID))
        }
        return AIFileTaskInput(taskID: taskID, items: records)
    }

    public static func originalResource(_ rep: ClipRepresentation, directories: AppDirectories) -> AIFileResource? {
        var path: URL, encoding = "raw"
        switch rep.storage {
        case .inline: return nil
        case .attachment(let relative, let checksum, _):
            path = directories.attachments.appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: path.path) { path = directories.archives.appendingPathComponent("AIContent/Packed/" + checksum + ".packed"); encoding = "lzfse" }
        case .archived(let relative, _, _): path = directories.archives.appendingPathComponent(relative); encoding = "lzfse"
        }
        return AIFileResource(kind: "image", path: path.path, directory: path.deletingLastPathComponent().path,
                              exists: FileManager.default.fileExists(atPath: path.path), isDirectory: false, encoding: encoding, representationID: rep.id)
    }
    private static func fileResource(_ path: String) -> AIFileResource {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return AIFileResource(kind: "file", path: path, directory: directory.boolValue ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path,
                              exists: exists, isDirectory: directory.boolValue, encoding: "raw")
    }
}
