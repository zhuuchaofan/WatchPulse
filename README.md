# WatchPulse

日常健康监控 + 实时运动监控应用（iOS + watchOS，SwiftUI + HealthKit）。

**当前为第一阶段**：iPhone 通过 HealthKit 读取并显示最新一条真实心率记录（数值、单位、采样时间、来源）。Watch 端只有最小 App 和运动镜像的扩展接口，暂不实现实时运动同步。

架构设计、状态机和运动镜像扩展点见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 环境要求

- Xcode 16 或更新版本（Swift 6 语言模式）
- iOS 17+ 的 iPhone、watchOS 10+ 的 Apple Watch（可选）
- Apple 开发者账号（个人免费账号也可以在真机运行 HealthKit App）

## 工程结构

| 路径 | 说明 |
| --- | --- |
| `WatchPulse.xcodeproj` | 由 `project.yml` 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成，已提交，可直接打开 |
| `Packages/WatchPulseKit` | 本地 Swift Package：`WatchPulseShared`（模型/镜像契约）、`WatchPulseCore`（服务/ViewModel/Mock） |
| `WatchPulse/` | iOS App target |
| `WatchPulseWatch/` | watchOS App target（嵌入在 iOS App 中） |
| `Config/Signing.xcconfig` | Team ID 与 Bundle ID |

修改 `project.yml` 后运行 `brew install xcodegen && xcodegen generate` 重新生成工程。

## 真机运行步骤（验收）

1. 在 `Config/` 下新建 `Signing.local.xcconfig`（已被 git 忽略）：
   ```
   DEVELOPMENT_TEAM = 你的TeamID
   WATCHPULSE_BUNDLE_ID = com.你的标识.WatchPulse
   ```
   Team ID 可以在 Xcode › Settings › Accounts 或 developer.apple.com › Membership 中查看。Bundle ID 必须在你的账号下唯一。
2. 打开 `WatchPulse.xcodeproj`，选中 `WatchPulse` target › Signing & Capabilities，确认 Team 正确、**HealthKit** capability 已显示（来自 `WatchPulse.entitlements`）。`WatchPulseWatch` target 同样检查一遍。
3. 确认 iPhone 上的“健康”App 至少有一条心率记录（佩戴 Apple Watch 测量一次，或在“健康 › 浏览 › 心脏 › 心率”中手动添加一条）。
4. 选择 `WatchPulse` scheme 和你的 iPhone，⌘R 运行。首次运行需在 iPhone「设置 › 通用 › VPN 与设备管理」中信任开发者证书，并打开「设置 › 隐私与安全性 › 开发者模式」。
5. App 显示“需要读取心率数据”，点击 **授权读取心率**，在系统授权页中打开“心率”，然后点“允许”。
6. **验收标准**：页面显示“最新心率”卡片，数值、单位 `count/min`、采样时间、来源与「健康」App 中最新一条心率记录一致。

如果显示“暂无可读取的心率记录”：可能是没有数据，也可能是关闭了读取权限。可在「设置 › 隐私与安全性 › 健康 › WatchPulse」中检查后返回 App，App 回到前台时会自动重新读取。

## 测试

```bash
swift test --package-path Packages/WatchPulseKit     # macOS / Linux 均可
```

在 Xcode 中，`WatchPulse` scheme 的 Test（⌘U）会在 iOS 模拟器上运行同一组包测试。

SwiftUI Preview（`HealthOverviewView.swift`）覆盖已读取 / 加载中 / 需要授权 / 无数据 / 读取失败 / 设备不支持六种状态，全部使用 `MockHealthDataService`。示例数据来源明确标注为“预览示例数据（非真实）”，**不能**作为真机验收依据。

## CI

`.github/workflows/ci.yml` 在 GitHub Actions 的 macOS runner 上运行：
- `swift test`（在 macOS 上会一并编译 HealthKit 实现）；
- `xcodebuild` 编译 iOS App 和嵌入的 watchOS App（模拟器 + 不签名的真机 arm64）；
- 检查产物中的 Info.plist 隐私用途说明和 Watch App 嵌入；
- 在 iOS 模拟器上运行包测试。

CI 只能证明代码可以编译、逻辑测试能通过，**不能**替代真机签名和 HealthKit 真机读数验收。
