import AVFoundation
import AppKit
import MetalKit
import SwiftUI

/// 预览视图，用 MTKView 承载渲染器输出的帧。
///
/// 不再使用 `AVCaptureVideoPreviewLayer`：它直接显示原始画面，
/// 无法插入虚拟背景这类逐帧处理。
struct CameraPreview: NSViewRepresentable {

    let renderer: FrameRenderer
    var isMirrored: Bool

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        // CIContext 需要往 drawable 纹理里写，不能只当渲染目标。
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0.055, green: 0.059, blue: 0.067, alpha: 1)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        renderer.setMirrored(isMirrored)
    }

    /// 视图销毁时停掉渲染循环并摘掉 delegate。
    /// 否则 MTKView 可能在 renderer 释放之后继续回调 draw，关窗口时会挂住。
    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        nsView.isPaused = true
        nsView.enableSetNeedsDisplay = false
        nsView.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}
