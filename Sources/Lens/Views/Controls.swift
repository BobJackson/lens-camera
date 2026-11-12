import AVFoundation
import AppKit
import SwiftUI

// MARK: - 快门

struct ShutterButton: View {

    let mode: CameraModel.CaptureMode
    let isRecording: Bool
    let isBusy: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(enabled ? 0.8 : 0.22), lineWidth: 3)
                    .frame(width: 60, height: 60)

                inner
            }
            .frame(width: 68, height: 68)
            .contentShape(Circle())
            .scaleEffect(hovering && enabled ? 1.045 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || (mode == .photo && isBusy))
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help(mode == .photo ? "拍照（空格）" : (isRecording ? "停止录制（空格）" : "开始录制（空格）"))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: mode)
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    @ViewBuilder
    private var inner: some View {
        switch mode {
        case .photo:
            Circle()
                .fill(isBusy ? Color.white.opacity(0.45) : Color.white)
                .frame(width: 46, height: 46)
        case .video:
            RoundedRectangle(cornerRadius: isRecording ? 5 : 23, style: .continuous)
                .fill(Theme.recording)
                .frame(width: isRecording ? 24 : 46, height: isRecording ? 24 : 46)
        }
    }
}

// MARK: - 模式切换

struct ModeSwitcher: View {

    @Binding var mode: CameraModel.CaptureMode
    let isRecording: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CameraModel.CaptureMode.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { mode = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(mode == item ? Color.black : Theme.textSecondary)
                        .frame(width: 54, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(mode == item ? Theme.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isRecording)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .opacity(isRecording ? 0.45 : 1)
    }
}

// MARK: - 设备与开关

struct DeviceControls: View {

    @ObservedObject var camera: CameraModel

    var body: some View {
        HStack(spacing: 8) {
            IconToggle(
                symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                isOn: camera.isMirrored,
                help: camera.isMirrored ? "关闭镜像预览" : "开启镜像预览"
            ) {
                camera.isMirrored.toggle()
            }

            IconToggle(
                symbol: "grid",
                isOn: camera.showGrid,
                help: camera.showGrid ? "隐藏网格" : "显示网格"
            ) {
                camera.showGrid.toggle()
            }

            backgroundButton

            deviceMenu
        }
    }

    private var backgroundButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                camera.showBackgroundPanel.toggle()
            }
        } label: {
            Image(systemName: "person.and.background.dotted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(camera.backgroundConfig.isActive ? Theme.accent : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            camera.backgroundConfig.isActive
                                ? Theme.accent.opacity(0.16)
                                : Color.white.opacity(0.07)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!camera.isBackgroundAvailable)
        .help(camera.backgroundConfig.isActive
              ? "虚拟背景：\(camera.backgroundConfig.displayName)"
              : "虚拟背景")
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(camera.devices) { device in
                Button {
                    camera.selectDevice(id: device.id)
                } label: {
                    if device.id == camera.selectedDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }

            if camera.devices.isEmpty {
                Text("未检测到摄像头")
            }

            Divider()

            Button("重新扫描设备") {
                camera.refreshDevices()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: camera.selectedDevice?.kind.symbol ?? "camera")
                    .font(.system(size: 11.5, weight: .medium))
                Text(camera.selectedDeviceName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct IconToggle: View {

    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? Theme.accent.opacity(0.16) : Color.white.opacity(hovering ? 0.10 : 0.07))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 最近拍摄

struct ThumbnailStrip: View {

    @ObservedObject var camera: CameraModel
    let onOpenLibrary: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if camera.library.recent.isEmpty {
                Button(action: onOpenLibrary) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 12))
                        Text("尚无拍摄")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("打开图库")
            } else {
                ForEach(camera.library.recent.prefix(3)) { item in
                    ThumbnailCell(item: item) {
                        onOpenLibrary()
                    }
                }

                Button(action: onOpenLibrary) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("打开图库（⌘L）")
            }
        }
    }
}

struct ThumbnailCell: View {

    let item: MediaItem
    let onTap: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }

                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(hovering ? Theme.accent.opacity(0.7) : Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.filename)
        .task(id: item.id) {
            let url = item.url
            let isVideo = item.kind == .video
            let cg = await Task.detached(priority: .utility) { () -> CGImage? in
                MediaThumbnailer.cached(url: url, isVideo: isVideo, maxPixel: 216)
            }.value
            if let cg {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

/// 缩略图生成放在后台，避免选中大图时卡住主线程。
enum MediaThumbnailer {

    /// 按「路径 + 尺寸」缓存，滚动网格时不会反复解码同一张图。
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 600
        return cache
    }()

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }

    static func cached(url: URL, isVideo: Bool, maxPixel: Int) -> CGImage? {
        let cacheKey = key(url, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let image = make(url: url, isVideo: isVideo, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    static func make(url: URL, isVideo: Bool, maxPixel: Int = 216) -> CGImage? {
        if isVideo {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 文件被删除后清掉相关缓存。
    static func invalidate(url: URL) {
        for pixel in [216, 420, 2048] {
            cache.removeObject(forKey: key(url, pixel))
        }
    }
}
