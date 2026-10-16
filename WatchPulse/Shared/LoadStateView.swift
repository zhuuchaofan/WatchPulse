import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 通用的加载状态展示：加载中 / 不支持 / 无数据 / 失败统一处理，成功时交给 `content`。
struct LoadStateView<Value: Hashable & Sendable, Content: View>: View {
    let state: LoadState<Value>
    var noDataTitle = "暂无数据"
    var noDataMessage = "“健康”中没有可读取的记录。若已有数据，请在「设置 › 隐私与安全性 › 健康 › WatchPulse」中检查读取权限。"
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView("正在读取…")
                .frame(maxWidth: .infinity, minHeight: 160)

        case .healthDataUnavailable:
            ContentUnavailableView(
                "此设备不支持健康数据",
                systemImage: "heart.slash",
                description: Text("这台设备无法使用“健康”数据。请在 iPhone 上使用 WatchPulse。")
            )

        case .needsAuthorization:
            ContentUnavailableView(
                "需要健康数据授权",
                systemImage: "heart.text.square",
                description: Text("请先在「健康」页完成授权。")
            )

        case .noData:
            ContentUnavailableView {
                Label(noDataTitle, systemImage: "chart.line.downtrend.xyaxis")
            } description: {
                Text(noDataMessage)
            } actions: {
                Button("重新读取") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }

        case .failed(let error):
            ContentUnavailableView {
                Label("读取失败", systemImage: "exclamationmark.triangle")
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
