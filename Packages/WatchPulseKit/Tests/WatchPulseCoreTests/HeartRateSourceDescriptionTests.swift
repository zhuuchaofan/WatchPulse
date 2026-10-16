import XCTest
import WatchPulseCore
import WatchPulseShared

final class HeartRateSourceDescriptionTests: XCTestCase {
    /// 真机上实际看到的组合：手表被命名为 “HUAWEI Watch”，设备字段是 “Apple Watch · Watch · Watch6,15”。
    func testRenamedAppleWatchShowsModelNameAndCustomName() {
        let source = HealthSampleSource(
            name: "HUAWEI Watch",
            bundleIdentifier: "com.apple.health.5D2EB7D3-3D9D-4D54-80DC-4E3117ADF752",
            productType: "Watch6,15",
            deviceName: "Apple Watch",
            deviceModel: "Watch"
        )
        let description = HeartRateSourceDescription(source: source)
        XCTAssertEqual(description.deviceModel, "Apple Watch Series 8")
        XCTAssertEqual(description.customName, "HUAWEI Watch")
        XCTAssertEqual(description.recordedBy, "手表自动测量，同步到「健康」App")
    }

    func testDefaultNamedAppleWatchHidesRedundantName() {
        let source = HealthSampleSource(
            name: "Apple Watch", bundleIdentifier: "com.apple.health.X",
            productType: "Watch7,1", deviceName: "Apple Watch", deviceModel: "Watch"
        )
        let description = HeartRateSourceDescription(source: source)
        XCTAssertEqual(description.deviceModel, "Apple Watch Series 9")
        XCTAssertNil(description.customName)
    }

    func testUnknownOrMissingProductTypeFallsBackToAppleWatch() {
        XCTAssertEqual(HeartRateSourceDescription.appleWatchModelName(productType: "Watch9,99"), "Apple Watch")
        XCTAssertEqual(HeartRateSourceDescription.appleWatchModelName(productType: nil), "Apple Watch")
        XCTAssertEqual(HeartRateSourceDescription.appleWatchModelName(productType: "garbage"), "Apple Watch")
        XCTAssertEqual(HeartRateSourceDescription.appleWatchModelName(productType: "Watch6,18"), "Apple Watch Ultra")
    }

    func testThirdPartyAppNamesTheWritingApp() {
        let source = HealthSampleSource(
            name: "Polar Beat", bundleIdentifier: "fi.polar.beat",
            productType: nil, deviceName: "H10", deviceModel: "H10"
        )
        let description = HeartRateSourceDescription(source: source)
        XCTAssertEqual(description.deviceModel, "H10")
        XCTAssertNil(description.customName)
        XCTAssertEqual(description.recordedBy, "由「Polar Beat」写入「健康」App")
    }

    func testSimulatedSampleIsLabelledAsNotReal() {
        let description = HeartRateSourceDescription(source: HeartRateSample.previewSample().source)
        XCTAssertNil(description.deviceModel)
        XCTAssertEqual(description.recordedBy, "示例数据，不是真实测量")
    }
}
