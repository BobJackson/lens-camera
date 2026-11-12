import CoreGraphics
import Foundation
import SwiftUI

/// 纯色背景预设。
enum SolidBackground: String, CaseIterable, Identifiable {
    case graphite
    case midnight
    case sand
    case mint
    case rose
    case studio

    var id: String { rawValue }

    var name: String {
        switch self {
        case .graphite: return "石墨"
        case .midnight: return "午夜"
        case .sand: return "砂岩"
        case .mint: return "薄荷"
        case .rose: return "玫瑰"
        case .studio: return "影棚"
        }
    }

    /// sRGB 分量。
    var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .graphite: return (0.16, 0.17, 0.19)
        case .midnight: return (0.06, 0.11, 0.24)
        case .sand: return (0.84, 0.75, 0.61)
        case .mint: return (0.56, 0.80, 0.70)
        case .rose: return (0.88, 0.68, 0.68)
        case .studio: return (0.93, 0.93, 0.94)
        }
    }

    var swiftUIColor: Color {
        let c = components
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

/// 虚拟背景配置。值语义，主线程写入、采集队列读取。
struct VirtualBackgroundConfig: Equatable {

    enum Kind: Equatable {
        case off
        case blur
        case solid(SolidBackground)
        case custom
    }

    var kind: Kind = .off

    /// 模糊背景的高斯半径。
    var blurRadius: Double = 28

    /// 自定义背景图（已经解码好，避免每帧读盘）。
    var customImage: CGImage?
    var customImageName: String?

    var isActive: Bool { kind != .off }

    var displayName: String {
        switch kind {
        case .off: return "原始画面"
        case .blur: return "模糊"
        case .solid(let preset): return preset.name
        case .custom: return customImageName ?? "自定义图片"
        }
    }

    /// CGImage 不参与比较，用文件名代表自定义背景。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind
            && lhs.blurRadius == rhs.blurRadius
            && lhs.customImageName == rhs.customImageName
    }
}
