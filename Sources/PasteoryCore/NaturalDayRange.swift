import Foundation

public struct NaturalDayRange: Equatable, Sendable {
    public let todayStart: Date
    public let sevenDayStart: Date

    public init(containing date: Date, calendar: Calendar = .autoupdatingCurrent) {
        todayStart = calendar.startOfDay(for: date)
        sevenDayStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
    }
}
