import Foundation

public struct AIOrganizationPolicy: Codable, Equatable, Sendable {
    public var recommendedCount = 3
    public var targetGroupCount = 7
    public var maximumGroupCount = 8
    public var minimumThemeMembers = 3
    public var idleEnabled = false
    public var weeklyReviewEnabled = true
    public var idleStartHour = 1
    public var idleEndHour = 2
    public var reviewIntervalDays = 7
    public var idleSeconds = 300.0
    public var nightlyItemLimit = 100
    public var nightlySeconds = 600.0
    public var nightlyTokenLimit = 300_000
    public init() {}
    public func validate() throws {
        guard (1...8).contains(recommendedCount), (6...8).contains(targetGroupCount), maximumGroupCount == 8,
              minimumThemeMembers >= 3, (0...22).contains(idleStartHour), (1...23).contains(idleEndHour),
              idleEndHour > idleStartHour, (1...90).contains(reviewIntervalDays),
              idleSeconds.isFinite, idleSeconds >= 60, (1...1000).contains(nightlyItemLimit),
              nightlySeconds.isFinite, nightlySeconds >= 60, nightlyTokenLimit >= 1000 else {
            throw AIError.invalid("Check the theme count and idle schedule")
        }
    }
    public func isIdleWindow(at date: Date, calendar: Calendar = .current) -> Bool {
        (idleStartHour..<idleEndHour).contains(calendar.component(.hour, from: date))
    }
    public func reviewIsDue(lastReview: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastReview else { return true }
        return now >= (calendar.date(byAdding: .day, value: reviewIntervalDays, to: lastReview) ?? .distantFuture)
    }
}

public struct AIDirtyContent: Codable, Equatable, Sendable {
    public var revision: String
    public var firstChangedAt: Date
    public var lastChangedAt: Date
    public init(revision: String, at date: Date) { self.revision = revision; firstChangedAt = date; lastChangedAt = date }
}

public struct AIClassificationDecision: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case assigned, unmatched, candidate }
    public var revision: String
    public var groupIDs: Set<UUID>
    public var outcome: Outcome
    public var reason: String
    public var date: Date
    public var catalogFingerprint: String
    public var promptFingerprint: String
    public init(revision: String, groupIDs: Set<UUID> = [], outcome: Outcome, reason: String,
                date: Date = Date(), catalogFingerprint: String = "", promptFingerprint: String = "") {
        self.revision = revision; self.groupIDs = groupIDs; self.outcome = outcome; self.reason = reason
        self.date = date; self.catalogFingerprint = catalogFingerprint; self.promptFingerprint = promptFingerprint
    }
}

public struct AIThemeCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var definition: String
    public var supportRevisions: [UUID: String]
    public var updatedAt = Date()
    public init(name: String, definition: String, supportRevisions: [UUID: String]) {
        self.name = name; self.definition = definition; self.supportRevisions = supportRevisions
    }
    public var key: String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct AIAutomationState: Codable, Equatable, Sendable {
    public var dirty: [UUID: AIDirtyContent] = [:]
    public var decisions: [UUID: AIClassificationDecision] = [:]
    public var candidates: [AIThemeCandidate] = []
    public var recommendedIDs: [UUID] = []
    public var protectedUntil: [UUID: Date] = [:]
    public var groupOpenedAt: [UUID: Date] = [:]
    public var viewedGroupMembers: [UUID: Set<UUID>]?
    public var lastNightlyDate: Date?
    public var lastReviewAt: Date?
    public var nightlyBudget: AINightlyBudget?
    public var requestedGroupReviews: Set<UUID>?
    public init() {}
    public mutating func enqueue(id: UUID, revision: String, at date: Date = Date()) {
        if decisions[id]?.revision == revision { return }
        if var previous = dirty[id] {
            guard previous.revision != revision else { return }
            previous.revision = revision; previous.lastChangedAt = date; dirty[id] = previous
        } else { dirty[id] = AIDirtyContent(revision: revision, at: date) }
    }
    public func incrementalIDs(at date: Date, limit: Int = 1000) -> [UUID] {
        guard !dirty.isEmpty, let oldest = dirty.values.map(\.firstChangedAt).min(),
              let newest = dirty.values.map(\.lastChangedAt).max(), date.timeIntervalSince(newest) >= 30,
              dirty.count >= 5 || date.timeIntervalSince(oldest) >= 120 else { return [] }
        return Array(dirty.sorted {
            $0.value.firstChangedAt == $1.value.firstChangedAt ? $0.key.uuidString < $1.key.uuidString : $0.value.firstChangedAt < $1.value.firstChangedAt
        }.prefix(limit).map(\.key))
    }
    public mutating func mergeCandidates(_ proposed: [AIThemeCandidate]) {
        for candidate in proposed {
            if let index = candidates.firstIndex(where: { $0.key == candidate.key }) {
                candidates[index].supportRevisions.merge(candidate.supportRevisions) { _, new in new }
                candidates[index].updatedAt = candidate.updatedAt
            } else { candidates.append(candidate) }
        }
        candidates = Array(candidates.sorted { $0.updatedAt > $1.updatedAt }.prefix(100))
    }
}

public struct AINightlyBudget: Codable, Equatable, Sendable {
    public var day: Date
    public var startedAt: Date
    public var processedIDs: Set<UUID> = []
    public init(now: Date, calendar: Calendar = .current) { day = calendar.startOfDay(for: now); startedAt = now }
    public func exhausted(policy: AIOrganizationPolicy, now: Date, tokens: Int) -> Bool {
        processedIDs.count >= policy.nightlyItemLimit || now.timeIntervalSince(startedAt) >= policy.nightlySeconds || tokens >= policy.nightlyTokenLimit
    }
}

public struct AIJobOrganization: Codable, Equatable, Sendable {
    public var trigger: String
    public var startedAt = Date()
    public var revisions: [UUID: String]
    public var protectedGroupIDs: Set<UUID>
    public var review = false
    public var semanticFingerprint: String?
    public var requiresThemePlan: Bool?
    public init(trigger: String, revisions: [UUID: String], protectedGroupIDs: Set<UUID> = [], review: Bool = false) {
        self.trigger = trigger; self.revisions = revisions; self.protectedGroupIDs = protectedGroupIDs; self.review = review
    }
}

public struct AIAnalysisRules: Equatable, Sendable {
    public var allowNewGroups = false
    public var allowReassignment = false
    public var protectedGroupIDs: Set<UUID> = []
    public var maximumGroups = 8
    public var minimumMembers = 3
    public var allowOverviewRefresh = false
    public init() {}
}

public enum AIThemeCatalog {
    public static func configurationFingerprint(_ configuration: AIConfiguration) -> String {
        AIHash.fingerprint([configuration.endpoint, configuration.model, configuration.reasoning, configuration.prompt,
                            String(configuration.includeNotes), String(configuration.includeSource), String(configuration.organizationPolicy.targetGroupCount)])
    }
    public static func fingerprint(_ groups: [AIGroupProfile]) -> String {
        // Membership and overview edits do not invalidate unmatched results.
        AIHash.fingerprint(groups.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            [$0.id.uuidString, $0.name, $0.definition, String($0.definitionVersion)]
        })
    }
}

public enum AIGroupProtection {
    public static func ids(groups: [AIGroupProfile], automation: AIAutomationState, activities: [UUID: ContentActivity],
                           births: [UUID: Date] = [:], reading: Set<UUID> = [], now: Date = Date()) -> Set<UUID> {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        var protected = reading.union(automation.recommendedIDs)
        for group in groups {
            let birth = group.createdAt ?? births[group.id] ?? now
            let used = group.memberIDs.contains { id in
                activities[id]?.samples.contains { $0.at >= max(cutoff, birth) && $0.at <= now } == true
            }
            if group.retained || group.nameIsManual || group.definitionIsManual || !group.memberIDs.subtracting(group.aiMemberIDs).isEmpty || used ||
                (automation.groupOpenedAt[group.id] ?? .distantPast) >= cutoff || (automation.protectedUntil[group.id] ?? .distantPast) > now {
                protected.insert(group.id)
            }
        }
        return protected
    }
}
