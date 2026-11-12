import CoreImage
import CoreVideo
import Foundation
import Vision

/// 人像分割与背景替换。
///
/// 全部方法都在同一条处理队列上串行调用 —— `VNGeneratePersonSegmentationRequest`
/// 实例不可并发复用，串行既能保证安全，也天然给处理限了速。
final class PersonSegmenter {

    private let ciContext: CIContext
    private let request: VNGeneratePersonSegmentationRequest

    init(ciContext: CIContext) {
        self.ciContext = ciContext

        let request = VNGeneratePersonSegmentationRequest()
        // balanced 在 M 系列上约 5–8 ms/帧，质量足够；fast 边缘会毛糙。
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.request = request
    }

    // MARK: - 视频帧

    /// 对采集到的一帧做分割并替换背景。失败时原样返回，绝不中断预览。
    func composite(pixelBuffer: CVPixelBuffer, config: VirtualBackgroundConfig) -> CIImage {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        return composite(source: source, config: config, mask: {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            return self.runSegmentation(handler)
        })
    }

    // MARK: - 静态图（拍照结果）

    func composite(image: CIImage, config: VirtualBackgroundConfig) -> CIImage {
        composite(source: image, config: config, mask: {
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            return self.runSegmentation(handler)
        })
    }

    // MARK: - 内部

    private func composite(
        source: CIImage,
        config: VirtualBackgroundConfig,
        mask makeMask: () -> CIImage?
    ) -> CIImage {
        guard config.isActive else { return source }

        guard let rawMask = makeMask() else {
            NSLog("[Lens] 人像分割未返回结果，回退到原始画面")
            return source
        }

        let mask = fit(rawMask, to: source.extent)

        guard let background = makeBackground(for: config, source: source) else {
            return source
        }

        return source
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask
            ])
            .cropped(to: source.extent)
    }

    private func runSegmentation(_ handler: VNImageRequestHandler) -> CIImage? {
        do {
            try handler.perform([request])
        } catch {
            NSLog("[Lens] 人像分割失败: \(error.localizedDescription)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        return CIImage(cvPixelBuffer: observation.pixelBuffer)
    }

    /// Vision 输出的蒙版分辨率通常远小于原帧，需要拉伸对齐。
    private func fit(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let source = mask.extent
        guard source.width > 0, source.height > 0,
              extent.width > 0, extent.height > 0 else { return mask }

        let scaleX = extent.width / source.width
        let scaleY = extent.height / source.height

        return mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: extent.minX - source.minX * scaleX,
                y: extent.minY - source.minY * scaleY
            ))
    }

    private func makeBackground(for config: VirtualBackgroundConfig, source: CIImage) -> CIImage? {
        switch config.kind {
        case .off:
            return nil

        case .blur:
            // 全分辨率跑大半径高斯模糊太贵（1536×1024、半径 30 要 800 ms 以上）。
            // 先降采样 4 倍再模糊，代价降一个数量级，观感上分辨不出差别。
            let scale: CGFloat = 0.25
            return source
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: config.blurRadius * scale
                ])
                .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                .cropped(to: source.extent)

        case .solid(let preset):
            let c = preset.components
            return CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue))
                .cropped(to: source.extent)

        case .custom:
            guard let cgImage = config.customImage else { return nil }
            return fill(CIImage(cgImage: cgImage), into: source.extent)
        }
    }

    /// 等比填满目标区域（aspect fill），超出的部分裁掉。
    private func fill(_ image: CIImage, into target: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }

        let scale = max(target.width / source.width, target.height / source.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = target.midX - scaled.extent.midX
        let dy = target.midY - scaled.extent.midY

        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: target)
    }
}
