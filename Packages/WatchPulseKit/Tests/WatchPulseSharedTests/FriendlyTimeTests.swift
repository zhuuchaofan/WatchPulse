import Foundation
import XCTest
import WatchPulseShared

final class FriendlyTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testFriendlyDateTime() {
        let now = date(2026, 10, 15, 21, 30)
        XCTAssertEqual(MetricFormatting.friendlyDateTime(date(2026, 10, 15, 21, 19), now: now, calendar: calendar), "今天 21:19")
        XCTAssertEqual(MetricFormatting.friendlyDateTime(date(2026, 10, 14, 8, 5), now: now, calendar: calendar), "昨天 08:05")
        XCTAssertEqual(MetricFormatting.friendlyDateTime(date(2026, 10, 13, 7, 40), now: now, calendar: calendar), "10月13日 07:40")
        XCTAssertEqual(MetricFormatting.friendlyDateTime(date(2025, 12, 31, 23, 59), now: now, calendar: calendar), "2025年12月31日 23:59")
    }

    func testAgo() {
        let now = date(2026, 10, 15, 21, 30)
        XCTAssertEqual(MetricFormatting.ago(now.addingTimeInterval(-20), now: now), "刚刚")
        XCTAssertEqual(MetricFormatting.ago(now.addingTimeInterval(-600), now: now), "10 分钟前")
        XCTAssertEqual(MetricFormatting.ago(now.addingTimeInterval(-3 * 3_600 - 100), now: now), "3 小时前")
        XCTAssertEqual(MetricFormatting.ago(now.addingTimeInterval(-2 * 86_400), now: now), "2 天前")
        XCTAssertEqual(MetricFormatting.ago(now.addingTimeInterval(60), now: now), "刚刚")
    }
}
