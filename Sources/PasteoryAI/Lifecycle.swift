import Foundation

public enum ContentStage: String, Codable, CaseIterable, Sendable {
    case active, retained, archived
    public var title: String {
        switch self { case .active: "活跃"; case .retained: "留存"; case .archived: "归档" }
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
    public init(lastUsedAt: Date, samples: [Sample] = []) {
        self.lastUsedAt = lastUsedAt; self.samples = samples
    }
    public mutating func record(_ event: Event, at date: Date = Date()) {
        lastUsedAt = max(lastUsedAt, date)
        samples.append(Sample(event, at: date))
        let cutoff = date.addingTimeInterval(-366 * 86_400)
        samples = Array(samples.filter { $0.at >= cutoff }.suffix(4096))
    }
}

public struct LifecyclePolicy: Codable, Equatable, Sendable {
    public var preset: LifecyclePreset = .standard
    public var version: Int = 1
    public var deprioritizeDays: Double = 7
    public var compressionDays: Double = 14
    public var archiveDays: Double = 60
    public var frequencyWindowDays: Int = 30
    public var recencyWeight: Double = 0.60
    public var frequencyWeight: Double = 0.25
    public var activeDaysWeight: Double = 0.15
    public var copyWeight: Double = 1
    public var pasteWeight: Double = 2
    public var openWeight: Double = 1
    public var editWeight: Double = 1.5
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
            p.recencyWeight = 0.75; p.frequencyWeight = 0.15; p.activeDaysWeight = 0.10; p.topKWeight = 0.35
        case .conservative:
            p.deprioritizeDays = 14; p.compressionDays = 30; p.archiveDays = 120
            p.recencyWeight = 0.45; p.frequencyWeight = 0.35; p.activeDaysWeight = 0.20; p.topKWeight = 0.75
        case .standard, .custom: break
        }
        return p
    }
    public func validate() throws {
        let numbers = [deprioritizeDays, compressionDays, archiveDays, recencyWeight, frequencyWeight,
                       activeDaysWeight, copyWeight, pasteWeight, openWeight, editWeight, topKWeight,
                       activeThreshold, archiveThreshold]
        guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 }), deprioritizeDays >= 1,
              deprioritizeDays <= compressionDays, compressionDays <= archiveDays, archiveDays <= 3650,
              (1...366).contains(frequencyWindowDays), (1...100).contains(topK),
              recencyWeight + frequencyWeight + activeDaysWeight > 0,
              topKWeight <= 1, archiveThreshold < activeThreshold, activeThreshold <= 1 else {
            throw AIError.invalid("Invalid lifecycle policy")
        }
    }
    public var fingerprint: String { AIHash.digest((try? JSONEncoder.sorted.encode(self)) ?? Data()) }

    public func evaluate(_ activity: ContentActivity, now: Date = Date(), calendar: Calendar = .current) -> ActivityEvaluation {
        let age = max(0, now.timeIntervalSince(activity.lastUsedAt) / 86_400)
        let safeDays = max(1, deprioritizeDays)
        let recency = pow(0.5, age / safeDays)
        let window = max(1, frequencyWindowDays)
        let cutoff = now.addingTimeInterval(-Double(window) * 86_400)
        let recent = activity.samples.filter { $0.at >= cutoff && $0.at <= now }
        let counts = recent.reduce(0.0) { sum, sample in
            let weight: Double
            switch sample.event { case .copy: weight = copyWeight; case .paste: weight = pasteWeight; case .open: weight = openWeight; case .edit: weight = editWeight }
            return sum + max(0, weight)
        }
        // Counts are windowed, capped, and decay too: old lifetime copyCount cannot
        // keep a project active forever. Zero-weight metrics are explicitly disabled.
        let frequency = min(1, log1p(counts) / log(21)) * recency
        let distinctDays = Set(recent.map { calendar.startOfDay(for: $0.at) }).count
        let continuity = min(1, Double(distinctDays) / Double(min(7, window))) * recency
        let denominator = max(0.0001, recencyWeight + frequencyWeight + activeDaysWeight)
        let raw = (recencyWeight * recency + frequencyWeight * frequency + activeDaysWeight * continuity) / denominator
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
