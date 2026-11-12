import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 虚拟背景选择面板，以 popover 形式挂在取景框的工具按钮上。
struct VirtualBackgroundPanel: View {

    @ObservedObject var camera: CameraModel

    private let columns = [GridItem(.adaptive(minimum: 56, maximum: 74), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            LazyVGrid(columns: columns, spacing: 10) {
                offTile
                blurTile
                ForEach(SolidBackground.allCases) { preset in
                    solidTile(preset)
                }
                customTile
            }

            if camera.backgroundConfig.kind == .blur {
                blurSlider
            }

            footer
        }
        .padding(16)
        .frame(width: 336)
        .background(Theme.panel)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.and.background.dotted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)

            Text("虚拟背景")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            Text(camera.backgroundConfig.displayName)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    camera.showBackgroundPanel = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .help("关闭面板")
        }
    }

    private var footer: some View {
        Text("预览与拍照都会套用；录像暂不支持。人像分割在本机完成。")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 选项

    private var offTile: some View {
        tile(label: "原图", isSelected: camera.backgroundConfig.kind == .off) {
            apply(.off)
        } content: {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: "slash.circle")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var blurTile: some View {
        tile(label: "模糊", isSelected: camera.backgroundConfig.kind == .blur) {
            apply(.blur)
        } content: {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.46, green: 0.53, blue: 0.63),
                        Color(red: 0.22, green: 0.28, blue: 0.38)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    private func solidTile(_ preset: SolidBackground) -> some View {
        let isSelected = camera.backgroundConfig.kind == .solid(preset)
        return tile(label: preset.name, isSelected: isSelected) {
            apply(.solid(preset))
        } content: {
            preset.swiftUIColor
        }
    }

    private var customTile: some View {
        let isSelected = camera.backgroundConfig.kind == .custom
        return tile(label: "自定义", isSelected: isSelected) {
            pickImage()
        } content: {
            ZStack {
                if let cgImage = camera.backgroundConfig.customImage {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.06)
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var blurSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模糊强度")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(camera.backgroundConfig.blurRadius))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            Slider(
                value: Binding(
                    get: { camera.backgroundConfig.blurRadius },
                    set: { value in
                        var config = camera.backgroundConfig
                        config.blurRadius = value
                        camera.backgroundConfig = config
                    }
                ),
                in: 8...60
            )
            .controlSize(.small)
        }
    }

    // MARK: - 通用

    private func tile<Content: View>(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                content()
                    .frame(height: 46)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? Theme.accent : Color.white.opacity(0.10),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )

                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func apply(_ kind: VirtualBackgroundConfig.Kind) {
        var config = camera.backgroundConfig
        config.kind = kind
        camera.backgroundConfig = config
    }

    // MARK: - 自定义图片

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择一张图片作为虚拟背景"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let cgImage = Self.loadDownsampled(url: url) else {
            camera.showToast("无法读取该图片", kind: .failure)
            return
        }

        var config = camera.backgroundConfig
        config.kind = .custom
        config.customImage = cgImage
        config.customImageName = url.lastPathComponent
        camera.backgroundConfig = config
    }

    /// 4K 原图没必要整个上传显存，先降到 2560px。
    private static func loadDownsampled(url: URL, maxPixel: Int = 2560) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
