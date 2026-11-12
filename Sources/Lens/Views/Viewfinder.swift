import AVFoundation
import SwiftUI

struct Viewfinder: View {

    @ObservedObject var camera: CameraModel

    private var isAuthorized: Bool { camera.authorization == .authorized }

    var body: some View {
        ZStack {
            Theme.viewfinder

            if isAuthorized, let renderer = camera.renderer {
                CameraPreview(renderer: renderer, isMirrored: camera.isMirrored)
            }

            if isAuthorized && camera.showGrid {
                GridOverlay()
            }

            if camera.isRecording {
                VStack {
                    RecordingBadge(duration: camera.formattedRecordingDuration)
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !isAuthorized {
                PermissionPrompt(
                    status: camera.authorization,
                    onRequest: { camera.requestAuthorization() },
                    onOpenSettings: { camera.openPrivacySettings() }
                )
            }

            if camera.status == .preparing {
                PreparingOverlay()
            }

            if camera.showBackgroundPanel {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VirtualBackgroundPanel(camera: camera)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                            .padding(16)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // 快门瞬间的白闪，纯装饰、不吃点击。
            Color.white
                .opacity(camera.flashOverlay ? 0.7 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.09), value: camera.flashOverlay)

            if let toast = camera.toast {
                VStack {
                    Spacer()
                    ToastView(toast: toast)
                        .padding(.bottom, 20)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: camera.toast)
        .animation(.easeInOut(duration: 0.22), value: camera.isRecording)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - 三分网格

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                for index in 1..<3 {
                    let x = w * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))

                    let y = h * CGFloat(index) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 录制指示

struct RecordingBadge: View {

    let duration: String

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.recording)
                .frame(width: 7, height: 7)
                .opacity(pulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulsing)

            Text(duration)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .onAppear { pulsing = true }
    }
}

// MARK: - 启动中

struct PreparingOverlay: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.textSecondary)
            Text("正在启动相机…")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - 权限引导

struct PermissionPrompt: View {

    let status: AVAuthorizationStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button(action: status == .notDetermined ? onRequest : onOpenSettings) {
                Text(status == .notDetermined ? "允许访问相机" : "打开系统设置")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(28)
    }

    private var title: String {
        status == .notDetermined ? "需要相机权限" : "相机权限已被拒绝"
    }

    private var message: String {
        status == .notDetermined
            ? "Lens 需要访问摄像头才能显示实时画面。画面只在本机处理，不会上传。"
            : "请在「系统设置 › 隐私与安全性 › 相机」中勾选 Lens，然后重新打开应用。"
    }
}

// MARK: - 提示条

struct ToastView: View {

    let toast: Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(toast.kind == .success ? Theme.success : Theme.recording)

            Text(toast.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.68))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}
