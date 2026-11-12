import AVKit
import AppKit
import SwiftUI

/// 全窗口预览层：照片看大图，视频直接播放，左右键切换。
struct MediaPreview: View {

    let items: [MediaItem]
    @Binding var current: MediaItem?
    let onDelete: (MediaItem) -> Void
    let onReveal: (MediaItem) -> Void
    let onClose: () -> Void

    private var index: Int? {
        guard let current else { return nil }
        return items.firstIndex { $0.id == current.id }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            if let item = current {
                VStack(spacing: 0) {
                    topBar(item)
                    viewer(item)
                    bottomBar(item)
                }
                .transition(.opacity)
            }

            shortcuts
        }
    }

    // MARK: - 顶栏

    private func topBar(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text(item.filename)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("关闭预览（Esc）")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - 画面

    @ViewBuilder
    private func viewer(_ item: MediaItem) -> some View {
        Group {
            switch item.kind {
            case .photo:
                PhotoStage(url: item.url)
            case .video:
                VideoStage(url: item.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(item.id)
    }

    // MARK: - 底栏

    private func bottomBar(_ item: MediaItem) -> some View {
        HStack(spacing: 14) {
            navButton(symbol: "chevron.left", enabled: canStep(-1)) { step(-1) }
                .help("上一张（←）")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.dateLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(item.sizeLabel)\(positionLabel)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            actionButton(symbol: "folder", title: "在访达中显示") { onReveal(item) }
            actionButton(symbol: "trash", title: "移到废纸篓", destructive: true) { onDelete(item) }

            navButton(symbol: "chevron.right", enabled: canStep(1)) { step(1) }
                .help("下一张（→）")
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
        .background(Color.white.opacity(0.04))
    }

    private var positionLabel: String {
        guard let index else { return "" }
        return "  ·  \(index + 1) / \(items.count)"
    }

    private func navButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary.opacity(0.4))
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(Color.white.opacity(enabled ? 0.09 : 0.03))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func actionButton(
        symbol: String,
        title: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(destructive ? Theme.recording : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 键盘

    private var shortcuts: some View {
        ZStack {
            Button("") { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func canStep(_ delta: Int) -> Bool {
        guard let index else { return false }
        return items.indices.contains(index + delta)
    }

    private func step(_ delta: Int) {
        guard let index else { return }
        let next = index + delta
        guard items.indices.contains(next) else { return }
        current = items[next]
    }
}

// MARK: - 照片

private struct PhotoStage: View {

    let url: URL

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .light))
                    Text("无法加载这张照片")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.textSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .padding(28)
        .task(id: url) {
            image = nil
            failed = false
            let target = url
            // 预览用 2048px 的降采样版本，比直接解码原图快得多。
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                MediaThumbnailer.cached(url: target, isVideo: false, maxPixel: 2048)
            }.value
            if let cg {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else {
                failed = true
            }
        }
    }
}

// MARK: - 视频

private struct VideoStage: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let playingURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        guard playingURL != url else { return }
        nsView.player?.pause()
        nsView.player = AVPlayer(url: url)
        nsView.player?.play()
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}
