import AVFoundation
import AppKit
import SwiftUI

struct ContentView: View {

    private enum Mode: Equatable {
        case camera
        case library
    }

    @StateObject private var camera = CameraModel()
    @State private var mode: Mode = {
        let screen = DebugSupport.initialScreen
        return (screen == "library" || screen == "preview") ? .library : .camera
    }()

    var body: some View {
        ZStack {
            switch mode {
            case .camera:
                cameraInterface
                    .transition(.opacity)
            case .library:
                LibraryView(camera: camera) { mode = .camera }
                    .transition(.opacity)
            }
        }
        .background(Theme.panel)
        .background(WindowConfigurator())
        .frame(minWidth: 840, minHeight: 620)
        .animation(.easeInOut(duration: 0.18), value: mode)
        .onAppear { camera.prepare() }
        .onDisappear { camera.shutdown() }
    }

    private var cameraInterface: some View {
        VStack(spacing: 0) {
            HeaderBar(camera: camera, onOpenLibrary: openLibrary)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            Viewfinder(camera: camera)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            ControlBar(camera: camera, onOpenLibrary: openLibrary)
        }
    }

    private func openLibrary() {
        mode = .library
    }
}

// MARK: - 顶部

private struct HeaderBar: View {

    @ObservedObject var camera: CameraModel
    let onOpenLibrary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)

            Text("Lens")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            StatusPill(status: camera.status, authorization: camera.authorization)

            Spacer(minLength: 8)

            if let device = camera.selectedDevice, let resolution = device.resolutionLabel {
                Text(resolution)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            libraryButton

            IconButton(symbol: "folder", help: "打开照片文件夹") {
                camera.library.openDirectory(for: .photo)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    private var libraryButton: some View {
        Button(action: onOpenLibrary) {
            HStack(spacing: 5) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 11.5, weight: .medium))
                Text("图库")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("l", modifiers: .command)
        .help("打开图库（⌘L）")
    }
}

private struct StatusPill: View {

    let status: CameraModel.Status
    let authorization: AVAuthorizationStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
        )
    }

    private var color: Color {
        if authorization != .authorized { return Theme.textTertiary }
        switch status {
        case .running: return Theme.success
        case .preparing: return Theme.accent
        case .idle: return Theme.textTertiary
        case .failed: return Theme.recording
        }
    }

    private var text: String {
        if authorization == .denied || authorization == .restricted { return "无权限" }
        switch status {
        case .running: return "就绪"
        case .preparing: return "启动中"
        case .idle: return "待机"
        case .failed(let message): return message
        }
    }
}

// MARK: - 底部控制栏

private struct ControlBar: View {

    @ObservedObject var camera: CameraModel
    let onOpenLibrary: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ThumbnailStrip(camera: camera, onOpenLibrary: onOpenLibrary)
                .frame(width: 268, alignment: .leading)

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                ModeSwitcher(mode: $camera.captureMode, isRecording: camera.isRecording)
                ShutterButton(
                    mode: camera.captureMode,
                    isRecording: camera.isRecording,
                    isBusy: camera.isBusy,
                    enabled: camera.status.isRunning
                ) {
                    switch camera.captureMode {
                    case .photo: camera.capturePhoto()
                    case .video: camera.toggleRecording()
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 8)

            DeviceControls(camera: camera)
                .frame(width: 268, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(height: 124)
    }
}

// MARK: - 窗口

/// 让整个窗口背景可拖动，配合 hiddenTitleBar 得到无边框观感。
private struct WindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        WindowTuner()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowTuner: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(Theme.panel)
        }
    }
}
