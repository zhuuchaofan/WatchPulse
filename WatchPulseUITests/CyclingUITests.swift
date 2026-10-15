import XCTest

/// 骑行码表的界面流程测试。**演示模式（模拟 GPS 与模拟心率）**，只验证显示规则与交互，
/// 不代表真机 GPS 测速、Apple Watch 心率或震动提醒验收。
final class CyclingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-WatchPulseDemoMode", "YES", "-WatchPulseDemoScenario", "full"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ format: String, _ argument: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "“\(element.label)” 不满足 \(format) \(argument)", file: file, line: line)
    }

    @MainActor
    func testSimulatedCyclingDashboard() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()
        let start = element(app, "demo.start.cycling")
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let liveRow = element(app, "workout.liveRow")
        XCTAssertTrue(liveRow.waitForExistence(timeout: 10))
        liveRow.tap()

        // 模拟 GPS 速度经镜像到达 iPhone，带来源与有效性说明。
        let speed = element(app, "cycling.speed")
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        waitFor(speed, "label MATCHES %@", ".*[0-9]+\\.[0-9].*")
        waitFor(element(app, "cycling.speedStatus"), "label CONTAINS %@", "GPS")
        XCTAssertTrue(element(app, "demoBanner").exists)
        // 演示数据的心率区间（模拟最大心率 190）。
        waitFor(element(app, "cycling.zone"), "label MATCHES %@", "(Z[1-5].*|低于 Z1)")

        // 暂停：速度显示 --，并说明“已暂停”，而不是 0。
        element(app, "live.pause").tap()
        waitFor(element(app, "cycling.speedStatus"), "label CONTAINS %@", "已暂停")
        waitFor(speed, "label CONTAINS %@", "--")
        element(app, "live.resume").tap()
        waitFor(element(app, "cycling.speedStatus"), "label CONTAINS %@", "GPS", timeout: 20)

        // 断线：速度不再显示旧值。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "demo.beginOutage").tap()
        liveRow.tap()
        waitFor(element(app, "cycling.speedStatus"), "label CONTAINS %@", "连接中断")
        waitFor(speed, "label CONTAINS %@", "--")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "demo.endOutage").tap()
        liveRow.tap()
        waitFor(element(app, "cycling.speedStatus"), "label CONTAINS %@", "GPS", timeout: 40)

        // 大字 / 标准视图切换。
        element(app, "cycling.toggleLargeMode").tap()
        XCTAssertTrue(speed.exists)
        element(app, "cycling.toggleLargeMode").tap()

        // 结束：保存结果语义不变。
        element(app, "live.end").tap()
        let confirm = app.buttons["结束并保存"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitFor(element(app, "live.saveStatus"), "label CONTAINS %@", "模拟运动已结束")
        element(app, "live.done").tap()
    }

    @MainActor
    func testCyclingStatisticsInHistory() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()
        let stats = element(app, "workout.cyclingStats")
        for _ in 0..<6 where !stats.exists {
            app.swipeUp()
        }
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        waitFor(stats, "label CONTAINS %@", "次骑行")
    }
}
