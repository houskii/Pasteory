import Foundation

public struct AIStorySection: Codable, Hashable, Sendable, Identifiable {
    public var title: String
    public var text: String
    public var evidence: [AIEvidence]
    public var id: String { AIHash.fingerprint([title, text] + evidence.map { $0.clipID.uuidString + $0.quote }) }
    public init(title: String, text: String, evidence: [AIEvidence]) {
        self.title = title; self.text = text; self.evidence = evidence
    }
}

public struct AIStoryReport: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var introduction: String
    public var recentWork: [AIStorySection]
    public var observations: [AIStorySection]
    public var encouragement: String
    public var periodStart: Date
    public var periodEnd: Date
    public var generatedAt: Date
    public var sourceCount: Int
    public var sourceRevisions: [UUID: String]
    public var promptVersion: Int?
    public var sharingFingerprint: String?
    public init(id: UUID, title: String, introduction: String, recentWork: [AIStorySection], observations: [AIStorySection],
                encouragement: String, periodStart: Date, periodEnd: Date, generatedAt: Date = Date(),
                sourceCount: Int, sourceRevisions: [UUID: String]) {
        self.id = id; self.title = title; self.introduction = introduction; self.recentWork = recentWork
        self.observations = observations; self.encouragement = encouragement; self.periodStart = periodStart
        self.periodEnd = periodEnd; self.generatedAt = generatedAt; self.sourceCount = sourceCount; self.sourceRevisions = sourceRevisions
    }
}

public struct AIStoryCheckpoint: Codable, Equatable, Sendable {
    public var id: UUID
    public var periodStart: Date
    public var periodEnd: Date
    public var language: String
    public var sharingFingerprint: String
    public var promptVersion: Int?
    public init(id: UUID = UUID(), periodStart: Date, periodEnd: Date, language: String, sharingFingerprint: String) {
        self.id = id; self.periodStart = periodStart; self.periodEnd = periodEnd
        self.language = language; self.sharingFingerprint = sharingFingerprint
        self.promptVersion = AIStorySchedule.promptVersion
    }
    public static func sharingFingerprint(_ configuration: AIConfiguration) -> String {
        AIHash.fingerprint([configuration.includeNotes, configuration.includeSource,
                            configuration.includeImageText == true, configuration.allowOriginalResourceRead != false])
    }
}

public enum AIStorySchedule {
    public static let promptVersion = 2
    public static let interval: TimeInterval = 7 * 86_400
    public static func isDue(_ latest: AIStoryReport?, now: Date) -> Bool {
        guard let latest, latest.promptVersion == promptVersion else { return true }
        return now.timeIntervalSince(latest.periodEnd) >= interval
    }
}
