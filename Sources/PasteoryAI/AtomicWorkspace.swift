import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let d) = self { return d[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var encoded: String { String(data: (try? JSONEncoder.sorted.encode(self)) ?? Data(), encoding: .utf8) ?? "null" }
    public static func value<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: JSONEncoder.sorted.encode(value)) }
}

public struct AIToolDefinition: Encodable, Sendable {
    public struct Function: Encodable, Sendable {
        public var name: String
        public var description: String
        public var parameters: JSONValue
    }
    public var type = "function"
    public var function: Function
    public init(name: String, description: String, properties: [String: JSONValue], required: [String]) {
        function = Function(name: name, description: description, parameters: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)
        ]))
    }
    public static let all: [Self] = {
        let text: JSONValue = .object(["type": .string("string")])
        let ids: JSONValue = .object(["type": .string("array"), "items": text, "maxItems": .number(100)])
        let limit: JSONValue = .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20)])
        let evidence: JSONValue = .object(["type": .string("array"), "maxItems": .number(10), "items": .object([
            "type": .string("object"), "properties": .object(["clip_id": text, "quote": text]),
            "required": .array([.string("clip_id"), .string("quote")]), "additionalProperties": .bool(false)
        ])])
        let claims: JSONValue = .object(["type": .string("array"), "maxItems": .number(20), "items": .object([
            "type": .string("object"), "properties": .object([
                "kind": .object(["type": .string("string"), "enum": .array([.string("fact"), .string("inference"), .string("action")])]),
                "text": text, "evidence": evidence
            ]), "required": .array([.string("kind"), .string("text"), .string("evidence")]), "additionalProperties": .bool(false)
        ])])
        return [
            Self(name: "clips_get", description: "Read bounded title, body, note, source and time for known content IDs. Only supplied data may be cited.", properties: ["clip_ids": ids], required: ["clip_ids"]),
            Self(name: "clips_search", description: "Find a small number of related clips in the authorized context. Reading does not authorize changing historical content.", properties: ["query": text, "limit": limit], required: ["query"]),
            Self(name: "groups_search", description: "Find existing AI groups by meaning and keywords before creating a group. Results include topic definitions and current overview coverage.", properties: ["query": text, "limit": limit], required: ["query"]),
            Self(name: "groups_get", description: "Read an existing or staged group's definition, overview and representative members.", properties: ["group_id": text], required: ["group_id"]),
            Self(name: "groups_create", description: "Stage a new AI group. Returns a stable draft UUID usable by later tools. Then add explicit clip IDs. Do not create empty or redundant groups.", properties: ["name": text, "definition": text, "reason": text], required: ["name", "definition"]),
            Self(name: "groups_add_items", description: "Stage adding explicit current-batch clip IDs to an AI group. Preserves manual assignments and excluded items.", properties: ["group_id": text, "clip_ids": ids, "reason": text], required: ["group_id", "clip_ids"]),
            Self(name: "groups_remove_items", description: "Stage removing AI-owned memberships only, never source content. Missing items from this batch are not a reason for removal.", properties: ["group_id": text, "clip_ids": ids, "reason": text], required: ["group_id", "clip_ids"]),
            Self(name: "groups_update_overview", description: "Stage an overview of actually read member content, with explicit source IDs. This never overwrites the user's topic definition.", properties: ["group_id": text, "overview": text, "source_ids": ids], required: ["group_id", "overview", "source_ids"]),
            Self(name: "aggregations_create", description: "Stage a reusable task bundle of at least two different current-batch clips. Returns its draft UUID; no nested aggregation.", properties: ["title": text, "clip_ids": ids, "reason": text], required: ["title", "clip_ids"]),
            Self(name: "summaries_set", description: "Stage fact/inference/action claims for a staged aggregation. Each claim needs an exact quote from a read member clip.", properties: ["target_id": text, "claims": claims], required: ["target_id", "claims"])
        ]
    }()
}

/// A transient working copy, never the application database. Each mutating tool
/// stages an explicit command. The application seals and commits the resulting
/// change set; the model has no apply-plan, SQL, filesystem or shell capability.
public struct AtomicWorkspace: Sendable {
    public private(set) var draft: AIChangeSet
    public private(set) var groups: [UUID: AIGroupProfile]
    public private(set) var aggregations: [UUID: [UUID]] = [:]
    public private(set) var readDocuments: [UUID: AIClipDocument] = [:]
    private let documents: [UUID: AIClipDocument]
    private let writable: Set<UUID>
    private let reservedNames: Set<String>
    private let readLimit: Int
    private var newlyCreatedGroups = 0

    public init(documents: [AIClipDocument], writableIDs: Set<UUID>, groups: [AIGroupProfile],
                reservedNames: Set<String> = [], draft: AIChangeSet = AIChangeSet(), readLimit: Int = 150) throws {
        self.documents = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.writable = writableIDs; self.groups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        self.reservedNames = Set(reservedNames.map(Self.normalized)); self.readLimit = max(1, readLimit)
        for (id, revision) in draft.clipRevisions {
            guard self.documents[id]?.revision == revision else { throw AIError.conflict(id.uuidString) }
        }
        for (id, revision) in draft.groupRevisions {
            guard self.groups[id]?.revision == revision else { throw AIError.conflict(id.uuidString) }
        }
        self.draft = AIChangeSet()
        // Rebuild the staged catalog when resuming a multi-batch library job.
        // Previous commands are trusted only after revalidation against the new snapshot.
        for command in draft.commands { try replay(command) }
        self.draft = draft; newlyCreatedGroups = 0
    }

    public mutating func initialDocuments(_ ids: [UUID], characterBudget: Int) throws -> [AIClipDocument] {
        var left = max(0, characterBudget); var result = [AIClipDocument]()
        for id in ids {
            guard let d = documents[id] else { continue }
            guard left >= 200 else { break }
            let perItem = min(2400, max(80, left / max(1, ids.count - result.count) - 300))
            let bounded = d.bounded(to: perItem)
            left -= bounded.evidenceText.utf8.count + 250
            try recordRead(bounded); result.append(bounded)
        }
        return result
    }

    public mutating func execute(name: String, arguments: String) throws -> JSONValue {
        guard arguments.utf8.count <= 65_536 else { throw AIError.invalid("Tool arguments are too large") }
        let a = try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))
        let definition = AIToolDefinition.all.first { $0.function.name == name }
        guard let definition, case .object(let fields) = a,
              case .object(let properties) = definition.function.parameters["properties"],
              Set(fields.keys).isSubset(of: Set(properties.keys)) else { throw AIError.invalid("Unknown tool or field") }
        func text(_ key: String, max: Int = 4000) throws -> String {
            guard let value = a[key].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= max else { throw AIError.invalid("Missing or oversized \(key)") }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func id(_ key: String) throws -> UUID { guard let id = UUID(uuidString: try text(key, max: 36)) else { throw AIError.invalid("Invalid \(key)") }; return id }
        func ids(_ key: String) throws -> [UUID] {
            guard let list = a[key].array, !list.isEmpty, list.count <= 100 else { throw AIError.invalid("Invalid \(key)") }
            return try Array(Set(list.map { value in guard let v = value.string.flatMap(UUID.init(uuidString:)) else { throw AIError.invalid("Invalid content ID") }; return v })).sorted { $0.uuidString < $1.uuidString }
        }
        let limit = min(20, max(1, Int(a["limit"].number ?? 5)))
        let reason = String((a["reason"].string ?? "").prefix(1000))
        switch name {
        case "clips_get":
            let values = try ids("clip_ids").map { id -> AIClipDocument in
                guard let d = documents[id] else { throw AIError.invalid("Content outside authorized context") }; return d.bounded()
            }
            for value in values { try recordRead(value) }; return try .value(values)
        case "clips_search":
            let query = try text("query", max: 200)
            var ranked: [(score: Int, document: AIClipDocument)] = []
            for document in documents.values {
                let score = Self.match(query, document.evidenceText + " " + document.source)
                if score > 0 { ranked.append((score, document)) }
            }
            ranked.sort { a, b in a.score == b.score ? a.document.id.uuidString < b.document.id.uuidString : a.score > b.score }
            let values: [AIClipDocument] = ranked.prefix(limit).map { $0.document.bounded(to: 1200) }
            for value in values { try recordRead(value) }; return try .value(Array(values))
        case "groups_search":
            let query = try text("query", max: 200)
            var ranked: [(score: Int, group: AIGroupProfile)] = []
            for group in groups.values {
                let score = Self.match(query, group.name + " " + group.definition + " " + group.overview)
                if score > 0 { ranked.append((score, group)) }
            }
            ranked.sort { a, b in a.score == b.score ? a.group.id.uuidString < b.group.id.uuidString : a.score > b.score }
            return .array(ranked.prefix(limit).map { describe($0.group) })
        case "groups_get":
            let groupID = try id("group_id"); guard let g = groups[groupID] else { throw AIError.invalid("Unknown AI group") }
            return describe(g)
        case "groups_create":
            guard newlyCreatedGroups < 3 else { throw AIError.invalid("At most three new themes per batch") }
            let name = try text("name", max: 40), definition = try text("definition", max: 2000)
            let key = Self.normalized(name)
            guard !reservedNames.contains(key), !groups.values.contains(where: { Self.normalized($0.name) == key }) else {
                throw AIError.invalid("A group with this name exists; reuse it")
            }
            let groupID = UUID(); let cmd = AICommand(kind: .createGroup, targetID: groupID, name: name, definition: definition, reason: reason)
            try stage(cmd); newlyCreatedGroups += 1
            return .object(["group_id": .string(groupID.uuidString), "staged": .bool(true)])
        case "groups_add_items", "groups_remove_items":
            let groupID = try id("group_id"), members = try ids("clip_ids")
            try validateWritable(members)
            guard let group = groups[groupID] else { throw AIError.invalid("Unknown AI group") }
            if name == "groups_add_items" {
                guard Set(members).isDisjoint(with: group.excludedClipIDs) else { throw AIError.invalid("A member was explicitly excluded by the user") }
            } else {
                guard Set(members).isSubset(of: group.aiMemberIDs) else { throw AIError.invalid("Manual memberships cannot be removed by AI") }
            }
            try stage(AICommand(kind: name == "groups_add_items" ? .addItems : .removeItems, targetID: groupID, clipIDs: members, reason: reason))
            return .object(["staged": .bool(true), "member_count": .number(Double(groups[groupID]?.memberIDs.count ?? 0))])
        case "groups_update_overview":
            let groupID = try id("group_id"), sources = try ids("source_ids")
            guard let g = groups[groupID], Set(sources).isSubset(of: g.memberIDs), sources.allSatisfy({ readDocuments[$0] != nil }) else {
                throw AIError.invalid("Overview sources must be read members of this group")
            }
            try stage(AICommand(kind: .updateOverview, targetID: groupID, clipIDs: sources, overview: try text("overview", max: 2000)))
            return .object(["staged": .bool(true), "coverage": .number(Double(sources.count))])
        case "aggregations_create":
            let members = try ids("clip_ids"); try validateWritable(members)
            guard members.count >= 2 else { throw AIError.invalid("An aggregation needs at least two different clips") }
            let target = UUID()
            try stage(AICommand(kind: .createAggregation, targetID: target, clipIDs: members, name: try text("title", max: 120), reason: reason))
            return .object(["aggregation_id": .string(target.uuidString), "staged": .bool(true)])
        case "summaries_set":
            let target = try id("target_id")
            guard let members = aggregations[target], let rawClaims = a["claims"].array, !rawClaims.isEmpty, rawClaims.count <= 20 else {
                throw AIError.invalid("Summaries must target an aggregation staged in this run")
            }
            let claims = try rawClaims.map { raw -> AIClaim in
                guard let kind = raw["kind"].string.flatMap(AIClaim.Kind.init(rawValue:)), let text = raw["text"].string,
                      !text.isEmpty, text.count <= 1200, let rawEvidence = raw["evidence"].array, !rawEvidence.isEmpty, rawEvidence.count <= 10 else {
                    throw AIError.invalid("Invalid summary claim")
                }
                let evidence = try rawEvidence.map { ref -> AIEvidence in
                    guard let clipID = ref["clip_id"].string.flatMap(UUID.init(uuidString:)), members.contains(clipID),
                          let doc = readDocuments[clipID], let quote = ref["quote"].string,
                          !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, quote.count <= 800,
                          doc.evidenceText.contains(quote) else { throw AIError.invalid("Evidence must quote actually read member text") }
                    return AIEvidence(clipID: clipID, quote: quote)
                }
                return AIClaim(kind: kind, text: text, evidence: evidence)
            }
            try stage(AICommand(kind: .setSummary, targetID: target, claims: claims))
            return .object(["staged": .bool(true)])
        default: throw AIError.invalid("Unknown tool")
        }
    }

    public func catalog(limit: Int = 20) -> [JSONValue] { groups.values.sorted { $0.id.uuidString < $1.id.uuidString }.prefix(limit).map(describe) }
    public func finish() throws -> AIChangeSet {
        for command in draft.commands where command.kind == .createGroup {
            guard groups[command.targetID]?.memberIDs.isEmpty == false else { throw AIError.invalid("Do not create an empty AI group") }
        }
        return draft
    }
    private func describe(_ g: AIGroupProfile) -> JSONValue {
        .object(["group_id": .string(g.id.uuidString), "name": .string(g.name), "definition": .string(String(g.definition.prefix(2000))),
                 "definition_is_manual": .bool(g.definitionIsManual), "overview": .string(String(g.overview.prefix(1000))),
                 "overview_is_partial_or_stale": .bool(g.overviewIsStale), "member_count": .number(Double(g.memberIDs.count)),
                 "example_clip_ids": .array(g.memberIDs.sorted { $0.uuidString < $1.uuidString }.prefix(5).map { .string($0.uuidString) })])
    }
    private mutating func recordRead(_ d: AIClipDocument) throws {
        guard readDocuments[d.id] != nil || readDocuments.count < readLimit else { throw AIError.invalid("Context read limit reached") }
        readDocuments[d.id] = d
        if let old = draft.clipRevisions[d.id], old != d.revision { throw AIError.conflict(d.id.uuidString) }
        draft.clipRevisions[d.id] = d.revision
    }
    private func validateWritable(_ ids: [UUID]) throws {
        guard ids.allSatisfy({ writable.contains($0) && readDocuments[$0] != nil }) else { throw AIError.invalid("Only read current-batch content can be reorganized") }
    }
    private mutating func stage(_ command: AICommand) throws {
        guard draft.commands.count < 20_000 else { throw AIError.invalid("Change set is too large") }
        if let group = groups[command.targetID], draft.groupRevisions[group.id] == nil,
           !draft.commands.contains(where: { $0.kind == .createGroup && $0.targetID == group.id }) {
            draft.groupRevisions[group.id] = group.revision
        }
        try replay(command); draft.commands.append(command)
    }
    private mutating func replay(_ command: AICommand) throws {
        switch command.kind {
        case .createGroup:
            guard groups[command.targetID] == nil else { throw AIError.conflict("Draft group already exists") }
            groups[command.targetID] = AIGroupProfile(id: command.targetID, name: command.name, definition: command.definition)
        case .addItems:
            guard groups[command.targetID] != nil else { throw AIError.invalid("Unknown group") }
            let newlyAdded = Set(command.clipIDs).subtracting(groups[command.targetID]!.memberIDs)
            groups[command.targetID]?.memberIDs.formUnion(newlyAdded); groups[command.targetID]?.aiMemberIDs.formUnion(newlyAdded)
        case .removeItems:
            guard groups[command.targetID] != nil else { throw AIError.invalid("Unknown group") }
            groups[command.targetID]?.memberIDs.subtract(command.clipIDs); groups[command.targetID]?.aiMemberIDs.subtract(command.clipIDs)
        case .updateOverview:
            guard var g = groups[command.targetID] else { throw AIError.invalid("Unknown group") }
            g.overview = command.overview
            g.overviewMemberFingerprint = Set(command.clipIDs) == g.memberIDs ? g.membershipFingerprint : ""
            groups[g.id] = g
        case .createAggregation: aggregations[command.targetID] = command.clipIDs
        case .setSummary: break
        }
    }
    private static func normalized(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    private static func match(_ query: String, _ text: String) -> Int {
        let q = normalized(query), t = normalized(text)
        guard !q.isEmpty else { return 0 }
        var terms = q.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        let chars = Array(q)
        if chars.count >= 2 { terms += (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) } }
        return Set(terms).filter { !$0.isEmpty && t.contains($0) }.reduce(0) { $0 + $1.count }
    }
}
