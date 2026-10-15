# Apple Watch 真机安装与排障

本文记录把 `WatchPulseWatch` 安装到 Apple Watch 的步骤，以及首次真机调试时实际遇到的问题（2026-10-15，Xcode 27 + watchOS 26.6，个人团队签名）。

## 安装步骤

1. iPhone 版已能用 `WatchPulse` scheme 正常运行（见 README）。
2. iPhone 用数据线连 Mac 并解锁；手表戴在手上、解锁，电量 **50% 以上**，未开低电量模式。
3. Mac、iPhone、手表连**同一个 Wi-Fi**（Mac 用网线上网也要打开 Wi-Fi），关闭 Mac 上的 VPN / 代理（Clash、Surge 等 TUN / 增强模式）。
4. Xcode 按 **⇧⌘2** 打开设备窗口（新版 Xcode 的 Window 菜单里可能没有 “Devices and Simulators”，也可从顶部设备选择器 › “Manage Run Destinations…” 打开），等待手表从 “Connecting” 变为已连接。首次连接需要准备调试支持，可能要 5–15 分钟；手表上出现“信任此电脑”时点信任。
5. 连接成功后，手表 › 设置 › 隐私与安全性 › 最下方出现 **开发者模式**，打开并重启手表。**这个选项在手表首次与 Xcode 连接成功之前是隐藏的。**
6. Xcode 顶部 scheme 选 **`WatchPulseWatch`**，运行设备选手表，⌘R。

## 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| “…watchOS platform doesn't match **WatchPulse.app**'s supported platforms” | 用 iPhone 的 `WatchPulse` scheme 运行到了手表 | scheme 改为 `WatchPulseWatch`。**不要**修改 Base SDK / Supported Platforms |
| “…watchOS␣␣doesn't match WatchPulseWatch.app's watchOS 10.0 deployment target”（watchOS 后面没有版本号） | Xcode 还没与手表建立连接，读不到手表系统版本；并非版本真的过低 | 先解决连接问题（下一行）。只有手表系统确实低于 10.0 时才需要升级手表，**不要**降低 deployment target（Workout Mirroring 需要 watchOS 10） |
| 设备窗口一直 “Connecting”，或连上又断开、提示需在附近 | Mac 与手表之间的局域网通道不通：Wi-Fi 不同 / 网络有 AP 隔离（公司、学校、酒店、访客网络）/ VPN 代理 / 防火墙 / 手表电量低 | 换家用网络或用另一台手机的热点让 Mac 和手表同网；关 VPN 和防火墙的“阻止所有传入连接”；手表充电到 50% 以上；重启手表、iPhone，⌘Q 退出 Xcode。仍不行：设备窗口右键手表和 iPhone › Unpair Device，重新插线信任；最后手段：iPhone 设置 › 通用 › 传输或还原 iPhone › 还原 › 还原位置与隐私（只清除信任记录） |
| 手表上的 App 图标点开提示“无法安装…无法验证其完整性” | 通过 iPhone「Watch」App 安装，但个人团队的描述文件中没有注册这块手表 | 手表与 Xcode 连接后直接用 `WatchPulseWatch` scheme 安装，会自动注册设备并覆盖旧安装 |
| 手表上长按图标无法删除 | watchOS 10 起长按不再提供删除 | 不需要删除，Xcode 安装会覆盖；或 iPhone「Watch」App › 我的手表 › WatchPulse › 关闭“在 Apple Watch 上显示 App” |
| 找不到 Window › Devices and Simulators | 新版 Xcode 调整了菜单 | 快捷键 ⇧⌘2，或设备选择器 › “Manage Run Destinations…” |

## 个人团队（免费）签名的限制

- 描述文件 **7 天**过期，过期后 App 打不开，需重新用 Xcode 运行一次。
- 每台设备最多同时安装 3 个个人团队签名的 App；iPhone App 与 Watch App 各占一个 App ID，7 天内最多新建 10 个 App ID（不要频繁更换 Bundle ID）。
- HealthKit 与 Workout Mirroring 在个人团队下可用（iPhone 端已于 2026-10-15 实测 HealthKit 读取正常）。
