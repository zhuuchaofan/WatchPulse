import SwiftUI
import UIKit
import WatchPulseCore
import WatchPulseShared

/// 通用的加载状态展示：加载中 / 不支持 / 未授权 / 无数据 / 失败统一处理，成功时交给 `content`。
struct LoadStateView<Value: Hashable & Sendable, Content: View>: View {
    let state: LoadState<Value>
    var noDataTitle = "暂无数据"
    var noDataMessage = "“健康”中没有可读取的记录。若已有数据，请检查 WatchPulse 的读取权限。"
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView("正在读取…")
                .frame(maxWidth: .infinity, minHeight: 160)

        case .healthDataUnavailable:
            ContentUnavailableView(
                "这台设备用不了“健康”",
                systemImage: "heart.slash",
                description: Text("请在 iPhone 上使用 WatchPulse。")
            )

        case .needsAuthorization:
            ContentUnavailableView(
                "需要先允许读取健康数据",
                systemImage: "heart.text.square",
                description: Text("请先在「今日」页完成授权。")
            )

        case .noData:
            ContentUnavailableView {
                Label(noDataTitle, systemImage: "chart.line.downtrend.xyaxis")
            } description: {
                Text(noDataMessage)
            } actions: {
                Button("重新读取") { Task { await retry() } }
                    .buttonStyle(.borderedProminent)
                OpenSettingsButton()
            }

        case .failed(let error):
            ContentUnavailableView {
                Label("暂时读不到数据", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("重试") { Task { await retry() } }
                    .buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("loadState.failed")

        case .loaded(let value):
            content(value)
        }
    }
}

/// 跳到系统「设置」中 WatchPulse 的页面，让用户检查“健康”读取权限。
/// iPhone 不会告诉 App 读取权限是否被关闭，所以这里只提供入口，不下“被拒绝”的结论。
struct OpenSettingsButton: View {
    var title = "检查读取权限"

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(title) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
        .buttonStyle(.themeSecondary)
        .accessibilityIdentifier("openSettings")
    }
}

#Preview("无数据") {
    LoadStateView(state: LoadState<Int>.noData, noDataTitle: "暂无运动记录", noDataMessage: "完成一次运动后会出现在这里。", retry: {}) { _ in EmptyView() }
}

#Preview("读取失败") {
    LoadStateView(state: LoadState<Int>.failed(.protectedDataUnavailable), retry: {}) { _ in EmptyView() }
}
