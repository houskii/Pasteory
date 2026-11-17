import Foundation

public enum ContentStage: String, Codable, CaseIterable, Sendable {
    case active, retained, archived
    public var title: String {
        switch self { case .active: "活跃度较高"; case .retained: "留存"; case .archived: "归档" }
    }
}

public enum LifecyclePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case aggressive, standard, conservative, custom
    public var id: String { rawValue }
    public var title: String {
        switch self { case .aggressive: "激进"; case .standard: "标准"; case .conservative: "保守"; case .custom: "自定义" }
    }
}

/// Human activity only. Organization, summaries, background scans and automatic
/// pasteboard replays must not call record(). Times are facts; scores are caches.
public struct ContentActivity: Codable, Hashable, Sendable {
    public enum Event: String, Codable, Sendable { case copy, paste, open, edit }
    public struct Sample: Codable, Hashable, Sendable {
        public var event: Event
        public var at: Date
        public init(_ event: Event, at: Date) { self.event = event; self.at = at }
    }
    public var lastUsedAt: Date
    public var samples: [Sample]
    /// Identifies the acquisition copy, which starts at 100% without a reuse bonus.
    /// Optional so activity saved by older versions remains readable.
    public var capturedAt: Date?
    public init(lastUsedAt: Date, samples: [Sample] = [], capturedAt: Date? = nil) {
        self.lastUsedAt = lastUsedAt; self.samples = samples; self.capturedAt = capturedAt
    }
    public mutating func record(_ event: Event, at date: Date = Date()) {
        lastUsedAt = max(lastUsedAt, date)
        samples.append(Sample(event, at: date))
        let cutoff = date.addingTimeInterval(-366 * 86_400)
        samples = Array(samples.filter { $0.at >= cutoff }.suffix(4096))
    }
}

public struct ActivityScoringParameters: Codable, Equatable, Sendable {
    public var halfLifeHours: Double = 48
    public var copyIncrement: Double = 0.4
    public var pasteIncrement: Double = 0.8
    public static let maximumBonus: Double = 3
    public static let bonusHalfLifeDays: Double = 7

    public init() {}
    public func validate() throws {
        guard halfLifeHours.isFinite, (1...8760).contains(halfLifeHours),
              copyIncrement.isFinite, (0...Self.maximumBonus).contains(copyIncrement),
              pasteIncrement.isFinite, (0...Self.maximumBonus).contains(pasteIncrement) else {
            throw AIError.invalid("Invalid activity scoring parameters")
        }
    }
}

public struct LifecyclePolicy: Codable, Equatable, Sendable {
    public var preset: LifecyclePreset = .standard
    public var version: Int = 2
    public var deprioritizeDays: Double = 7
    public var compressionDays: Double = 14
    public var archiveDays: Double = 60
    // Absent in old settings. All installations adopt the new defaults without
    // rewriting clip payloads or rebuilding the repository on panel activation.
    public var activityScoring: ActivityScoringParameters?
    public var scoringParameters: ActivityScoringParameters {
        get { activityScoring ?? ActivityScoringParameters() }
        set { activityScoring = newValue == ActivityScoringParameters() ? nil : newValue }
    }
    public var topK: Int = 5
    public var topKWeight: Double = 0.6
    public var activeThreshold: Double = 0.65
    public var archiveThreshold: Double = 0.10

    public init() {}
    public static func preset(_ value: LifecyclePreset) -> Self {
        var p = Self(); p.preset = value
        switch value {
        case .aggressive:
            p.deprioritizeDays = 3; p.compressionDays = 7; p.archiveDays = 30
            p.topKWeight = 0.35
        case .conservative:
            p.deprioritizeDays = 14; p.compressionDays = 30; p.archiveDays = 120
            p.topKWeight = 0.75
        case .standard, .custom: break
        }
        return p
    }
    public func validate() throws {
        try scoringParameters.validate()
        let numbers = [deprioritizeDays, compressionDays, archiveDays, topKWeight, activeThreshold, archiveThreshold]
        guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 }), deprioritizeDays >= 1,
              deprioritizeDays <= compressionDays, compressionDays <= archiveDays, archiveDays <= 3650,
              (1...100).contains(topK),
              topKWeight <= 1, archiveThreshold < activeThreshold, activeThreshold <= 1 else {
            throw AIError.invalid("Invalid lifecycle policy")
        }
    }
    public var fingerprint: String { AIHash.digest((try? JSONEncoder.sorted.encode(self)) ?? Data()) }

    public func evaluate(_ activity: ContentActivity, now: Date = Date(), calendar _: Calendar = .current) -> ActivityEvaluation {
        let age = max(0, now.timeIntervalSince(activity.lastUsedAt) / 86_400)
        let parameters = scoringParameters
        let cutoff = now.addingTimeInterval(-366 * 86_400)
        let events = activity.samples.filter { $0.at >= cutoff && $0.at <= now && ($0.event == .copy || $0.event == .paste) }
            .sorted { $0.at < $1.at }
        var bonus = 0.0, bonusAt: Date?, skippedAcquisition = false
        for sample in events {
            if !skippedAcquisition, sample.event == .copy, sample.at == activity.capturedAt {
                skippedAcquisition = true
                continue
            }
            if let previous = bonusAt {
                bonus *= pow(0.5, max(0, sample.at.timeIntervalSince(previous)) / (ActivityScoringParameters.bonusHalfLifeDays * 86_400))
            }
            let increment = sample.event == .paste ? parameters.pasteIncrement : parameters.copyIncrement
            bonus = min(ActivityScoringParameters.maximumBonus, bonus + max(0, increment))
            bonusAt = sample.at
        }
        if let previous = bonusAt {
            bonus *= pow(0.5, max(0, now.timeIntervalSince(previous)) / (ActivityScoringParameters.bonusHalfLifeDays * 86_400))
        }
        // Explicit opens and edits refresh lastUsedAt but never add copy/paste
        // credit. Bonus decay stays anchored to its own event timestamps.
        let coefficient = 1 + bonus
        let raw = pow(0.5, age / (max(1, parameters.halfLifeHours) / 24 * coefficient))
        let score = min(1, max(0, raw.isFinite ? raw : 0))
        let stage: ContentStage = age >= archiveDays ? .archived : age >= deprioritizeDays ? .retained : .active
        return ActivityEvaluation(score: score, stage: stage, ageDays: age,
                                  compressionEligible: age >= compressionDays, policyVersion: fingerprint)
    }

    public func group(_ evaluations: [ActivityEvaluation]) -> GroupActivity {
        guard !evaluations.isEmpty else { return GroupActivity(score: 0, stage: .archived, counts: [:]) }
        let scores = evaluations.map(\.score).sorted(by: >)
        let leading = scores.prefix(max(1, topK))
        let kMean = leading.reduce(0, +) / Double(leading.count)
        let mean = scores.reduce(0, +) / Double(scores.count)
        let coefficient = min(1, max(0, topKWeight)) * kMean + (1 - min(1, max(0, topKWeight))) * mean
        let stage: ContentStage = coefficient >= activeThreshold ? .active : coefficient >= archiveThreshold ? .retained : .archived
        return GroupActivity(score: coefficient, stage: stage,
                             counts: Dictionary(grouping: evaluations, by: \.stage).mapValues(\.count))
    }
}

public struct ActivityEvaluation: Codable, Hashable, Sendable {
    public var score: Double
    public var stage: ContentStage
    public var ageDays: Double
    public var compressionEligible: Bool
    public var policyVersion: String
}
public struct GroupActivity: Codable, Equatable, Sendable {
    public var score: Double
    public var stage: ContentStage
    public var counts: [ContentStage: Int]
}

public enum ActivityPercentile {
    /// The percentage includes all entries tied at the same score.
    public static func ranks(_ scores: [UUID: Double]) -> [UUID: Int] {
        let ordered = scores.filter { $0.value.isFinite }.sorted { $0.value > $1.value }
        guard !ordered.isEmpty else { return [:] }
        var result = [UUID: Int](), start = 0
        while start < ordered.count {
            var end = start + 1
            while end < ordered.count && ordered[end].value == ordered[start].value { end += 1 }
            let percent = min(100, max(1, Int(ceil(Double(end) * 100 / Double(ordered.count)))))
            for index in start..<end { result[ordered[index].key] = percent }
            start = end
        }
        return result
    }
}
