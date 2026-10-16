import XCTest

/// 分析页的界面流程测试。**演示模式（模拟数据）**，只验证状态与文案规则，
/// 不代表真机 HealthKit 数据的基线 / 睡眠分析验收。
final class InsightsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-WatchPulseDemoMode", "YES", "-WatchPulseDemoScenario", scenario]
        app.launch()
        app.tabBars.buttons["分析"].tap()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "“\(element.label)” 不包含 “\(text)”", file: file, line: line)
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    @MainActor
    func testFullDataShowsBaselinesSleepAndDisclaimer() {
        let app = launch(scenario: "full")
        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 10))
        let resting = element(app, "insights.restingHeartRate")
        XCTAssertTrue(resting.waitForExistence(timeout: 10))
        waitFor(resting, contains: "基线")
        waitFor(element(app, "insights.hrv"), contains: "近 7 天")
        let sleep = element(app, "insights.sleep")
        scrollTo(sleep, in: app)
        waitFor(sleep, contains: "深睡")
        let range = element(app, "insights.trendRange")
        scrollTo(range, in: app)
        range.buttons["28 天"].tap()
        let disclaimer = element(app, "insights.disclaimer")
        scrollTo(disclaimer, in: app)
        waitFor(disclaimer, contains: "不代表医疗诊断")
    }

    @MainActor
    func testInsufficientDataShowsAccumulating() {
        let app = launch(scenario: "insufficient")
        let resting = element(app, "insights.restingHeartRate")
        XCTAssertTrue(resting.waitForExistence(timeout: 10))
        waitFor(resting, contains: "积累中")
        // 数据不足不能说成与平时一样，并给出下一步。
        waitFor(resting, contains: "继续日常佩戴")
        let sleep = element(app, "insights.sleep")
        scrollTo(sleep, in: app)
        waitFor(sleep, contains: "至少 4 晚")
    }

    @MainActor
    func testConceptsAreExplainedWithoutStatisticalJargon() {
        let app = launch(scenario: "full")
        let explanation = element(app, "insights.baselineExplanation")
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        waitFor(explanation, contains: "平时水平")
        let hrv = element(app, "insights.hrv")
        XCTAssertTrue(hrv.waitForExistence(timeout: 10))
        waitFor(hrv, contains: "HRV")
        XCTAssertFalse(hrv.label.contains("中位数"), "统计口径收进“数据依据与来源”")
    }

    @MainActor
    func testEmptyShowsNoDataNotDenied() {
        let app = launch(scenario: "empty")
        let title = app.staticTexts["暂无可分析的数据"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "拒绝")).firstMatch.exists)
    }

    @MainActor
    func testNeedsAuthorization() {
        let app = launch(scenario: "needsAuthorization")
        let button = element(app, "insights.authorize")
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(element(app, "insights.restingHeartRate").waitForExistence(timeout: 10))
    }

    @MainActor
    func testFailureShowsRetry() {
        let app = launch(scenario: "failure")
        XCTAssertTrue(element(app, "loadState.failed").waitForExistence(timeout: 10))
    }

    @MainActor
    func testHealthTabShowsBaselineOnCards() {
        let app = XCUIApplication()
        app.launchArguments += ["-WatchPulseDemoMode", "YES", "-WatchPulseDemoScenario", "full"]
        app.launch()
        // 卡片内容合并为一个无障碍元素，基线文字是卡片标签的一部分。
        let card = element(app, "metricCard.restingHeartRate")
        for _ in 0..<6 where !card.exists {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        waitFor(card, contains: "基线")
    }
}
