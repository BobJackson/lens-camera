import AVFoundation
import Foundation

/// 对 AVCaptureDevice 的一层轻量包装，只保留 UI 需要的字段。
struct CameraDevice: Identifiable, Hashable {

    enum Kind {
        case builtIn
        case external
        case continuity
        case deskView
        case unknown

        var label: String {
            switch self {
            case .builtIn: return "内置"
            case .external: return "外接"
            case .continuity: return "连续互通"
            case .deskView: return "桌面视角"
            case .unknown: return "其他"
            }
        }

        var symbol: String {
            switch self {
            case .builtIn: return "laptopcomputer"
            case .external: return "web.camera"
            case .continuity: return "iphone"
            case .deskView: return "rectangle.on.rectangle.angled"
            case .unknown: return "camera"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind

    /// 设备当前支持的最高拍照分辨率描述，例如 “1920 × 1080”。
    let resolutionLabel: String?

    init(_ device: AVCaptureDevice) {
        self.id = device.uniqueID
        self.name = device.localizedName

        switch device.deviceType {
        case .builtInWideAngleCamera:
            self.kind = .builtIn
        case .external:
            self.kind = .external
        case .continuityCamera:
            self.kind = .continuity
        case .deskViewCamera:
            self.kind = .deskView
        default:
            self.kind = .unknown
        }

        // 从格式列表里挑出像素数最大的那个作为宣传值。
        let best = device.formats
            .map { $0.formatDescription.dimensions }
            .max { lhs, rhs in
                Int(lhs.width) * Int(lhs.height) < Int(rhs.width) * Int(rhs.height)
            }
        if let best, best.width > 0, best.height > 0 {
            self.resolutionLabel = "\(best.width) × \(best.height)"
        } else {
            self.resolutionLabel = nil
        }
    }
}

extension CameraDevice.Kind: Equatable {}
