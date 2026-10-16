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

    // MARK: - 今日

    /// 进入二级页「全部指标」（最新心率与全部指标卡片都在这里）。
    @MainActor
    private func openAllMetrics(_ app: XCUIApplication) {
        let link = element(app, "today.allMetrics")
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        scrollTo(link, in: app)
        link.tap()
    }

    @MainActor
    func testTodayShowsConclusionReasonAndAction() {
        let app = launch()
        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 15), "模拟数据必须有明确标注")
        XCTAssertFalse(element(app, "demoBanner").label.contains("HealthKit"), "不向普通用户展示框架名")
        // 顶部状态卡：结论 + 原因 + 下一步。
        XCTAssertTrue(element(app, "today.hero").exists)
        XCTAssertFalse(element(app, "today.headline").label.isEmpty)
        XCTAssertFalse(element(app, "today.reason").label.isEmpty)
        XCTAssertTrue(element(app, "today.action").exists)
        // 不用医学化用语。
        for word in ["异常", "疾病", "诊断"] {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", word)).firstMatch.exists, word)
        }
        // 三张次级卡片。
        for identifier in ["today.sleep", "today.body", "today.activity"] {
            let card = element(app, identifier)
            scrollTo(card, in: app)
            XCTAssertTrue(card.exists, identifier)
        }
    }

    @MainActor
    func testTodayActionOpensTrainingCenter() {
        let app = launch(scenario: "insufficient")
        // 平时水平还在积累时，下一步是去看本周训练。
        let headline = element(app, "today.headline")
        XCTAssertTrue(headline.waitForExistence(timeout: 15))
        waitForLabel(headline, contains: "正在了解你的平时水平")
        element(app, "today.action").tap()
        XCTAssertTrue(element(app, "workout.goalEmpty").waitForExistence(timeout: 10), "切换到了运动页（训练中心）")
    }

    @MainActor
    func testAllMetricsShowsHeartRateAndMetricCards() {
        let app = launch()
        XCTAssertTrue(element(app, "today.hero").waitForExistence(timeout: 15))
        openAllMetrics(app)
        XCTAssertTrue(element(app, "dashboard.heartRateCard").waitForExistence(timeout: 10))
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
        XCTAssertTrue(element(app, "today.hero").waitForExistence(timeout: 15))
        openAllMetrics(app)
        XCTAssertTrue(element(app, "dashboard.heartRateCard").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "heartRate.ago").exists)
        // 技术细节默认收起，点开“数据详情”才显示。
        XCTAssertFalse(app.staticTexts["记录方式"].exists)
        app.buttons["数据详情"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["记录方式"].waitForExistence(timeout: 5))
        // 演示数据明确标注为示例；不再展示 Bundle ID 等技术字段。
        // LabeledContent 可能把值合并进“记录方式”元素的 value，也可能单独成一个文本，两种都接受。
        let recordedByValue = app.staticTexts["记录方式"].value as? String ?? ""
        let separateValueText = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "示例数据，不是真实测量"))
            .firstMatch
        XCTAssertTrue(recordedByValue.contains("示例数据，不是真实测量") || separateValueText.exists)
        XCTAssertFalse(app.staticTexts["来源标识"].exists)
    }

    @MainActor
    func testTrendScreenSwitchesPeriods() {
        let app = launch()
        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 15))
        // 今日页的“今天的活动”卡片进入步数趋势。
        let steps = element(app, "today.activity")
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
        XCTAssertTrue(element(app, "today.hero").waitForExistence(timeout: 10))
    }

    @MainActor
    func testEmptyScenarioShowsNoDataWithoutClaimingDenial() {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.staticTexts["暂无可读取的健康数据"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "拒绝")).firstMatch.exists)
        // 没数据时给出“检查读取权限”入口，而不是只说无数据。
        XCTAssertTrue(app.buttons["检查读取权限"].exists)
    }

    @MainActor
    func testFailureScenarioShowsErrorAndRetry() {
        let app = launch(scenario: "failure")
        XCTAssertTrue(app.staticTexts["暂时读不到数据"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["重试"].exists)
        app.buttons["重试"].tap()
        XCTAssertTrue(app.staticTexts["暂时读不到数据"].waitForExistence(timeout: 10))
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
    func testWorkoutDetailShowsDataCredibilitySection() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()

        let row = element(app, "workout.history.row")
        for _ in 0..<5 where !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 10), "演示模式必须显示模拟数据标识")
        // 运动后反馈位于其上方，需要向下滚动。
        let header = app.staticTexts["数据可信度"]
        scrollTo(header, in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 10))

        // 默认只显示通俗结论；覆盖率、来源等判断依据收起，点开才显示。
        let summary = element(app, "workoutDetail.credibilitySummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertFalse(summary.label.contains("可展示"))
        let technical = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "来源：")).firstMatch
        XCTAssertFalse(technical.exists, "技术依据默认收起")
        let disclosure = app.buttons["查看判断依据"].firstMatch
        scrollTo(disclosure, in: app)
        disclosure.tap()
        XCTAssertTrue(technical.waitForExistence(timeout: 5))
    }

    @MainActor
    func testWorkoutDetailRelativeZonesAvoidTrainingEffectClaims() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()

        let row = element(app, "workout.history.row")
        for _ in 0..<5 where !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let explanation = element(app, "workoutDetail.zoneExplanation")
        scrollTo(explanation, in: app, attempts: 10)
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        waitForLabel(explanation, contains: "不能和其他运动比较")
        // 以本次最高心率为 100% 的区间不能叫“无氧 / 极限”。
        for word in ["无氧", "极限"] {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", word)).firstMatch.exists, word)
        }
        XCTAssertTrue(app.staticTexts["很高"].exists)
    }

    @MainActor
    func testGoalsWithoutAnyWorkoutRecordsExplainTheZero() {
        let app = launch(scenario: "empty")
        app.tabBars.buttons["目标"].tap()
        XCTAssertTrue(element(app, "goals.empty").waitForExistence(timeout: 10))

        element(app, "goals.add").tap()
        let target = element(app, "goalEditor.target")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.tap()
        target.typeText("3")
        app.buttons["goalEditor.save"].tap()

        // 没有读到运动时，0 次可能是未授权，不能当作正常进度静默显示。
        let hint = element(app, "goals.recordsEmpty")
        XCTAssertTrue(hint.waitForExistence(timeout: 10))
        waitForLabel(hint, contains: "检查")
    }

    @MainActor
    func testWorkoutDetailShowsPostWorkoutFeedback() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()

        let row = element(app, "workout.history.row")
        for _ in 0..<5 where !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let headline = element(app, "workoutDetail.feedback.headline")
        scrollTo(headline, in: app)
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        // 无论样本是否足够，都要说明对比对象的范围（时间窗与同类运动）。
        waitForLabel(headline, contains: "天内可比的")
        // iPhone 上没有个人心率区间时，区间比较这一项整体隐藏，不显示无法补救的提示。
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "暂不比较区间分布")).firstMatch.exists)
    }

    @MainActor
    func testCreateEditPauseAndDeleteWeeklyGoal() {
        let app = launch()
        app.tabBars.buttons["目标"].tap()

        XCTAssertTrue(element(app, "demoBanner").waitForExistence(timeout: 10), "演示模式必须显示模拟数据标识")
        XCTAssertTrue(element(app, "goals.empty").waitForExistence(timeout: 10), "初始没有任何预设目标")

        element(app, "goals.add").tap()
        let target = element(app, "goalEditor.target")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        // 工具栏按钮要按 Button 查找：按标识匹配到的第一个元素可能是其外层容器，`isEnabled` 恒为 true。
        let save = app.buttons["goalEditor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled, "未输入数值时不能保存")
        target.tap()
        target.typeText("3")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["每周运动 3 次"].waitForExistence(timeout: 10))
        let progress = element(app, "goals.progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        waitForLabel(progress, contains: "本周")

        // 编辑 → 暂停 → 恢复 → 删除。
        element(app, "goals.row").tap()
        element(app, "goalEditor.togglePause").tap()
        XCTAssertTrue(app.staticTexts["已暂停，不计算进度"].waitForExistence(timeout: 10))
        element(app, "goals.row").tap()
        element(app, "goalEditor.togglePause").tap()
        XCTAssertTrue(element(app, "goals.progress").waitForExistence(timeout: 10))
        element(app, "goals.row").tap()
        element(app, "goalEditor.delete").tap()
        XCTAssertTrue(element(app, "goals.empty").waitForExistence(timeout: 10))
    }

    // MARK: - 训练中心

    @MainActor
    func testTrainingCenterShowsGoalStartLatestFeedbackAndRecent() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()
        // 本周目标 → 开始运动 → 最近一次运动 → 最近记录。
        XCTAssertTrue(element(app, "workout.goalEmpty").waitForExistence(timeout: 10), "初始没有任何预设目标")
        XCTAssertTrue(element(app, "workout.waiting").exists)
        let latest = element(app, "workout.latest")
        scrollTo(latest, in: app)
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        let feedback = element(app, "workout.latest.feedback")
        scrollTo(feedback, in: app)
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        let row = element(app, "workout.history.row")
        scrollTo(row, in: app)
        XCTAssertTrue(row.exists)
    }

    @MainActor
    func testTrainingCenterGoalCardLinksToGoalsAndShowsProgress() {
        let app = launch()
        app.tabBars.buttons["运动"].tap()
        let setGoal = app.buttons["设定目标"].firstMatch
        XCTAssertTrue(setGoal.waitForExistence(timeout: 10))
        setGoal.tap()
        // 切换到了目标页。
        XCTAssertTrue(element(app, "goals.empty").waitForExistence(timeout: 10))
        element(app, "goals.add").tap()
        let target = element(app, "goalEditor.target")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.tap()
        target.typeText("3")
        app.buttons["goalEditor.save"].tap()

        // 回到运动页：本周目标卡显示进度与还差多少。
        app.tabBars.buttons["运动"].tap()
        let progress = element(app, "workout.goalProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        waitForLabel(progress, contains: "/")
    }

    @MainActor
    func testTrainingCenterEmptyHistoryExplainsNextStep() {
        let app = launch(scenario: "empty")
        app.tabBars.buttons["运动"].tap()
        // 「最近记录」在本周目标、开始运动和演示控制之后，懒加载列表中需要先滚动到它。
        XCTAssertTrue(element(app, "workout.waiting").waitForExistence(timeout: 10))
        let empty = app.staticTexts["还没有运动记录"]
        scrollTo(empty, in: app)
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "拒绝")).firstMatch.exists)
    }

    @MainActor
    func testWorkoutHistoryFailureScenario() {
        let app = launch(scenario: "failure")
        app.tabBars.buttons["运动"].tap()
        XCTAssertTrue(element(app, "workout.waiting").waitForExistence(timeout: 10))
        let failed = element(app, "loadState.failed")
        scrollTo(failed, in: app)
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
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
