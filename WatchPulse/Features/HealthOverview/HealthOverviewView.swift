import SwiftUI
import WatchPulseCore
import WatchPulseShared

struct HealthOverviewView: View {
    let viewModel: HealthOverviewViewModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("健康总览")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await viewModel.load() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 从「设置」或「健康」App 修改权限后返回时重新读取。
            if newPhase == .active, viewModel.state != .idle {
                Task { await viewModel.load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("正在读取健康数据…")

        case .healthDataUnavailable:
            ContentUnavailableView(
                "此设备不支持健康数据",
                systemImage: "heart.slash",
                description: Text("HealthKit 在当前设备上不可用，请在 iPhone 上运行 WatchPulse。")
            )

        case .needsAuthorization:
            ContentUnavailableView {
                Label("需要读取心率数据", systemImage: "heart.text.square")
            } description: {
                Text("WatchPulse 只读取“健康”中的心率记录并在本机显示，不会上传，也不会写入任何数据。")
            } actions: {
                Button("授权读取心率") {
                    Task { await viewModel.requestAuthorizationAndLoad() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .noData:
            ScrollView {
                ContentUnavailableView {
                    Label("暂无可读取的心率记录", systemImage: "waveform.path.ecg")
                } description: {
                    Text(Self.noDataExplanation)
                } actions: {
                    Button("重新读取") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.bordered)
                }
                lastCheckedFooter
            }
            .refreshable { await viewModel.load() }

        case .failed(let error):
            ContentUnavailableView {
                Label("读取失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("重试") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .loaded(let sample):
            ScrollView {
                VStack(spacing: 12) {
                    HeartRateCard(sample: sample)
                    lastCheckedFooter
                }
                .padding()
            }
            .refreshable { await viewModel.load() }
        }
    }

    @ViewBuilder
    private var lastCheckedFooter: some View {
        if let lastCheckedAt = viewModel.lastCheckedAt {
            Text("最近读取：\(lastCheckedAt.formatted(date: .omitted, time: .standard))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// HealthKit 不会告知读取权限是否被拒绝，因此这里只列出可能原因，不下“被拒绝”的结论。
    static let noDataExplanation = """
    “健康”中没有 WatchPulse 可以读取的心率记录。可能的原因：
    • 还没有心率数据（例如尚未佩戴 Apple Watch 测量过）
    • 未允许 WatchPulse 读取心率，可在「设置 › 隐私与安全性 › 健康 › WatchPulse」中检查
    出于隐私保护，HealthKit 不会告诉 App 读取权限是否被关闭。
    """
}

// MARK: - Previews（仅使用 MockHealthDataService，非真实数据）

#Preview("已读取") {
    HealthOverviewView(viewModel: HealthOverviewViewModel(
        service: MockHealthDataService(fetchBehavior: .sample(.previewSample()))
    ))
}

#Preview("加载中") {
    HealthOverviewView(viewModel: HealthOverviewViewModel(
        service: MockHealthDataService(responseDelay: .seconds(3600))
    ))
}

#Preview("需要授权") {
    HealthOverviewView(viewModel: HealthOverviewViewModel(
        service: MockHealthDataService(
            authorizationStatus: .shouldRequest,
            fetchBehavior: .sample(.previewSample())
        )
    ))
}

#Preview("无数据") {
    HealthOverviewView(viewModel: HealthOverviewViewModel(
        service: MockHealthDataService(fetchBehavior: .noData)
    ))
}

#Preview("读取失败") {
    HealthOverviewView(viewModel: HealthOverviewViewModel(
        service: MockHealthDataService(fetchBehavior: .failure(.protectedDataUnavailable))
    ))
}

#Preview("设备不支持") {
    HealthOverviewView(viewModel: HealthOverviewViewModel(
        service: MockHealthDataService(isHealthDataAvailable: false)
    ))
}
