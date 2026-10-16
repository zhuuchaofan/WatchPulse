import SwiftUI

/// 模拟数据标注。任何来自 Mock / 模拟实现的数据所在页面都必须显示。
struct DemoModeBanner: View {
    var text = "演示模式：以下均为模拟数据，不是你的真实健康数据"

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("demoBanner")
    }
}

#Preview {
    DemoModeBanner().padding()
}
