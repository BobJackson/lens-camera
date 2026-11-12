import AppKit
import AVFoundation
import Foundation

enum MediaKind: String, Codable {
    case photo
    case video

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        }
    }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all
    case photo
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .photo: return "照片"
        case .video: return "视频"
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    let url: URL
    let kind: MediaKind
    let createdAt: Date

    /// 用路径做标识：重新扫描磁盘时 id 保持不变，SwiftUI 不会重建视图、缩略图也不会重载。
    var id: String { url.path }

    var filename: String { url.lastPathComponent }

    /// 人类可读的文件大小，例如 “2.4 MB”。
    var sizeLabel: String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let bytes = values.fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var dateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: createdAt)
    }
}

/// 负责把拍摄结果落盘到用户目录，并维护最近拍摄列表。
/// 刻意不使用「照片图库」，避免额外的图库授权弹窗；文件直接归入 Pictures / Movies。
///
/// 线程约定：所有方法都从主线程调用。
final class MediaLibrary: ObservableObject {

    /// 磁盘上的全部媒体，按拍摄时间倒序。
    @Published private(set) var allItems: [MediaItem] = []

    /// 供控制栏缩略图条使用的最近若干张。
    @Published private(set) var recent: [MediaItem] = []

    @Published private(set) var isScanning = false

    /// 最近一次保存的提示（用于 UI 上的一次性反馈）。
    @Published var lastSaved: MediaItem?

    private let fileManager = FileManager.default
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - 目录

    var picturesDirectory: URL {
        let base = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return base.appendingPathComponent("Lens", isDirectory: true)
    }

    var moviesDirectory: URL {
        let base = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return base.appendingPathComponent("Lens", isDirectory: true)
    }

    @discardableResult
    private func ensureDirectory(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("[Lens] 创建目录失败 \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 路径

    func destinationURL(for kind: MediaKind, date: Date = Date()) -> URL {
        let stamp = timestampFormatter.string(from: date)
        switch kind {
        case .photo:
            return picturesDirectory.appendingPathComponent("Lens_\(stamp).jpg")
        case .video:
            return moviesDirectory.appendingPathComponent("Lens_\(stamp).mov")
        }
    }

    /// 录像输出需要一个「此刻尚不存在」的地址。
    func temporaryMovieURL() -> URL {
        let stamp = timestampFormatter.string(from: Date())
        return fileManager.temporaryDirectory
            .appendingPathComponent("lens-capture-\(stamp)-\(UUID().uuidString.prefix(6)).mov")
    }

    // MARK: - 保存

    /// 保存照片数据，返回落盘后的条目。
    @discardableResult
    func savePhoto(data: Data, date: Date = Date()) throws -> MediaItem {
        guard ensureDirectory(picturesDirectory) else {
            throw LensError.storageUnavailable(picturesDirectory.path)
        }
        let url = destinationURL(for: .photo, date: date)
        try data.write(to: url, options: .atomic)

        // 写入 EXIF 拍摄时间，方便按时间归档。
        applyCreationDate(date, to: url)

        let item = MediaItem(url: url, kind: .photo, createdAt: date)
        register(item)
        return item
    }

    /// 把录像输出产生的临时文件移入影片目录。
    @discardableResult
    func adoptMovie(at temporaryURL: URL, date: Date = Date()) throws -> MediaItem {
        guard ensureDirectory(moviesDirectory) else {
            throw LensError.storageUnavailable(moviesDirectory.path)
        }
        let url = destinationURL(for: .video, date: date)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporaryURL, to: url)
        applyCreationDate(date, to: url)

        let item = MediaItem(url: url, kind: .video, createdAt: date)
        register(item)
        return item
    }

    private func applyCreationDate(_ date: Date, to url: URL) {
        try? fileManager.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    private func register(_ item: MediaItem) {
        allItems.insert(item, at: 0)
        refreshRecent()
        lastSaved = item
    }

    private func refreshRecent() {
        recent = Array(allItems.prefix(24))
    }

    // MARK: - 图库

    /// 支持的扩展名。用户手动往目录里放的文件也能被识别。
    private static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "gif"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// 重新扫描磁盘。进入图库时调用一次即可。
    func reload() {
        isScanning = true
        defer { isScanning = false }

        let photos = scan(directory: picturesDirectory)
        let videos = scan(directory: moviesDirectory)
        allItems = (photos + videos).sorted { $0.createdAt > $1.createdAt }
        refreshRecent()
    }

    private func scan(directory: URL) -> [MediaItem] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return urls.compactMap { url -> MediaItem? in
            let ext = url.pathExtension.lowercased()
            let kind: MediaKind
            if Self.photoExtensions.contains(ext) {
                kind = .photo
            } else if Self.videoExtensions.contains(ext) {
                kind = .video
            } else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return MediaItem(url: url, kind: kind, createdAt: date)
        }
    }

    /// 移到废纸篓而不是直接抹掉 —— 误删还能捞回来。
    func delete(_ item: MediaItem) throws {
        guard fileManager.fileExists(atPath: item.url.path) else {
            // 文件已不在磁盘上，仅从列表移除。
            allItems.removeAll { $0.id == item.id }
            refreshRecent()
            return
        }

        var resultingURL: NSURL?
        try fileManager.trashItem(at: item.url, resultingItemURL: &resultingURL)

        allItems.removeAll { $0.id == item.id }
        refreshRecent()
        if lastSaved?.id == item.id { lastSaved = nil }
    }

    /// 批量删除，返回成功与失败数量。
    @discardableResult
    func delete(_ items: [MediaItem]) -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        for item in items {
            do {
                try delete(item)
                succeeded += 1
            } catch {
                NSLog("[Lens] 删除失败 \(item.filename): \(error.localizedDescription)")
                failed += 1
            }
        }
        return (succeeded, failed)
    }

    func count(of kind: MediaKind) -> Int {
        allItems.filter { $0.kind == kind }.count
    }

    func items(matching filter: MediaFilter) -> [MediaItem] {
        switch filter {
        case .all: return allItems
        case .photo: return allItems.filter { $0.kind == .photo }
        case .video: return allItems.filter { $0.kind == .video }
        }
    }

    // MARK: - 打开

    func open(_ item: MediaItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(_ item: MediaItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openDirectory(for kind: MediaKind) {
        let dir = kind == .photo ? picturesDirectory : moviesDirectory
        if ensureDirectory(dir) {
            NSWorkspace.shared.open(dir)
        }
    }
}

enum LensError: LocalizedError {
    case storageUnavailable(String)
    case cameraUnavailable(String)
    case captureFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .storageUnavailable(let path):
            return "无法写入目录：\(path)"
        case .cameraUnavailable(let reason):
            return "相机不可用：\(reason)"
        case .captureFailed(let reason):
            return "拍摄失败：\(reason)"
        case .permissionDenied:
            return "未获得相机访问权限"
        }
    }
}
