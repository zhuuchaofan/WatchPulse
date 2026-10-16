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

## 8. v0.2：骑行增强 + 健康分析

需求基准见 [ROADMAP_V02_V10.md](ROADMAP_V02_V10.md)。不改动现有分层与状态机，只通过以下扩展点接入：

**共享契约（C0）**
- `WorkoutMetricsSnapshot.speed: WorkoutSpeedSample?`（来源 GPS / 传感器 / 不可用，质量 good / lowAccuracy / stale / unavailable / notAuthorized / paused；不可展示的质量不带数值）。字段可选、解码宽松，镜像协议版本号不变：v0.1 的一端会忽略新字段，未知取值降级为 `unavailable`。
- `WorkoutStateSnapshot.heartRateZones / targetZone`（可选），iPhone 用 Watch 上的区间设置显示当前区间。
- `WorkoutLiveObserver`：挂在 `WorkoutSessionController` 上，只能在指标发布前补充字段、在开始 / 阶段变化 / 结束时得到通知；不能改变计时，也不能改变开始 / 暂停 / 结束 / 保存流程。`refreshMetrics()` 让观察者在有新速度时重发指标（时间戳不变）。
- `HealthDataService.fetchSleepNights(in:)`：按夜返回带分期与来源的睡眠详情。

**Cycling Track**

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| `GPSSpeedCalculator` | Core | 纯逻辑：有效性 / 精度 / 时间序 / 跳点过滤，5 秒平滑，过期与暂停不带数值；阈值集中在 `Configuration`，需真机校准 |
| `CyclingSpeedTracker` | Core | 观察者：仅室外骑行启动定位，暂停 / 结束停止，崩溃恢复后重启；限频请求重发 |
| `WorkoutSpeedMath` / `CyclingStatistics` | Shared | 运动均速 = 距离 ÷ 有效运动时长（不含暂停），实时与记录同一口径 |
| `HeartRateZoneSettings` / `HeartRateZoneSettingsStore` | Shared / Core | 用户输入最大心率或下限，校验不重叠；Watch 本机存储 |
| `ZoneAlertEngine` / `ZoneAlertMonitor` | Core | 运行中、样本新鲜、连续 ≥ 3 样本且持续 ≥ 10 秒越界才提醒；冷却 60 秒；回到区间内 3 bpm 以上才重新武装；默认关闭 |
| `CyclingDisplayModel` | Core | Watch / iPhone 共用的显示规则：缺失 / 过期 / 暂停 / 未授权 / 断开 → `--` + 原因 |
| `CoreLocationFixProvider`、`WatchHapticPlayer` | watchOS App | `CLLocationManager`（使用期间授权）与 `WKInterfaceDevice.play(_:)` |

**Health Track**

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| `DailyMetricSeries` | Shared | 每个日历日一项，缺测为 `nil`；按 `Calendar` 逐日推进，夏令时不重复 / 缺失 |
| `BaselineWindows` / `BaselineComparison` | Shared | 观察期 = 最近 7 个完整日（不含今天），参考期 = 之前 28 天；中位数；参考 ≥ 14 天且观察 ≥ 4 天才给差值；超出合理范围的日值排除并计数 |
| `SleepInsight` | Shared | 最近一晚分期与占比、仅卧床标记；≥ 4 晚时给出平均时长与入睡 / 醒来时刻的均值和标准差（墙上时间，跨午夜与夏令时正确） |
| `HealthInsightsViewModel` | Core | 并发读取 35 天日值与睡眠；每张卡片独立 value / noData / failed；不缓存（H5 视真机性能再定） |
| `InsightsView` | iOS `Features/Insights` | 第三个 Tab「分析」；健康页静息心率 / HRV 卡片显示“较基线 ±n / 积累中” |

所有文案只描述数值、天数、来源；不生成“恢复分 / 身体电量”等综合评分，不做医学判断。演示模式下模拟 GPS、模拟区间与模拟健康数据均有明显标注。

## 9. v0.3 T1：运动数据层（数据可信度）

规则与阈值见 [ROADMAP_V02_V10.md](ROADMAP_V02_V10.md) 1.3.1 / 1.3.2。全部为确定性纯逻辑，只读：不写入、不删除、不修改 HealthKit 数据。

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| `WorkoutSourceInfo`、`WorkoutRecord.sourceInfo` | Shared | 来源 bundle / 设备 / 外部标识；可选字段，旧记录与演示数据为 `nil`，旧 `sourceName` 保留 |
| `WorkoutDuplicateDetector`、`WorkoutDeduplicator` | Shared | 确认重复 / 疑似重复 / 独立；疑似重复全部保留、统计只计一次、不传递、与输入顺序无关 |
| `HeartRateEvidence`、`HeartRateUsability` | Shared | 复用 `HeartRateAttribution`，加入覆盖率与异常样本，分级：无数据 / 仅可展示 / 可汇总 / 可比较 |
| `HeartRateZoneBasis`、`HeartRateZoneAnalyzer` | Shared | 个人训练区间（用户输入）与本次相对区间的口径标注与可比较性；不推算最大心率 |
| `WorkoutAnalysisRecord`、`WorkoutAnalysisBuilder`、`WorkoutEligibility` | Shared | 统一分析记录；按指标（时长 / 距离 / 均速 / 平均心率 / 区间 / 相同心率速度）给出统计与进步比较资格 |
| `WorkoutComparability` | Shared | 活动、室内外、来源、设备族、距离 / 时长量级与区间口径的成对可比较判定，返回具体原因 |
| `WorkoutVolumeSummary` | Shared | 仅含具备统计资格的记录；Calendar 注入，按开始时刻归属当地日，夏令时 / 时区安全 |
| `PerceivedEffortRecord`、`PerceivedEffortReconciler` | Shared | T5 存储契约（模型与对账规则）；无 UI、无持久化实现 |
| `WorkoutAnalysisLoader`、`WorkoutAnalysisViewModel`、`PerceivedEffortStore`（含内存参考实现） | Core | 在 `WorkoutHistoryService` 之上读取、去重、只为主记录读取心率（数量 / 并发有限，单条失败只降级该条） |
| `HealthKitWorkoutMapping.sourceInfo(from:)` | Core（HealthKit 边缘） | 只增字段：来源、`HKDevice`、`HKMetadataKeyExternalUUID` / `SyncIdentifier` |
| 运动历史标签、详情“数据可信度”小节、“本次相对区间”标注 | iOS | 只读标注，不改变列表内容与既有流程 |

`HeartRateZone`（本次相对区间）保持不变并标注口径；`WorkoutHeartRateDetail` 新增 `zoneBasis` / `heartRateEvidence`。Workout Mirroring、运动保存与 Demo 模式代码未改动。

## 10. v0.3 T2：个人运动目标

规则见 [ROADMAP_V02_V10.md](ROADMAP_V02_V10.md) 1.3 T2。目标数值由用户输入，不预设、不推荐、不自动调高；进度只描述完成情况，不做评价或建议。

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| `WorkoutGoal`、`WorkoutGoalMetric` | Shared | 每周运动次数 / 总时长 / 距离，可按运动类型筛选；创建与解码时都校验（> 0、次数为整数、距离只用于有距离的类型、防误输入上限） |
| `WorkoutGoalProgressCalculator` | Shared | 基于 T1 的 `WorkoutAnalysisRecord` 与 `WorkoutVolumeSummary`：只计具备统计资格的记录，疑似重复只计一次并报告，距离缺失不补 0；本周 + 之前 3 个完整自然周，周由注入的 `Calendar`（时区、每周第一天）决定，时区 / 夏令时安全；读取条数达上限时标注“可能不完整” |
| `WorkoutGoalStore`（`UserDefaults` / 内存实现） | Core | 仅本机；存储数据无法解析时先备份原始数据再从空列表开始，并提示用户，不静默覆盖 |
| `WorkoutGoalsViewModel` | Core | 目标增删改、暂停 / 恢复；运动记录经 `WorkoutAnalysisLoader` 读取（不读取心率曲线），读取失败时目标仍可管理、进度显示 `--` 而不是 0 |
| 「目标」Tab（`WorkoutGoalsView`） | iOS | 列表、进度条、说明（疑似重复 / 无距离 / 可能不完整）、新建 / 编辑表单（目标值初始为空）；演示模式目标只存内存 |

## 11. v0.3 T3：运动后反馈

规则见 [ROADMAP_V02_V10.md](ROADMAP_V02_V10.md) 1.3 T3。只描述本次与自己过去同类运动的数值差异（高 / 低 / 相近），不评价进步或退步，不做健康判断；“相同心率下的速度”等进步指标属于 T4。

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| `WorkoutFeedbackCalculator`、`WorkoutFeedback` | Shared | 对比对象 = 本次之前 90 天内、`WorkoutComparability` 判定可比的同类运动；每项指标（时长、距离、均速 / 配速、平均心率、个人区间分布）只用对该指标可比的运动，取最近 5 次的平均；少于 3 次该项不下判断；本次不满足进步比较资格时只展示数据。同类但不可比的运动计数并列出原因；结果与输入顺序无关 |
| `WorkoutFeedbackPresentation` | Shared | 文案：每条结论带对比对象与样本数；“相近”阈值为 ±5%（心率 ±3 次/分、区间占比 ±5 个百分点）；缺失显示 `--` |
| `WorkoutAnalysisLoader.load(limit:selectHeartRateTargets:)` | Core | 由调用方决定为哪些运动读取心率；反馈只读取本次与更早的同类运动（最多 21 条） |
| `WorkoutFeedbackViewModel` | Core | 读取最近 200 条运动；打开的是被合并的确认重复记录时按主记录计算；读取条数达上限时提示更早的运动可能未参与 |
| 运动详情“运动后反馈”小节（`WorkoutFeedbackSection`） | iOS | 位于汇总数据之后；iPhone 端暂无用户确认的个人心率区间，区间分布显示“未设置个人心率区间” |

`WorkoutAnalysisRecord` 新增 `mergedWorkoutIDs`，`WorkoutAnalysisSet.record(containing:)` 可从任一原始记录找到主记录。
