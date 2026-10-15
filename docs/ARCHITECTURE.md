# WatchPulse 架构设计

## 1. 范围与阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 1 | HealthKit 可用性检查、按需授权、最新心率（值 / 单位 / 时间 / 来源） | 已实现，云端编译 + 单元测试通过，**真机未验证** |
| 2 | 日常健康监控：心率、HRV、静息心率、步数、睡眠、活动能量；7 / 30 / 90 天趋势 | 已实现，云端验证，**真机未验证** |
| 3 | Apple Watch 实时运动采集、Workout Mirroring、iPhone 实时仪表盘、状态管理、断线恢复 | 已实现，云端验证（含模拟端到端），**真机未验证** |
| 4 | 运动记录保存（Watch → HealthKit）、历史查询、运动详情、心率曲线与区间 | 已实现，云端验证，**真机未验证** |
| 5 | 云端可验证部分：UI 测试（演示模式）、异常处理、模拟 / 压力 / 模糊测试 | 已实现 |

真机待验证事项见 [DEVICE_VALIDATION.md](DEVICE_VALIDATION.md)。

约束：不使用后端、网络服务或第三方 SDK；模拟数据必须与真实 HealthKit 数据明确区分。

## 2. 分层（MVVM + Service）

```
┌──────────────────────────── iOS App (WatchPulse) ────────────────────────────────┐
│ Views: HealthOverviewView · MetricTrendView · WorkoutHomeView                      │
│        LiveWorkoutDashboardView · WorkoutDetailView · DemoModeBanner              │
│ AppEnvironment: 真实 / 演示模式依赖组装；HealthKitMirroringReceiver（镜像接收）      │
└──────────────┬────────────────────────────────────────────────────────────────────┘
               │ 依赖
┌──────────────▼──────────── WatchPulseCore（本地 Swift Package）───────────────────┐
│ ViewModels: HealthOverviewViewModel · MetricTrendViewModel                         │
│             WorkoutHistoryViewModel · WorkoutDetailViewModel · LoadState<T>        │
│ Workout:    WorkoutSessionController（Watch 状态机） · LiveWorkoutMonitor（iPhone）  │
│             SimulatedWorkoutSessionDriver · InMemoryMirroringLink                  │
│             SimulatedMirroredWorkout（演示 / 集成测试）                              │
│ Services:   HealthDataService · WorkoutHistoryService（协议）                        │
│             HealthKit*Service（#if canImport(HealthKit)） · Mock*Service · 模拟数据   │
└──────────────┬────────────────────────────────────────────────────────────────────┘
┌──────────────▼──────────── WatchPulseShared（纯 Foundation）──────────────────────┐
│ 模型：HeartRateSample · HealthMetricKind · MetricSummaryValue · MetricTrend         │
│       SleepSegment / SleepNight / SleepAggregator · WorkoutRecord · HeartRatePoint │
│ 镜像契约：WorkoutMirroringEnvelope / Message / Codec · WorkoutStateSnapshot          │
│          WorkoutSessionDriver · WorkoutMirroringSender（协议）                       │
└────────────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────── watchOS App (WatchPulseWatch) ────────────────────────┐
│ WatchHomeView（开始 / 实时 / 摘要） · WatchAppEnvironment · WatchAppDelegate（恢复）   │
│ HealthKitWorkoutSessionDriver：HKWorkoutSession + HKLiveWorkoutBuilder + 镜像发送     │
└────────────────────────────────────────────────────────────────────────────────────┘
```

设计要点：

- **可测试性优先**：HealthKit 只出现在 `HealthKit*Service`、`HealthKitWorkoutSessionDriver`、`HealthKitMirroringReceiver` 三类“边缘”对象中；所有状态机、聚合、编解码逻辑都在纯 Swift 中，Linux / macOS 均可 `swift test`。
- **数据来源显式**：服务与驱动都有 `dataOrigin`（`.healthKit` / `.simulated`），界面据此显示“演示模式 · 模拟数据”横幅；模拟样本来源名统一为“模拟数据（非真实）”/“模拟运动（非真实）”。
- **状态统一**：`LoadState<T>` = idle / loading / healthDataUnavailable / needsAuthorization / noData / failed / loaded。**无数据 ≠ 拒绝权限**：HealthKit 不披露读取权限，空结果只显示“暂无数据”并提示检查路径。

## 3. 日常健康监控（第二阶段）

| 指标 | HealthKit 类型 | 摘要 | 趋势 |
| --- | --- | --- | --- |
| 心率 | `heartRate` | 最新样本 | `HKStatisticsCollectionQuery` 日均 + 最小 / 最大 |
| 心率变异性 | `heartRateVariabilitySDNN`（毫秒） | 最新样本 | 同上 |
| 静息心率 | `restingHeartRate` | 最新样本 | 同上 |
| 步数 | `stepCount` | 今日 `HKStatisticsQuery` 合计（HealthKit 自动去重） | 每日合计 |
| 活动能量 | `activeEnergyBurned`（千卡） | 今日合计 | 每日合计 |
| 睡眠 | `sleepAnalysis` | 昨晚（按夜聚合） | 每晚时长 |

睡眠聚合 `SleepAggregator`：以 18:00 为界把记录归到“醒来那天”；多来源重叠时按时间轴扫描，每段只计优先级最高的阶段（深睡 > REM > 核心 > 未细分 > 清醒 > 卧床），避免 iPhone + Watch + 第三方 App 重复累计。只有卧床记录时标记为“仅有卧床记录”。

总览页并发读取各指标：单项失败只影响该卡片；全部失败才整体失败（例如锁屏）；全部为空才显示“暂无可读取的健康数据”。

## 4. 实时运动与镜像（第三阶段）

参考 Apple《Building a multidevice workout app》：

```
Apple Watch                                             iPhone
───────────                                             ──────
WorkoutSessionController ──(Data)──► WorkoutMirroringSender ═══► HKWorkoutSession(镜像)
   ▲      │  状态机 / 序号 / 心跳 / 重连                          │ didReceiveDataFromRemote…
   │      ▼                                                      ▼
HealthKitWorkoutSessionDriver                          HealthKitMirroringReceiver
  HKWorkoutSession + HKLiveWorkoutBuilder                       │
  startMirroringToCompanionDevice()                             ▼
  sendToRemoteWorkoutSession(data:)  ◄═══(命令 Data)═══   LiveWorkoutMonitor ──► 仪表盘
```

- **消息协议**：`WorkoutMirroringEnvelope { version, sessionID, sequence, sentAt, message }`，JSON 编码，单条 ≤ 64 KB。
  消息：`stateSync`（完整状态）、`phaseChanged`、`metrics`、`heartbeat`、`commandRejected`（Watch → iPhone）；`command`、`requestStateSync`（iPhone → Watch）。
- **顺序与去重**：接收端按 `sessionID + sequence` 丢弃重复 / 过期消息；`sessionID` 变化表示 Watch 端新会话（新运动或崩溃恢复），若开始时间相同则保留曲线。
- **连接状态**（iPhone）：waiting → connected ↔ stale（12 秒无消息）/ disconnected（系统通知断开或发送失败）；从断开恢复时自动 `requestStateSync`。
- **断线恢复**（Watch）：发送失败或系统通知断开 → 按 2 / 5 / 10 / 20 / 30 秒退避重连（`startMirroringToCompanionDevice`）；一轮失败后提示“暂时无法连接 iPhone”，运动继续本地记录，之后每 60 秒由 `tick()` 再试；重连成功立即发送 `stateSync`。
- **崩溃恢复**（Watch）：`WKApplicationDelegate.handleActiveWorkoutRecovery()` → `recoverActiveWorkoutSession()` → 恢复状态并重新镜像。
- **暂停计时**：恢复运动时把指标快照的时间基准移到恢复时刻，避免暂停期间被计入时长。
- **线程模型**：HealthKit 回调在后台线程，统一经 `DispatchQueue.main.async` + `MainActor.assumeIsolated` 按序交给主线程状态机；回调式 API 在 `nonisolated static` 函数中包装，避免 Swift 6 把回调推断为主线程隔离。

## 5. 运动记录（第四阶段）

- 保存：Watch 端 `HKLiveWorkoutBuilder.endCollection` + `finishWorkout()` 写入 HealthKit（需要写入权限）。
- 查询：`HKSampleQueryDescriptor(.workout())` 按开始时间倒序；`HKWorkout.statistics(for:)` 取能量、距离、心率统计；室内 / 室外取 `HKMetadataKeyIndoorWorkout`。
- 详情：运动区间内的心率样本 → `HeartRateSeries.downsample`（≤ 300 点）+ 最小 / 平均 / 最大 + 心率区间（以本次最高心率为参照，样本间隔 > 60 秒视为缺测）。

## 6. 演示模式与测试（第五阶段）

- 启动参数 `-WatchPulseDemoMode YES`（Xcode scheme：`WatchPulse Demo` / `WatchPulseWatch Demo`）：所有服务换成模拟实现；iPhone 运动页可“开始模拟运动 / 模拟断线 / 恢复连接”，由 `SimulatedMirroredWorkout` 在进程内模拟一只 Apple Watch。
- `-WatchPulseDemoScenario full|empty|failure|needsAuthorization`：UI 测试覆盖各种状态。
- 测试分层：
  - `WatchPulseSharedTests`：格式化、睡眠聚合（含随机不变式）、编解码（含模糊）、心率降采样。
  - `WatchPulseCoreTests`：各 ViewModel 状态流转、Watch 状态机、iPhone 仪表盘、端到端模拟（暂停 / 命令 / 断线 / 重连 / 结束）、稳定性（2 万条乱序重复消息、随机字节、2 小时多次断线、快速切换）。
  - `WatchPulseUITests`：iOS 模拟器上演示模式的界面流程。

## 7. 目录结构

```
WatchPulse/
├── project.yml / WatchPulse.xcodeproj      # XcodeGen 定义与生成的工程
├── Config/Signing.xcconfig                 # Team ID、Bundle ID（Signing.local.xcconfig 覆盖）
├── Packages/WatchPulseKit/
│   ├── Sources/WatchPulseShared/{Models,Workout}
│   ├── Sources/WatchPulseCore/{Services,ViewModels,Workout}
│   └── Tests/{WatchPulseSharedTests,WatchPulseCoreTests}
├── WatchPulse/                             # iOS：App、Features/{HealthOverview,Trends,Workout}、Shared
├── WatchPulseWatch/                        # watchOS：App、Views、Workout
├── WatchPulseUITests/                      # XCUITest（演示模式）
├── docs/{ARCHITECTURE,DEVICE_VALIDATION}.md
└── .github/workflows/ci.yml
```
