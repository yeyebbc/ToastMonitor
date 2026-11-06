import XCTest
@testable import ToastMonitor

final class UsagePeriodTests: XCTestCase {
    func testCalendarWeekRespectsMondayOrSunday() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19 // Wednesday
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!

        let monday = UsagePeriodConfiguration(mode: .calendar, weekStart: .monday)
        let sunday = UsagePeriodConfiguration(mode: .calendar, weekStart: .sunday)
        let mondayRange = monday.range(for: .week, now: date)
        let sundayRange = sunday.range(for: .week, now: date)

        XCTAssertEqual(calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(mondayRange.start))), 2)
        XCTAssertEqual(calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(sundayRange.start))), 1)
    }

    func testRecentPeriodsUseInclusiveLocalDayWindows() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = 12
        let date = Calendar.current.date(from: components)!
        let config = UsagePeriodConfiguration(mode: .recent, weekStart: .monday)
        let todayStart = Calendar.current.startOfDay(for: date)

        XCTAssertEqual(
            config.range(for: .week, now: date).start,
            Int64(Calendar.current.date(byAdding: .day, value: -6, to: todayStart)!.timeIntervalSince1970)
        )
        XCTAssertEqual(
            config.range(for: .month, now: date).start,
            Int64(Calendar.current.date(byAdding: .day, value: -29, to: todayStart)!.timeIntervalSince1970)
        )
    }
    #if os(Windows)
    func testWindowsPeriodsUseLocalMidnightAfterRestoringEnvironment() throws {
        defer {
            NSTimeZone.resetSystemTimeZone()
            XCTAssertNoThrow(try WindowsTimeZone.initialize())
        }
        try WindowsTimeZone.useWindowsTimeZone("China Standard Time")
        let configuration = UsagePeriodConfiguration()
        let beforeMidnight = configuration.range(for: .today, now: Date(timeIntervalSince1970: 1_793_807_999))
        let afterMidnight = configuration.range(for: .today, now: Date(timeIntervalSince1970: 1_793_809_600))
        XCTAssertEqual(beforeMidnight.start, 1_793_721_600)
        XCTAssertEqual(afterMidnight.start, 1_793_808_000)
        XCTAssertEqual(afterMidnight.end, 1_793_809_600)
    }

    func testWindowsPeriodsPreserveSpringAndAutumnDSTRules() throws {
        defer {
            NSTimeZone.resetSystemTimeZone()
            XCTAssertNoThrow(try WindowsTimeZone.initialize())
        }
        try WindowsTimeZone.useWindowsTimeZone("Pacific Standard Time")
        let configuration = UsagePeriodConfiguration()
        // These UTC timestamps enclose a 23-hour spring day and a 25-hour autumn day in Los Angeles.
        let boundaries: [(Int64, Int64, Int64)] = [
            (1_772_956_800, 1_773_039_600, 23 * 3600),
            (1_793_516_400, 1_793_606_400, 25 * 3600),
        ]
        for (start, nextStart, duration) in boundaries {
            let day = configuration.range(for: .today, now: Date(timeIntervalSince1970: TimeInterval(start + 12 * 3600)))
            let next = configuration.range(for: .today, now: Date(timeIntervalSince1970: TimeInterval(nextStart + 12 * 3600)))
            XCTAssertEqual(day.start, start)
            XCTAssertEqual(next.start, nextStart)
            XCTAssertEqual(next.start - day.start, duration)
        }
    }
    #endif
}
