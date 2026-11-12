import AppKit
import CoreImage
import Foundation
import Metal

/// 通过环境变量启用的自检钩子。正常运行（不带这些变量）时完全不参与。
///
/// - `LENS_SNAPSHOT=<路径>`：启动后把主窗口内容渲染成 PNG 写入该路径，然后退出。
/// - `LENS_SCREEN=camera|library`：指定启动时进入哪个界面，便于分别取图。
///
/// 之所以用 `CALayer.render(in:)` 而不是 `screencapture`：渲染自己的窗口层级
/// 不需要屏幕录制权限，在沙箱或未授权的环境里也能拿到画面。
enum DebugSupport {

    static var snapshotPath: String? {
        ProcessInfo.processInfo.environment["LENS_SNAPSHOT"]
    }

    static var initialScreen: String? {
        ProcessInfo.processInfo.environment["LENS_SCREEN"]
    }

    /// 启动 N 秒后自动关闭窗口，用来验证「关窗口不卡死」。
    static var autoCloseDelay: TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment["LENS_AUTOCLOSE"],
              let value = TimeInterval(raw) else { return nil }
        return value
    }

    /// 自检用假帧源：拿一张静态图按 30fps 灌进渲染管线，
    /// 在没有摄像头权限的情况下复现真实采集负载。
    static var fakeFramePath: String? {
        ProcessInfo.processInfo.environment["LENS_FAKE_FRAMES"]
    }

    static func captureMainWindow(to path: String, delay: TimeInterval = 2.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView,
                  let layer = view.layer else {
                NSLog("[Lens] 自检：找不到可渲染的窗口")
                exit(3)
            }

            let scale = window.backingScaleFactor
            let width = Int(view.bounds.width * scale)
            let height = Int(view.bounds.height * scale)

            guard width > 0, height > 0,
                  let context = CGContext(
                      data: nil,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else {
                NSLog("[Lens] 自检：无法创建绘图上下文")
                exit(4)
            }

            // CGContext 原点在左下，CALayer 几何原点在左上，先把 Y 轴翻过来再渲染。
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            layer.render(in: context)

            guard let cgImage = context.makeImage(),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                NSLog("[Lens] 自检：PNG 编码失败")
                exit(5)
            }

            do {
                try data.write(to: URL(fileURLWithPath: path))
                NSLog("[Lens] 自检：已写入 \(path)")
                exit(0)
            } catch {
                NSLog("[Lens] 自检：写入失败 \(error)")
                exit(6)
            }
        }
    }

    // MARK: - 虚拟背景自检

    static var backgroundTestInput: String? {
        ProcessInfo.processInfo.environment["LENS_BG_TEST_IN"]
    }

    static var backgroundTestOutput: String? {
        ProcessInfo.processInfo.environment["LENS_BG_TEST_OUT"]
    }

    /// 用一张静态图跑完整的「人像分割 → 替换背景」管线，输出并排对比图。
    /// 不依赖摄像头权限，用来确认蒙版方向、缩放与合成是否正确。
    static func runBackgroundTest(input: String, output: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = FrameRenderer(device: device) else {
            NSLog("[Lens] 自检：无法创建渲染器")
            exit(7)
        }

        guard let source = CIImage(contentsOf: URL(fileURLWithPath: input)) else {
            NSLog("[Lens] 自检：无法读取 \(input)")
            exit(8)
        }

        var variants: [(String, VirtualBackgroundConfig)] = []

        var blur = VirtualBackgroundConfig()
        blur.kind = .blur
        blur.blurRadius = 30
        variants.append(("模糊", blur))

        var solid = VirtualBackgroundConfig()
        solid.kind = .solid(.midnight)
        variants.append(("午夜", solid))

        var panels: [CIImage] = []
        for (name, config) in variants {
            let started = Date()
            let result = renderer.applyBackground(to: source, config: config)
            // CIImage 是惰性的，强制编码一次才能真正测到耗时。
            _ = renderer.encodeJPEG(result, quality: 0.8)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            NSLog("[Lens] 自检：\(name) 合成耗时 \(ms) ms")
            panels.append(result)
        }

        let width = source.extent.width
        let height = source.extent.height
        var canvas = CIImage(color: .black).cropped(
            to: CGRect(x: 0, y: 0, width: width * CGFloat(panels.count), height: height)
        )
        for (index, panel) in panels.enumerated() {
            let placed = panel.transformed(by: CGAffineTransform(
                translationX: width * CGFloat(index) - panel.extent.minX,
                y: -panel.extent.minY
            ))
            canvas = placed.composited(over: canvas)
        }

        // 缩到 1920 宽，便于直接查看。
        let scale = 1920 / canvas.extent.width
        let scaled = canvas.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard renderer.writePNG(scaled, to: URL(fileURLWithPath: output)) else {
            NSLog("[Lens] 自检：写入失败")
            exit(9)
        }
        NSLog("[Lens] 自检：已写入 \(output)")
        exit(0)
    }
}
