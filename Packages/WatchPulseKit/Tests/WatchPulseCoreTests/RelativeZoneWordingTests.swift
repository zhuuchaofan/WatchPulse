import XCTest
@testable import WatchPulseCore

/// 运动详情的“本次相对区间”以本次最高心率为 100%，不能用“燃脂 / 无氧 / 极限”等训练效果用语。
final class RelativeZoneWordingTests: XCTestCase {
    func testRelativeZonesOnlyDescribeIntensity() {
        for zone in HeartRateZone.allCases {
            for word in ["燃脂", "有氧", "无氧", "极限", "热身"] {
                XCTAssertFalse(zone.title.contains(word), "\(zone) → \(zone.title)")
            }
            XCTAssertFalse(zone.rangeDescription.isEmpty)
        }
        XCTAssertEqual(HeartRateZone.allCases.map(\.title), ["很低", "较低", "中等", "较高", "很高"])
    }

    func testRangeDescriptionsMatchTheBoundaries() {
        XCTAssertEqual(HeartRateZone.warmUp.rangeDescription, "低于 60%")
        XCTAssertEqual(HeartRateZone.maximum.rangeDescription, "90% 及以上")
    }
}
