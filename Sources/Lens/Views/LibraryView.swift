import AppKit
import SwiftUI

/// 图库：浏览、筛选、预览、删除已拍摄的媒体。
struct LibraryView: View {

    @ObservedObject var camera: CameraModel
    let onClose: () -> Void

    @State private var filter: MediaFilter = .all
    @State private var previewItem: MediaItem?
    @State private var pendingDelete: MediaItem?
    @State private var toast: Toast?

    private var items: [MediaItem] { camera.library.items(matching: filter) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(Theme.hairline).frame(height: 1)
                content
            }

            if previewItem != nil {
                MediaPreview(
                    items: items,
                    current: Binding(
                        get: { previewItem },
                        set: { previewItem = $0 }
                    ),
                    onDelete: { requestDelete($0) },
                    onReveal: { camera.library.revealInFinder($0) },
                    onClose: { previewItem = nil }
                )
                .transition(.opacity)
            }

            if let toast {
                VStack {
                    Spacer()
                    ToastView(toast: toast).padding(.bottom, 28)
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: previewItem)
        .animation(.easeInOut(duration: 0.2), value: toast)
        .onAppear {
            camera.library.reload()
            // 自检用：直接打开第一项的预览。
            if DebugSupport.initialScreen == "preview" {
                previewItem = items.first
            }
        }
        .alert(
            "移到废纸篓？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("移到废纸篓", role: .destructive) { confirmDelete(item) }
        } message: { item in
            Text("\(item.filename)\n可从废纸篓恢复。")
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("相机")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)

            Text("图库")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            FilterPicker(filter: $filter, library: camera.library)

            Text("共 \(items.count) 项")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)

            IconButton(symbol: "arrow.clockwise", help: "重新扫描磁盘") {
                camera.library.reload()
                showToast("已重新扫描", kind: .success)
            }

            IconButton(symbol: "folder", help: "在访达中打开照片目录") {
                camera.library.openDirectory(for: .photo)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 158, maximum: 230), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(items) { item in
                        LibraryCell(item: item) {
                            previewItem = item
                        }
                        .contextMenu {
                            Button("预览") { previewItem = item }
                            Button("在访达中显示") { camera.library.revealInFinder(item) }
                            Button("用默认应用打开") { camera.library.open(item) }
                            Divider()
                            Button("移到废纸篓", role: .destructive) { pendingDelete = item }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .video ? "video.slash" : "photo.on.rectangle.angled")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)

            Text(emptyTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text("照片保存在 ~/Pictures/Lens，视频保存在 ~/Movies/Lens")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return "还没有拍摄任何内容"
        case .photo: return "还没有照片"
        case .video: return "还没有视频"
        }
    }

    // MARK: - 删除

    private func requestDelete(_ item: MediaItem) {
        pendingDelete = item
    }

    private func confirmDelete(_ item: MediaItem) {
        pendingDelete = nil

        // 记下删除前的位置，删完自动落到相邻的一张，方便连续清理。
        let list = items
        let position = list.firstIndex { $0.id == item.id }

        do {
            try camera.library.delete(item)
            MediaThumbnailer.invalidate(url: item.url)

            if previewItem?.id == item.id {
                let remaining = list.filter { $0.id != item.id }
                if remaining.isEmpty {
                    previewItem = nil
                } else if let position {
                    previewItem = remaining[min(position, remaining.count - 1)]
                } else {
                    previewItem = remaining.first
                }
            }

            showToast("已移到废纸篓", kind: .success)
        } catch {
            showToast("删除失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    private func showToast(_ text: String, kind: Toast.Kind) {
        let newToast = Toast(text: text, kind: kind)
        toast = newToast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast?.id == newToast.id { toast = nil }
        }
    }
}

// MARK: - 筛选器

private struct FilterPicker: View {

    @Binding var filter: MediaFilter
    @ObservedObject var library: MediaLibrary

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MediaFilter.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { filter = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("\(count(for: item))")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .opacity(0.6)
                    }
                    .foregroundStyle(filter == item ? Color.black : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(filter == item ? Theme.accent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func count(for item: MediaFilter) -> Int {
        switch item {
        case .all: return library.allItems.count
        case .photo: return library.count(of: .photo)
        case .video: return library.count(of: .video)
        }
    }
}

// MARK: - 网格单元

private struct LibraryCell: View {

    let item: MediaItem
    let onOpen: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.textTertiary)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .padding(7)
                }
            }
            .overlay(alignment: .bottom) {
                if hovering {
                    Text(item.filename)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(
                            .rect(
                                bottomLeadingRadius: 10,
                                bottomTrailingRadius: 10
                            )
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        hovering ? Theme.accent.opacity(0.85) : Color.white.opacity(0.08),
                        lineWidth: hovering ? 1.5 : 1
                    )
            )
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help("\(item.filename)\n\(item.dateLabel) · \(item.sizeLabel)")
        .task(id: item.id) { await load() }
    }

    private func load() async {
        let url = item.url
        let isVideo = item.kind == .video
        let cg = await Task.detached(priority: .utility) { () -> CGImage? in
            MediaThumbnailer.cached(url: url, isVideo: isVideo, maxPixel: 420)
        }.value
        if let cg {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

// MARK: - 小图标按钮

struct IconButton: View {

    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.10) : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
