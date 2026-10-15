# WatchPulse

日常健康监控 + Apple Watch 实时运动监控应用（iOS + watchOS，SwiftUI + HealthKit，无后端、无第三方 SDK）。

> **验证状态**：所有功能已在云端完成编译（iOS / watchOS 模拟器与真机架构）和自动化测试（单元、模拟端到端、稳定性、演示模式 UI 测试）。
> iPhone 端已在真机上验证部分数据读取（最新心率、静息心率、HRV、步数、活动能量、运动详情与心率曲线）；**Apple Watch 运动、镜像与保存尚未在真机上验证**。
> **v0.2（骑行增强 + 健康分析）全部功能尚未在真机上验证**，见清单中的 C.x / H.x 项。
> 编译成功和模拟测试通过都不等于真机功能验收，逐项结果见 [docs/DEVICE_VALIDATION.md](docs/DEVICE_VALIDATION.md)。产品定位与验证计划见 [docs/PRODUCT_STRATEGY.md](docs/PRODUCT_STRATEGY.md)，版本路线见 [docs/ROADMAP_V02_V10.md](docs/ROADMAP_V02_V10.md)。

架构与设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 功能

| 模块 | 功能 |
| --- | --- |
| 健康总览 | 最新心率（值、单位、采样时间、来源）；静息心率、HRV、今日步数、今日活动能量、昨晚睡眠；单项失败不影响其他项 |
| 历史趋势 | 各指标 7 / 30 / 90 天图表、统计（平均 / 最低 / 最高 / 合计）、每日明细 |
| Apple Watch 运动 | 跑步 / 步行 / 骑行 / HIIT / 其他，室内 / 室外；实时心率、能量、距离；暂停 / 继续 / 结束；崩溃恢复 |
| 运动镜像 | Watch 运动自动镜像到 iPhone；iPhone 实时仪表盘与心率曲线；iPhone 远程暂停 / 继续 / 结束；断线检测与自动重连 |
| 运动记录 | Watch 结束运动后保存到“健康”；iPhone 历史列表（按月）、详情、心率曲线与心率区间 |
| 骑行（v0.2） | 室外骑行 Apple Watch GPS 实时速度（来源 / 有效性标注，缺失显示 `--`）、运动均速；手表骑行页；iPhone 大字骑行码表与心率区间条；近 30 天骑行统计 |
| 心率区间（v0.2） | 在手表上按最大心率或自定义下限设置 Z1–Z5（不使用年龄公式）；目标区间低频震动提醒（默认关闭，持续 / 冷却 / 滞回控制） |
| 分析（v0.2） | 静息心率、HRV 近 7 天与此前 28 天中位数对比（个人基线，样本不足显示“积累中”）；睡眠分期、仅卧床说明、作息规律；7 / 28 天趋势。只描述数值，不做诊断 |
| 演示模式 | 全部模拟数据（界面有明显标注），用于无真机时查看界面与 UI 测试 |

## 环境要求

- Xcode 16 或更新版本（Swift 6 语言模式；CI 使用 Xcode 16.4）
- iOS 17+ 的 iPhone；watchOS 10+ 的 Apple Watch（运动镜像需要两者配对）
- Apple 开发者账号

## 工程结构

| 路径 | 说明 |
| --- | --- |
| `WatchPulse.xcodeproj` | 由 `project.yml` 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成，已提交，可直接打开 |
| `Packages/WatchPulseKit` | `WatchPulseShared`（模型、镜像协议）+ `WatchPulseCore`（服务、ViewModel、运动状态机、模拟实现） |
| `WatchPulse/` · `WatchPulseWatch/` · `WatchPulseUITests/` | iOS App、watchOS App、UI 测试 |
| `Config/Signing.xcconfig` | Team ID 与 Bundle ID |

修改 `project.yml` 后运行 `brew install xcodegen && xcodegen generate` 重新生成工程。

## Scheme

| Scheme | 用途 |
| --- | --- |
| `WatchPulse` | iOS 真实模式（HealthKit）；⌘U 运行包测试与 UI 测试 |
| `WatchPulse Demo` | iOS 演示模式（模拟数据）；可在模拟器中体验全部界面，包括模拟 Apple Watch 运动和断线恢复 |
| `WatchPulseWatch` | watchOS 真实模式 |
| `WatchPulseWatch Demo` | watchOS 演示模式（模拟运动驱动，不写入“健康”） |

## 真机运行步骤

1. 在 `Config/` 下新建 `Signing.local.xcconfig`（已被 git 忽略）：
   ```
   DEVELOPMENT_TEAM = 你的TeamID
   WATCHPULSE_BUNDLE_ID = com.你的标识.WatchPulse
   ```
2. 打开 `WatchPulse.xcodeproj`，在 Signing & Capabilities 中确认 `WatchPulse`、`WatchPulseWatch` 两个 target 的 Team 正确、**HealthKit** capability 已显示。
3. 选择 `WatchPulse` scheme 和 iPhone，⌘R 运行。首次需信任开发者证书并开启开发者模式。Watch App 请用 `WatchPulseWatch` scheme 直接运行到手表（个人团队签名下，经 iPhone「Watch」App 安装会提示“无法验证其完整性”），步骤与排障见 [docs/WATCH_DEVICE_SETUP.md](docs/WATCH_DEVICE_SETUP.md)。
4. 按 [docs/DEVICE_VALIDATION.md](docs/DEVICE_VALIDATION.md) 逐项验证并记录结果。

## 测试

```bash
swift test --package-path Packages/WatchPulseKit     # macOS / Linux 均可（不含 HealthKit 的逻辑）
```

Xcode 中 `WatchPulse` scheme 的 Test（⌘U）在 iOS 模拟器上运行包测试和 UI 测试（UI 测试只使用演示模式数据）。

## CI

`.github/workflows/ci.yml`（GitHub Actions macOS runner）：

1. `swift test`（macOS 上同时编译 HealthKit 实现）；
2. `xcodebuild` 编译 iOS App + 嵌入的 watchOS App：模拟器（Swift 警告视为错误）与不签名的真机架构；单独编译 watchOS scheme；
3. 汇总编译警告；检查产物 Info.plist 隐私说明与 Watch App 嵌入；
4. iOS 模拟器上运行包测试与演示模式 UI 测试。

CI 只能证明代码可编译、逻辑与界面流程在模拟条件下正确，**不能**替代真机签名、HealthKit 真实数据与 Apple Watch 镜像的验收。
