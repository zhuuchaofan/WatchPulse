import XCTest

/// 四个页面与各类状态的同场景截图，用于改版前后对照。**演示模式（模拟数据）**，不做断言之外的验收。
///
/// 只在 CI 的截图步骤中单独运行（主测试步骤跳过本类）。设置环境变量 `WATCHPULSE_SCREENSHOT_DIR`
/// （xcodebuild 以 `TEST_RUNNER_WATCHPULSE_SCREENSHOT_DIR` 传入）时把 PNG 写到该目录；同时作为测试附件保留。
/// 文件名：`<外观>-<场景>-<页面>-<序号>.png`，序号是同一页面向下滚动的第几屏。
final class ScreenshotTests: XCTestCase {
    private enum Variant: String, CaseIterable {
        case light
        case dark
        /// 浅色 + 辅助功能大字号（AccessibilityL）。
        case large

        var launchArguments: [String] {
            switch self {
            case .light: return ["-WatchPulseAppearance", "light"]
            case .dark: return ["-WatchPulseAppearance", "dark"]
            case .large: return ["-WatchPulseAppearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
            }
        }
    }

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func launch(scenario: String, variant: Variant) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-WatchPulseDemoMode", "YES", "-WatchPulseDemoScenario", scenario] + variant.launchArguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func settle(_ seconds: TimeInterval = 1.5) {
        // 等待异步加载与动画结束；截图只求画面稳定，不作为时序断言。
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func save(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["WATCHPULSE_SCREENSHOT_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("写入截图失败：\(url.path) \(error)")
        }
    }

    /// 截当前屏，再向上滑动逐屏截取，画面不再变化（已到底）时停止。
    @MainActor
    private func capturePage(_ app: XCUIApplication, name: String, maxScreens: Int = 4) {
        settle()
        var previous = app.screenshot()
        save(previous, name: "\(name)-1")
        guard maxScreens > 1 else { return }
        for index in 2...maxScreens {
            app.swipeUp()
            settle(1)
            let current = app.screenshot()
            if current.pngRepresentation == previous.pngRepresentation { return }
            save(current, name: "\(name)-\(index)")
            previous = current
        }
    }

    @MainActor
    private func open(_ tab: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
    }

    @MainActor
    private func addWeeklyGoal(_ app: XCUIApplication) {
        let add = element(app, "goals.add")
        guard add.waitForExistence(timeout: 10) else { return XCTFail("没有找到新增目标按钮") }
        add.tap()
        let target = element(app, "goalEditor.target")
        guard target.waitForExistence(timeout: 10) else { return XCTFail("没有打开目标编辑") }
        target.tap()
        target.typeText("3")
        app.buttons["goalEditor.save"].tap()
        _ = element(app, "goals.progress").waitForExistence(timeout: 10)
    }

    // MARK: - 四个页面（完整数据）× 浅色 / 深色 / 大字号

    @MainActor
    func testFourPagesInEveryAppearance() {
        for variant in Variant.allCases {
            let app = launch(scenario: "full", variant: variant)
            let prefix = "\(variant.rawValue)-full"
            _ = element(app, "demoBanner").waitForExistence(timeout: 15)
            capturePage(app, name: "\(prefix)-today")

            open("目标", in: app)
            capturePage(app, name: "\(prefix)-goals-empty", maxScreens: 1)
            addWeeklyGoal(app)
            capturePage(app, name: "\(prefix)-goals")

            open("运动", in: app)
            _ = element(app, "workout.waiting").waitForExistence(timeout: 10)
            capturePage(app, name: "\(prefix)-workout")

            open("进步", in: app)
            capturePage(app, name: "\(prefix)-progress", maxScreens: 6)
            app.terminate()
        }
    }

    // MARK: - 运动中

    @MainActor
    func testLiveWorkoutInEveryAppearance() {
        for variant in Variant.allCases {
            let app = launch(scenario: "full", variant: variant)
            open("运动", in: app)
            let start = element(app, "demo.start.running")
            guard start.waitForExistence(timeout: 10) else { XCTFail("没有找到模拟开始按钮"); continue }
            start.tap()
            let liveRow = element(app, "workout.liveRow")
            guard liveRow.waitForExistence(timeout: 10) else { XCTFail("没有出现运动中入口"); continue }
            liveRow.tap()
            _ = element(app, "live.phase").waitForExistence(timeout: 10)
            settle(4)
            capturePage(app, name: "\(variant.rawValue)-full-live", maxScreens: 3)
            app.terminate()
        }
    }

    // MARK: - 空数据 / 权限 / 失败 / 数据不足（浅色、深色）

    @MainActor
    func testStatesInLightAndDark() {
        let scenarios = ["empty", "needsAuthorization", "failure", "insufficient"]
        for variant in [Variant.light, .dark] {
            for scenario in scenarios {
                let app = launch(scenario: scenario, variant: variant)
                let prefix = "\(variant.rawValue)-\(scenario)"
                _ = element(app, "demoBanner").waitForExistence(timeout: 15)
                capturePage(app, name: "\(prefix)-today", maxScreens: 2)
                open("运动", in: app)
                capturePage(app, name: "\(prefix)-workout", maxScreens: 2)
                open("进步", in: app)
                capturePage(app, name: "\(prefix)-progress", maxScreens: 3)
                app.terminate()
            }
        }
    }
}
