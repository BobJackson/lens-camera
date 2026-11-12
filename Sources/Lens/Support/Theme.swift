import SwiftUI

/// 全局视觉常量。深色取景 + 半透明玻璃控制栏，让注意力集中在画面上。
enum Theme {

    // MARK: - 取景区

    /// 取景框底色（无信号时）。
    static let viewfinder = Color(red: 0.055, green: 0.059, blue: 0.067)

    /// 控制栏背景。
    static let panel = Color(red: 0.098, green: 0.106, blue: 0.118)

    /// 面板上浮一层的卡片。
    static let card = Color(red: 0.141, green: 0.149, blue: 0.165)

    /// 分隔线。
    static let hairline = Color.white.opacity(0.09)

    // MARK: - 文字

    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.34)

    // MARK: - 强调色

    /// 主强调色，用于高亮状态与主按钮。
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.24)

    /// 录制中。
    static let recording = Color(red: 0.98, green: 0.27, blue: 0.31)

    /// 成功/已保存。
    static let success = Color(red: 0.30, green: 0.80, blue: 0.52)

    // MARK: - 尺寸

    static let controlBarHeight: CGFloat = 96
    static let cornerRadius: CGFloat = 12
}

/// 玻璃质感的分组容器。
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            )
    }
}

/// 统一的区块小标题。
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
    }
}
