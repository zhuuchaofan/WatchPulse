// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WatchPulseKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WatchPulseShared", targets: ["WatchPulseShared"]),
        .library(name: "WatchPulseCore", targets: ["WatchPulseCore"]),
    ],
    targets: [
        // 纯模型与运动镜像契约：只依赖 Foundation，iOS / watchOS 共用。
        .target(name: "WatchPulseShared"),
        // 健康数据服务协议、HealthKit 实现、Mock 与 ViewModel。
        .target(name: "WatchPulseCore", dependencies: ["WatchPulseShared"]),
        .testTarget(name: "WatchPulseSharedTests", dependencies: ["WatchPulseShared"]),
        .testTarget(name: "WatchPulseCoreTests", dependencies: ["WatchPulseCore", "WatchPulseShared"]),
    ]
)
