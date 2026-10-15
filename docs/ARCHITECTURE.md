# WatchPulse 架构设计（第一阶段）

## 1. 阶段目标

第一阶段只交付**最小可运行闭环**：

> iPhone 真机通过 HealthKit 读取并显示**一条真实心率记录**（数值、单位、采样时间、来源）。

明确**不在**本阶段实现：实时运动会话、Workout Mirroring 数据同步、后台投递、写入健康数据、任何网络/后端/第三方 SDK。

## 2. 分层（MVVM + Service）

```
┌──────────────────────────── iOS App (WatchPulse) ─────────────────────────────┐
│  View  : HealthOverviewView / HeartRateCard （SwiftUI，只负责渲染 State）       │
│     │ 绑定                                                                     │
│  ViewModel : HealthOverviewViewModel（@Observable @MainActor，状态机）          │  ← WatchPulseCore
│     │ 依赖协议                                                                  │
│  Service 协议 : HealthDataService                                               │  ← WatchPulseCore
│     ├─ HealthKitHealthDataService（真实实现，#if canImport(HealthKit)）         │
│     └─ MockHealthDataService（仅用于 Preview / 单元测试）                       │
│  Model : HeartRateSample / HealthSampleSource / HealthDataError …               │  ← WatchPulseShared
└───────────────────────────────────────────────────────────────────────────────┘
┌────────────────────────── watchOS App (WatchPulseWatch) ──────────────────────┐
│  WatchHomeView → WatchWorkoutManager（实现 WorkoutSessionManaging，本阶段占位）│
│  Workout 契约：WorkoutSessionPhase / WorkoutMetricsSnapshot /                  │  ← WatchPulseShared
│               WorkoutMirroringMessage + WorkoutMirroringCodec                 │
└───────────────────────────────────────────────────────────────────────────────┘
```

共享代码放在本地 Swift Package `Packages/WatchPulseKit`，两个库：

| 模块 | 内容 | 依赖 |
| --- | --- | --- |
| `WatchPulseShared` | 纯模型 + 运动镜像契约（Codable、Sendable），无平台依赖 | Foundation |
| `WatchPulseCore` | `HealthDataService` 协议、HealthKit 实现、Mock、ViewModel | Shared、Observation、HealthKit（条件编译） |

这样做的好处：
- 不依赖 HealthKit 的逻辑（状态机、模型、编解码）可以在 macOS / Linux 上用 `swift test` 直接测试；
- iOS 与 watchOS 共用同一份模型和镜像消息格式，后续 Mirroring 两端不会出现格式漂移。

## 3. 健康总览状态机

`HealthOverviewViewModel.State`：

| 状态 | 触发条件 | UI |
| --- | --- | --- |
| `idle` | 初始 | 等同加载中 |
| `loading` | 正在查询授权状态 / 读取数据 | ProgressView |
| `healthDataUnavailable` | `HKHealthStore.isHealthDataAvailable() == false` | 设备不支持说明 |
| `needsAuthorization` | `statusForAuthorizationRequest == .shouldRequest` | 说明 + “授权读取心率”按钮（**按需授权**，不在启动时自动弹窗） |
| `noData` | 查询成功但结果为空 | “暂无心率记录” + 可能原因（含“可能未授予读取权限”，但**不断言**为拒绝） |
| `failed(HealthDataError)` | 查询/授权抛错 | 错误说明 + 重试 |
| `loaded(HeartRateSample)` | 拿到最新一条样本 | 数值、单位、采样时间、来源、设备 |

**关于“无数据 ≠ 拒绝权限”**：HealthKit 出于隐私不会告诉 App 读取权限是否被拒绝；被拒绝时查询表现为“返回空结果”。因此 `noData` 只能表述为“没有可读取的记录”，并引导用户到「健康 App › 共享 › App › WatchPulse」检查，而不是显示“权限被拒绝”。`statusForAuthorizationRequest` 返回 `.unnecessary` 也只代表“已经弹过授权框”，不代表用户允许了读取。

## 4. 运动镜像扩展点（参考 Apple《Building a multidevice workout app》）

Apple 示例的流程：

1. **Watch** 创建 `HKWorkoutSession` + `HKLiveWorkoutBuilder`，调用 `session.startMirroringToCompanionDevice()`；
2. **iPhone** 在启动早期设置 `healthStore.workoutSessionMirroringStartHandler`，收到镜像出来的 `HKWorkoutSession`；
3. 两端通过 `session.sendToRemoteWorkoutSession(data:)` 互发 `Data`，通过 `HKWorkoutSessionDelegate.workoutSession(_:didReceiveDataFromRemoteWorkoutSession:)` 接收；
4. 运动状态变化通过 `workoutSession(_:didChangeTo:from:date:)` 同步。

本阶段预留的接口：

| 接口 | 位置 | 对应上面步骤 |
| --- | --- | --- |
| `WorkoutConfigurationRequest`、`WorkoutActivityKind`、`WorkoutLocation` | Shared | 第 1 步构造 `HKWorkoutConfiguration` |
| `WorkoutSessionPhase` | Shared | 第 4 步，映射 `HKWorkoutSessionState` |
| `WorkoutMetricsSnapshot` | Shared | Watch 从 `HKLiveWorkoutBuilder` 汇总后发送 |
| `WorkoutMirroringMessage` + `WorkoutMirroringCodec`（带版本号的 JSON 封包） | Shared | 第 3 步 `Data` 的格式 |
| `WorkoutSessionManaging`（Watch 端，主会话所有者） | Shared | 第 1、3、4 步 |
| `MirroredWorkoutReceiving`（iPhone 端，镜像接收方） | Shared | 第 2、3 步 |
| `WatchWorkoutManager` | Watch target | 第 1 步实现位置（本阶段抛 `notImplementedInThisPhase`） |
| `PhoneWorkoutMirroringCoordinator` | iOS target | 第 2 步实现位置（本阶段不注册 handler） |

## 5. 目录结构

```
WatchPulse/
├── project.yml                         # XcodeGen 工程定义（工程的唯一来源）
├── WatchPulse.xcodeproj                # 由 project.yml 生成，已提交，可直接打开
├── Config/Signing.xcconfig             # Team ID、Bundle ID（真机运行前唯一需要改的地方）
├── Packages/WatchPulseKit/
│   ├── Package.swift
│   ├── Sources/WatchPulseShared/
│   │   ├── Models/      HeartRateSample.swift, HealthDataError.swift, HealthAuthorizationRequestStatus.swift
│   │   └── Workout/     WorkoutConfiguration.swift, WorkoutSessionPhase.swift, WorkoutMetricsSnapshot.swift,
│   │                    WorkoutMirroringMessage.swift, WorkoutSessionContracts.swift
│   ├── Sources/WatchPulseCore/
│   │   ├── Services/    HealthDataService.swift, HealthKitHealthDataService.swift, MockHealthDataService.swift
│   │   └── ViewModels/  HealthOverviewViewModel.swift
│   └── Tests/           WatchPulseSharedTests/, WatchPulseCoreTests/
├── WatchPulse/                         # iOS App target
│   ├── App/             WatchPulseApp.swift, AppDependencies.swift
│   ├── Features/HealthOverview/  HealthOverviewView.swift, HeartRateCard.swift
│   ├── Features/Workout/         PhoneWorkoutMirroringCoordinator.swift
│   ├── Resources/Assets.xcassets
│   ├── Info.plist, WatchPulse.entitlements
├── WatchPulseWatch/                    # watchOS App target（单 target watch App，嵌入 iOS App）
│   ├── App/WatchPulseWatchApp.swift, Views/WatchHomeView.swift, Workout/WatchWorkoutManager.swift
│   ├── Resources/Assets.xcassets
│   ├── Info.plist, WatchPulseWatch.entitlements
└── .github/workflows/ci.yml            # macOS runner：swift test + iOS/watchOS 模拟器编译
```

## 6. 实现步骤

1. 写共享模型与镜像契约（WatchPulseShared）及单元测试；
2. 写 `HealthDataService` 协议、Mock、ViewModel 状态机及单元测试；
3. 写 `HealthKitHealthDataService`（`HKSampleQueryDescriptor`，按 `endDate` 倒序，limit 1）；
4. 写 iOS 视图（每种状态都有 Preview，使用 Mock）；
5. 写 Watch 最小 App 与运动管理占位；
6. 写 `project.yml`、Info.plist、entitlements，生成 `.xcodeproj`；
7. 构建验证：Linux 上 `swift test`；GitHub Actions macOS runner 上 `swift test` + `xcodebuild` 编译 iOS / watchOS 模拟器；
8. 真机验收（需要开发者在 Mac + iPhone 上完成，见 README）。
