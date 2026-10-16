import SwiftUI
import UIKit

/// 统一视觉规范（与 HTML 预览一致）：暖白底、白色卡片、鼠尾草绿为主色，杏色只用于“本周 / 进行中”的少量强调。
///
/// 对比度约定：`sage` / `apricot` 只用于图标、图表和 24pt 以上的数字；正文与小字一律用 `text` / `secondaryText`，
/// 需要绿色或杏色文字时用 `sageText` / `apricotText`（浅色与深色下都满足 4.5:1）。
enum Theme {
    // MARK: 颜色

    static let background = dynamic(light: 0xF6F4EE, dark: 0x111613)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1B221E)
    static let text = dynamic(light: 0x1E2722, dark: 0xECF0EC)
    static let secondaryText = dynamic(light: 0x56635B, dark: 0xA7B3AB)
    static let sage = dynamic(light: 0x5B8A6C, dark: 0x86BB98)
    static let sageText = dynamic(light: 0x3D6A4F, dark: 0x9CD0AE)
    static let mint = dynamic(light: 0xE4F0E8, dark: 0x22332A)
    static let apricot = dynamic(light: 0xE58F55, dark: 0xEFA672)
    static let apricotText = dynamic(light: 0x9E5220, dark: 0xF2B184)
    static let line = dynamic(light: 0xE8E4DA, dark: 0x2A332D)
    /// 主按钮底色与其上的文字。
    static let button = dynamic(light: 0x4E7D60, dark: 0x86BB98)
    static let buttonText = dynamic(light: 0xFFFFFF, dark: 0x0F1A13)
    /// “结束运动”按钮：深杏色底（深色模式为亮杏色底、深色字），与“暂停”明显区分。
    static let endButton = dynamic(light: 0x9E5220, dark: 0xEFA672)
    static let endButtonText = dynamic(light: 0xFFFFFF, dark: 0x24160B)
    /// 提示 / 读取失败等需要注意、但不是警报的文字。
    static let notice = apricotText

    // MARK: 尺寸

    static let cardRadius: CGFloat = 20
    static let innerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 20
    static let gutter: CGFloat = 16
    static let cardSpacing: CGFloat = 16

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 组件

/// 白色卡片：圆角 20、内边距 20、1pt 细边。
struct CardBackground: ViewModifier {
    var padding: CGFloat = Theme.cardPadding

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
    }
}

/// 卡片内的浅绿色块（例如今日页的两项身体指标）。
struct TileBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.mint, in: RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
    }
}

extension View {
    func cardStyle(padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// 只加卡片底色与细边（调用方自己控制内边距与宽度）。
    func cardBackground() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
    }

    func tile() -> some View {
        modifier(TileBackground())
    }

    /// 页面底色（滚动视图 / 列表都适用）。列表行保持系统分组行底色（浅色白、深色近卡片色）。
    func screenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

/// 大号数字：圆体、等宽数字，随动态字体缩放。
struct MetricNumber: View {
    let value: String
    var unit: String?
    var style: Font.TextStyle = .largeTitle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(style, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            if let unit {
                Text(unit)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// 主按钮：绿色胶囊，至少 44pt 高。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.buttonText)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(Theme.button.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

/// 次要按钮：无底色的绿色文字，至少 44pt 高。
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.sageText.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var themePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var themeSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// 卡片标题行：绿色图标 + 标题，可带右侧说明（如时间范围）。
struct CardHeader: View {
    let title: String
    var systemImage: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.sage)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
