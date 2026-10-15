import XCTest

/// iOS 模拟器上的界面流程测试。**全部在演示模式（模拟数据）下运行**，只验证界面状态与交互流程，
/// 不代表真机 HealthKit / Apple Watch 功能验收。
final class WatchPulseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(scenario: String = "full") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-WatchPulseDemoMode", "YES", "-WatchPulseDemoScenario", scenario]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "“\(element.label)” 不包含 “\(text)”", file: file, line: line)
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, matches format: String, _ argument: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "“\(element.label)” 不满足 \(format) \(argument)", file: file, line: line)
    }

    /// 在懒加载列表中向上滑动直到元素出现。
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) {
        for _ in 0..<attempts where !element.exists {
            app.swipeUp()
        }
    }

    // MARK: - 健康总览

    @MainActor
    func testDashboardShowsSimulatedDataBannerAndMetrics() {
        let app = launch()
        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 15), "模拟数据必须有明确标注")
        XCTAssertTrue(element(app, "dashboard.heartRateCard").exists)
        // 演示心率并非来自 Apple Watch，卡片会显示来源提示。
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "非 Apple Watch")).firstMatch.exists)
        // 卡片在懒加载网格中，可能需要滚动才会创建。
        for identifier in ["metricCard.restingHeartRate", "metricCard.stepCount"] {
            let card = element(app, identifier)
            scrollTo(card, in: app)
            XCTAssertTrue(card.exists, identifier)
        }
        let simulatedSource = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "模拟数据（非真实）"))
            .firstMatch
        XCTAssertTrue(simulatedSource.exists, "示例心率的来源必须标注为非真实")
    }

    @MainActor
    func testHeartRateDetailsCollapsedByDefault() {
        let app = launch()
        XCTAssertTrue(element(app, "dashboard.heartRateCard").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "heartRate.ago").exists)
        // 技术细节默认收起，点开“数据详情”才显示。
        XCTAssertFalse(app.staticTexts["来源标识"].exists)
        app.buttons["数据详情"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["来源标识"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTrendScreenSwitchesPeriods() {
        let app = launch()
        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 15))
        let steps = element(app, "metricCard.stepCount")
        scrollTo(steps, in: app)
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        steps.tap()

        XCTAssertTrue(element(app, "trend.chart").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "demoBanner").exists)
        app.buttons["30 天"].tap()
        XCTAssertTrue(element(app, "trend.chart").waitForExistence(timeout: 10))
        app.buttons["90 天"].tap()
        XCTAssertTrue(element(app, "trend.chart").waitForExistence(timeout: 10))
    }

    @MainActor
    func testNeedsAuthorizationThenLoads() {
        let app = launch(scenario: "needsAuthorization")
        let authorize = element(app, "dashboard.authorize")
        XCTAssertTrue(authorize.waitForExistence(timeout: 15))
        authorize.tap()
        XCTAssertTrue(element(app, "dashboard.heartRateCard").waitForExistence(timeout: 10))
    }

    @MainActor
    func testEmptyScenarioShowsNoDataWithoutClaimingDenial() {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.staticTexts["暂无可读取的健康数据"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "拒绝")).firstMatch.exists)
    }

    @MainActor
    func testFailureScenarioShowsErrorAndRetry() {
        let app = launch(scenario: "failure")
        XCTAssertTrue(app.staticTexts["读取失败"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["重试"].exists)
        app.buttons["重试"].tap()
        XCTAssertTrue(app.staticTexts["读取失败"].waitForExistence(timeout: 10))
    }

    // MARK: - 运动记录

    @MainActor
    func testWorkoutHistoryDetailShowsHeartRateCurve() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()

        let row = element(app, "workout.history.row")
        for _ in 0..<5 where !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 10))
        let chart = element(app, "workoutDetail.heartRateChart")
        scrollTo(chart, in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
    }

    @MainActor
    func testWorkoutHistoryFailureScenario() {
        let app = launch(scenario: "failure")
        app.tabBars.buttons["运动"].tap()
        XCTAssertTrue(element(app, "loadState.failed").waitForExistence(timeout: 10))
    }

    // MARK: - 实时运动（模拟 Apple Watch）

    @MainActor
    func testSimulatedLiveWorkoutControlOutageRecoveryAndEnd() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()
        XCTAssertTrue(element(app, "workout.waiting").waitForExistence(timeout: 10))

        element(app, "demo.start.running").tap()
        let liveRow = element(app, "workout.liveRow")
        XCTAssertTrue(liveRow.waitForExistence(timeout: 10))
        liveRow.tap()

        let phase = element(app, "live.phase")
        XCTAssertTrue(phase.waitForExistence(timeout: 10))
        waitForLabel(phase, contains: "进行中")
        XCTAssertTrue(element(app, "demoBanner").exists)
        // 心率数值出现（不再是占位符“--”），说明模拟指标经镜像链路到达仪表盘。
        waitForLabel(element(app, "live.heartRate"), matches: "label MATCHES %@", ".*[0-9]+.*次/分.*", timeout: 15)

        // iPhone → Watch：暂停 / 继续。
        element(app, "live.pause").tap()
        waitForLabel(phase, contains: "已暂停")
        element(app, "live.resume").tap()
        waitForLabel(phase, contains: "进行中")

        // 模拟断线：仪表盘显示断开，命令被拒绝。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "demo.beginOutage").tap()
        liveRow.tap()
        waitForLabel(element(app, "live.connection"), contains: "断开")
        element(app, "live.pause").tap()
        waitForLabel(element(app, "live.commandError"), contains: "未连接")

        // 恢复：Watch 端自动重连，仪表盘回到已连接。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "demo.endOutage").tap()
        liveRow.tap()
        waitForLabel(element(app, "live.connection"), contains: "已连接", timeout: 40)

        // 结束运动。
        element(app, "live.end").tap()
        let confirm = app.buttons["结束并保存"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitForLabel(phase, contains: "已结束")
        // 只有收到 Watch 的保存结果才显示结束文案；演示模式明确说明未写入“健康”。
        waitForLabel(element(app, "live.saveStatus"), contains: "模拟运动已结束")
        element(app, "live.done").tap()

        // 模拟运动加入了运动记录。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "workout.waiting").waitForExistence(timeout: 10))
    }
}
