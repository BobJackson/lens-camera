import CoreImage
import CoreVideo
import Metal
import MetalKit

/// 帧渲染器。采集队列负责处理并写入离屏纹理，MTKView 只做一次贴屏。
///
/// 之所以不在 `draw(in:)` 里做分割：拿到的 `CVPixelBuffer` 在采集回调返回后
/// 就会被池回收，必须当场用完；而且把 Vision 放在主线程会直接卡住 UI。
final class FrameRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let segmenter: PersonSegmenter
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var frameTexture: MTLTexture?
    private let lock = NSLock()
    private var mirrored = true
    /// 窗口关闭后置位，采集侧与渲染侧都不再触碰 GPU 资源。
    private var isInvalidated = false

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }

        // cacheIntermediates 关掉：每帧内容都不同，缓存只会白占显存。
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])

        self.device = device
        self.commandQueue = queue
        self.ciContext = context
        self.segmenter = PersonSegmenter(ciContext: context)
        super.init()
    }

    // MARK: - 采集侧

    func setMirrored(_ value: Bool) {
        lock.lock()
        mirrored = value
        lock.unlock()
    }

    /// 由采集队列调用。必须同步完成 —— 回调返回后 pixelBuffer 即失效。
    func process(pixelBuffer: CVPixelBuffer, config: VirtualBackgroundConfig) {
        lock.lock()
        let stopped = isInvalidated
        lock.unlock()
        guard !stopped else { return }

        let image = segmenter.composite(pixelBuffer: pixelBuffer, config: config)
        renderOffscreen(image)
    }

    /// 自检用：直接送一张 CIImage 走完整渲染路径，用来在没有摄像头权限时复现采集负载。
    func processImage(_ image: CIImage, config: VirtualBackgroundConfig) {
        lock.lock()
        let stopped = isInvalidated
        lock.unlock()
        guard !stopped else { return }

        renderOffscreen(segmenter.composite(image: image, config: config))
    }

    /// 窗口关闭时调用：停止一切后续渲染，避免在资源释放过程中继续碰 GPU。
    func invalidate() {
        lock.lock()
        isInvalidated = true
        frameTexture = nil
        lock.unlock()
    }

    /// 拍照保存路径：对静态图套用同一套背景合成。
    func applyBackground(to image: CIImage, config: VirtualBackgroundConfig) -> CIImage {
        segmenter.composite(image: image, config: config)
    }

    /// 把处理结果编码回 JPEG。
    func encodeJPEG(_ image: CIImage, quality: Double = 0.95) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            ): quality
        ]
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }

    func writePNG(_ image: CIImage, to url: URL) -> Bool {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.pngRepresentation(
                  of: image,
                  format: .RGBA8,
                  colorSpace: colorSpace,
                  options: [:]
              ) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private func renderOffscreen(_ image: CIImage) {
        let extent = image.extent
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return }

        lock.lock()
        if frameTexture == nil || frameTexture?.width != width || frameTexture?.height != height {
            frameTexture = makeTexture(width: width, height: height)
        }
        let texture = frameTexture
        lock.unlock()

        guard let texture else { return }

        // 渲染必须放在锁外：这一步会同步等待 GPU，可能上百毫秒。
        // 若持锁等待，主线程的 draw 会一直抢不到锁 —— 关窗口时就表现为整个应用卡死。
        ciContext.render(
            image,
            to: texture,
            commandBuffer: nil,
            bounds: extent,
            colorSpace: colorSpace
        )
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        lock.lock()
        let texture = isInvalidated ? nil : frameTexture
        let flip = mirrored
        lock.unlock()

        let targetSize = CGSize(
            width: drawable.texture.width,
            height: drawable.texture.height
        )
        guard let texture, targetSize.width > 0, targetSize.height > 0 else {
            clear(drawable: drawable, commandBuffer: commandBuffer)
            return
        }

        guard let source = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]) else {
            clear(drawable: drawable, commandBuffer: commandBuffer)
            return
        }

        let composed = compose(source, into: targetSize, mirrored: flip)

        ciContext.render(
            composed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: targetSize),
            colorSpace: colorSpace
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// 等比填满画布（aspect fill），居中并裁掉多余部分。
    private func compose(_ image: CIImage, into target: CGSize, mirrored: Bool) -> CIImage {
        let canvas = CGRect(origin: .zero, size: target)
        let source = image.extent
        guard source.width > 0, source.height > 0 else {
            return CIImage(color: .black).cropped(to: canvas)
        }

        let scale = max(target.width / source.width, target.height / source.height)
        var transformed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if mirrored {
            transformed = transformed.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }

        let dx = (target.width - transformed.extent.width) / 2 - transformed.extent.minX
        let dy = (target.height - transformed.extent.height) / 2 - transformed.extent.minY
        transformed = transformed.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        return transformed.composited(over: CIImage(color: .black).cropped(to: canvas))
    }

    private func clear(drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.055, green: 0.059, blue: 0.067, alpha: 1
        )
        commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
