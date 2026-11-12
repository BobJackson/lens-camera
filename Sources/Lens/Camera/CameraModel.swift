import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation
import Metal

/// 一次性的界面提示。
struct Toast: Identifiable, Equatable {
    enum Kind: Equatable { case success, failure }

    let id = UUID()
    let text: String
    let kind: Kind
}

/// 相机会话的唯一管理者。
///
/// 线程约定：所有 `@Published` 状态只在主线程读写；`AVCaptureSession` 的
/// 配置与启停一律派发到 `sessionQueue`，避免阻塞 UI。
final class CameraModel: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case preparing
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    enum CaptureMode: String, CaseIterable, Identifiable {
        case photo
        case video

        var id: String { rawValue }

        var title: String {
            switch self {
            case .photo: return "照片"
            case .video: return "视频"
            }
        }

        var symbol: String {
            switch self {
            case .photo: return "camera"
            case .video: return "video"
            }
        }
    }

    // MARK: - AVFoundation 对象

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.bob.lens.session", qos: .userInitiated)
    /// 逐帧处理队列。串行就够了 —— Vision 本身就是瓶颈，并发只会互相抢资源。
    private let videoQueue = DispatchQueue(label: "com.bob.lens.video", qos: .userInitiated)

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false

    /// 后台队列需要读取的少量状态，用锁保护一份快照，避免跨线程直接读 @Published。
    private let snapshotLock = NSLock()
    private var deviceIDSnapshot: String?
    private var mirrorSnapshot = true
    private var backgroundSnapshot = VirtualBackgroundConfig()

    /// 拍照委托需要活到回调触发为止，用 token 索引以便回调时精确释放。
    private var pendingPhotoDelegates: [UUID: PhotoCaptureDelegate] = [:]
    private let movieDelegate = MovieRecordingDelegate()

    // MARK: - 对外状态

    @Published private(set) var status: Status = .idle
    @Published private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var devices: [CameraDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isBusy = false

    @Published var captureMode: CaptureMode = .photo
    @Published var isMirrored = true {
        didSet {
            snapshotLock.lock()
            mirrorSnapshot = isMirrored
            snapshotLock.unlock()
        }
    }
    @Published var showGrid = true
    @Published var flashOverlay = false
    @Published var toast: Toast?

    @Published var backgroundConfig = VirtualBackgroundConfig() {
        didSet {
            snapshotLock.lock()
            backgroundSnapshot = backgroundConfig
            snapshotLock.unlock()
        }
    }

    /// 虚拟背景面板是否展开。做成取景框内的浮层，而不是 popover ——
    /// 相机类应用里设置面板浮在画面上更自然。
    @Published var showBackgroundPanel = DebugSupport.initialScreen == "background"

    /// 逐帧渲染器。设备不支持 Metal 时为 nil，预览会退化成黑屏而非崩溃。
    let renderer: FrameRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[Lens] 当前设备不支持 Metal，虚拟背景不可用")
            return nil
        }
        return FrameRenderer(device: device)
    }()

    var isBackgroundAvailable: Bool { renderer != nil }

    let library = MediaLibrary()

    /// MediaLibrary 是独立的 ObservableObject，视图观察的是 CameraModel，
    /// 需要把它的变更转发出去，否则图库和缩略图条不会自动刷新。
    private var libraryObserver: AnyCancellable?

    // MARK: - 生命周期

    override init() {
        super.init()

        libraryObserver = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        movieDelegate.onStart = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRecording = true
                self?.startRecordingTimer()
            }
        }

        movieDelegate.onFinish = { [weak self] url, error in
            DispatchQueue.main.async {
                self?.finishRecording(at: url, error: error)
            }
        }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(deviceListChanged),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(deviceListChanged),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )

        refreshDevices()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func deviceListChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let previous = self.selectedDeviceID
            self.refreshDevices()
            // 拔掉的正是当前设备时，自动切到剩下的第一个。
            if let previous, previous != self.selectedDeviceID {
                self.restartSession()
                self.showToast("已切换到 \(self.selectedDeviceName)", kind: .success)
            }
        }
    }

    var selectedDeviceName: String {
        devices.first { $0.id == selectedDeviceID }?.name ?? "未选择设备"
    }

    var selectedDevice: CameraDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    // MARK: - 设备枚举

    func refreshDevices() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        types.append(.continuityCamera)
        types.append(.deskViewCamera)

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )

        let list = discovery.devices.map(CameraDevice.init)
        devices = list.sorted { rank($0.kind) < rank($1.kind) }

        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            setSelectedDeviceID(devices.first?.id)
        }
    }

    private func rank(_ kind: CameraDevice.Kind) -> Int {
        switch kind {
        case .builtIn: return 0
        case .continuity: return 1
        case .external: return 2
        case .deskView: return 3
        case .unknown: return 4
        }
    }

    // MARK: - 权限

    /// 首次进入时调用：按当前授权状态决定是直接启动还是先弹权限。
    func prepare() {
        // 自检：用静态图冒充采集帧，绕过摄像头权限。
        if let path = DebugSupport.fakeFramePath {
            startFakeFrames(path: path)
            return
        }

        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .authorized:
            startSession()
        case .notDetermined:
            requestAuthorization()
        case .denied, .restricted:
            status = .idle
        @unknown default:
            status = .idle
        }
    }

    // MARK: - 自检假帧源

    private var fakeFrameTimer: Timer?
    private var fakeFrameImage: CIImage?
    private var fakeFrameBusy = false

    /// 自检模式下用普通 Image 呈现假帧。
    /// MTKView 的内容由 GPU 直接呈现，`CALayer.render` 抓不到，截图会是全黑。
    @Published private(set) var fakeFramePreviewImage: NSImage?

    /// 按 30fps 把一张静态图灌进渲染管线，处理不过来时丢帧 ——
    /// 和 `alwaysDiscardsLateVideoFrames` 的行为一致，用来复现真实采集负载。
    private func startFakeFrames(path: String) {
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
            NSLog("[Lens] 自检：无法读取假帧 \(path)")
            return
        }
        fakeFrameImage = image
        // 自检截图用：转成普通 NSImage，避开 MTKView 抓不到画面的问题。
        if let cgImage = CIContext().createCGImage(image, from: image.extent) {
            fakeFramePreviewImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
        // 假帧模式下视同已授权，否则取景框会被权限引导盖住。
        authorization = .authorized
        status = .running

        fakeFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let frame = self.fakeFrameImage, !self.fakeFrameBusy else { return }
            self.fakeFrameBusy = true

            self.snapshotLock.lock()
            let config = self.backgroundSnapshot
            self.snapshotLock.unlock()

            self.videoQueue.async {
                self.renderer?.processImage(frame, config: config)
                DispatchQueue.main.async {
                    self.fakeFrameBusy = false
                }
            }
        }
    }

    func requestAuthorization() {        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorization = granted ? .authorized : .denied
                if granted {
                    self.startSession()
                } else {
                    self.showToast("未获得相机权限", kind: .failure)
                }
            }
        }
    }

    /// 跳转到系统设置的隐私面板，方便用户手动放行。
    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 会话配置

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        guard let deviceID = currentSelectedDeviceID,
              let device = AVCaptureDevice(uniqueID: deviceID) else {
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        // 视频输入
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            videoInput = input
        } catch {
            NSLog("[Lens] 创建视频输入失败: \(error.localizedDescription)")
            return false
        }

        // 音频输入（录像用；没有麦克风也不该阻断拍照）
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        // 输出
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        }

        // 逐帧输出：预览和虚拟背景都依赖它。
        if session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            // 处理跟不上时直接丢帧，而不是排队堆积、越拖越迟。
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }

        isConfigured = true
        return true
    }

    func startSession() {
        guard authorization == .authorized else {
            prepare()
            return
        }
        status = .preparing
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configureIfNeeded() else {
                DispatchQueue.main.async {
                    self.status = .failed("无法初始化相机输入")
                }
                return
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.status = .running
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// 窗口关闭 / 应用退出时的完整清理。
    ///
    /// 必须是同步的：先停采集、再排空处理队列，最后让渲染器失效。
    /// 否则退出过程中主线程可能还在等 GPU，表现为整个应用卡死。
    func shutdown() {
        sessionQueue.sync {
            if session.isRunning {
                session.stopRunning()
            }
        }
        // 排空逐帧处理队列，确保没有帧还在写纹理。
        videoQueue.sync {}
        renderer?.invalidate()
    }

    /// 切换设备后需要重建输入。
    func selectDevice(id: String) {
        guard id != selectedDeviceID else { return }
        setSelectedDeviceID(id)
        restartSession()
        showToast("已切换到 \(selectedDeviceName)", kind: .success)
    }

    private func restartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let deviceID = self.currentSelectedDeviceID,
                  let device = AVCaptureDevice(uniqueID: deviceID) else { return }

            self.session.beginConfiguration()
            if let old = self.videoInput {
                self.session.removeInput(old)
                self.videoInput = nil
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoInput = input
                }
            } catch {
                NSLog("[Lens] 切换设备失败: \(error.localizedDescription)")
            }
            self.session.commitConfiguration()
        }
    }

    /// 主线程写、后台队列读的统一入口。
    private func setSelectedDeviceID(_ id: String?) {
        snapshotLock.lock()
        deviceIDSnapshot = id
        snapshotLock.unlock()
        selectedDeviceID = id
    }

    private var currentSelectedDeviceID: String? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return deviceIDSnapshot
    }

    // MARK: - 拍照

    func capturePhoto() {
        guard status.isRunning, !isBusy else { return }
        isBusy = true
        triggerFlash()

        let token = UUID()
        let delegate = PhotoCaptureDelegate { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingPhotoDelegates.removeValue(forKey: token)
                self.isBusy = false
                switch result {
                case .success(let data):
                    self.persistPhoto(data)
                case .failure(let error):
                    self.showToast("拍照失败：\(error.localizedDescription)", kind: .failure)
                }
            }
        }
        pendingPhotoDelegates[token] = delegate

        sessionQueue.async { [weak self] in
            guard let self, let connection = self.photoOutput.connection(with: .video), connection.isEnabled else {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.showToast("相机尚未就绪", kind: .failure)
                }
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// 保存照片。开了虚拟背景就先合成再落盘。
    /// 处理走视频队列串行执行 —— 分割器实例不可并发复用。
    private func persistPhoto(_ data: Data) {
        snapshotLock.lock()
        let config = backgroundSnapshot
        snapshotLock.unlock()

        guard let renderer, config.isActive else {
            writePhoto(data)
            return
        }

        videoQueue.async { [weak self] in
            var payload = data
            if let source = CIImage(data: data) {
                let composed = renderer.applyBackground(to: source, config: config)
                if let encoded = renderer.encodeJPEG(composed) {
                    payload = encoded
                }
            }
            DispatchQueue.main.async {
                self?.writePhoto(payload)
            }
        }
    }

    private func writePhoto(_ data: Data) {
        do {
            let item = try library.savePhoto(data: data)
            showToast("已保存 \(item.filename)", kind: .success)
        } catch {
            showToast(error.localizedDescription, kind: .failure)
        }
    }

    private func triggerFlash() {
        flashOverlay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            self?.flashOverlay = false
        }
    }

    // MARK: - 录像

    func toggleRecording() {
        guard status.isRunning else { return }
        if isRecording {
            sessionQueue.async { [weak self] in
                self?.movieOutput.stopRecording()
            }
        } else {
            let url = library.temporaryMovieURL()
            sessionQueue.async { [weak self] in
                guard let self else { return }
                guard let connection = self.movieOutput.connection(with: .video), connection.isEnabled else {
                    DispatchQueue.main.async {
                        self.showToast("相机尚未就绪", kind: .failure)
                    }
                    return
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = self.currentMirrorPreference
                }
                self.movieOutput.startRecording(to: url, recordingDelegate: self.movieDelegate)
            }
        }
    }

    private var currentMirrorPreference: Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return mirrorSnapshot
    }

    private func finishRecording(at url: URL, error: Error?) {
        stopRecordingTimer()
        isRecording = false

        if let error {
            // 只要文件已落盘就仍然采纳，仅提示异常。
            NSLog("[Lens] 录像结束附带错误: \(error.localizedDescription)")
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast("录像失败：未生成文件", kind: .failure)
            return
        }

        do {
            let item = try library.adoptMovie(at: url)
            showToast("已保存 \(item.filename)", kind: .success)
        } catch {
            showToast(error.localizedDescription, kind: .failure)
        }
    }

    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    private func startRecordingTimer() {
        recordingStartedAt = Date()
        recordingDuration = 0
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartedAt else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }

    var formattedRecordingDuration: String {
        let total = Int(recordingDuration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 提示

    func showToast(_ text: String, kind: Toast.Kind) {
        let toast = Toast(text: text, kind: kind)
        self.toast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
    }
}

// MARK: - 逐帧处理

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let renderer else { return }

        // 在采集队列上取锁保护的快照，不直接读 @Published。
        snapshotLock.lock()
        let config = backgroundSnapshot
        snapshotLock.unlock()

        // 必须同步处理完：回调返回后 pixelBuffer 就被池回收了。
        renderer.process(pixelBuffer: pixelBuffer, config: config)
    }
}
