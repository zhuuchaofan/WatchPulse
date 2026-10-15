import SwiftUI
import WatchPulseCore
import WatchPulseShared

struct HealthOverviewView: View {
    let viewModel: HealthOverviewViewModel
    /// 用于创建趋势页的 ViewModel。
    let service: any HealthDataService

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("健康总览")
                .navigationDestination(for: HealthMetricKind.self) { kind in
                    MetricTrendScreen(kind: kind, service: service)
                }
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
                Label("需要读取健康数据", systemImage: "heart.text.square")
            } description: {
                Text("WatchPulse 读取心率、心率变异性、静息心率、步数、睡眠、活动能量与运动记录，仅在本机显示，不会上传。Apple Watch 运动时会把运动记录保存到“健康”。")
            } actions: {
                Button("授权读取健康数据") {
                    Task { await viewModel.requestAuthorizationAndLoad() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("dashboard.authorize")
            }

        case .noData:
            ScrollView {
                if viewModel.dataOrigin.isSimulated {
                    DemoModeBanner().padding(.horizontal)
                }
                ContentUnavailableView {
                    Label("暂无可读取的健康数据", systemImage: "waveform.path.ecg")
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

        case .loaded(let snapshot):
            ScrollView {
                VStack(spacing: 12) {
                    if viewModel.dataOrigin.isSimulated {
                        DemoModeBanner()
                    }
                    heartRateSection(snapshot)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(snapshot.cards) { card in
                            NavigationLink(value: card.kind) {
                                MetricSummaryCard(card: card)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("metricCard.\(card.kind.rawValue)")
                        }
                    }
                    lastCheckedFooter
                }
                .padding()
            }
            .refreshable { await viewModel.load() }
        }
    }

    @ViewBuilder
    private func heartRateSection(_ snapshot: HealthDashboardSnapshot) -> some View {
        if let sample = snapshot.latestHeartRate {
            // 卡片内有可展开的“数据详情”，因此不整体作为链接；趋势入口在卡片底部。
            HeartRateCard(sample: sample)
                .accessibilityIdentifier("dashboard.heartRateCard")
        } else {
            NavigationLink(value: HealthMetricKind.heartRate) {
                MetricSummaryCard(card: MetricCardModel(
                    kind: .heartRate,
                    status: snapshot.heartRateError.map(MetricCardStatus.failed) ?? .noData
                ))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dashboard.heartRateCard")
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
    “健康”中没有 WatchPulse 可以读取的记录。可能的原因：
    • 还没有相关数据（例如尚未佩戴 Apple Watch）
    • 未允许 WatchPulse 读取，可在「设置 › 隐私与安全性 › 健康 › WatchPulse」中检查
    出于隐私保护，HealthKit 不会告诉 App 读取权限是否被关闭。
    """
}

/// 持有趋势页 ViewModel 的容器，避免视图重建时重复创建 ViewModel。
struct MetricTrendScreen: View {
    @State private var viewModel: MetricTrendViewModel

    init(kind: HealthMetricKind, service: any HealthDataService) {
        _viewModel = State(initialValue: MetricTrendViewModel(kind: kind, service: service))
    }

    var body: some View {
        MetricTrendView(viewModel: viewModel)
    }
}

// MARK: - Previews（仅使用 MockHealthDataService，非真实数据）

#Preview("演示数据") {
    let service = MockHealthDataService.demo()
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("加载中") {
    let service = MockHealthDataService(responseDelay: .seconds(3600))
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("需要授权") {
    let service = MockHealthDataService(authorizationStatus: .shouldRequest)
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("无数据") {
    let service = MockHealthDataService(fetchBehavior: .noData)
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("部分失败") {
    let service = MockHealthDataService(
        fetchBehavior: .sample(.previewSample()),
        summaries: [.sleep: .failure(.protectedDataUnavailable), .stepCount: .value(MetricSummaryValue(kind: .stepCount, value: 4_321, date: .now))]
    )
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("设备不支持") {
    let service = MockHealthDataService(isHealthDataAvailable: false)
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}
