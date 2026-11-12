import AVFoundation
import Foundation

/// 拍照委托。拆成独立对象，避免让 CameraModel 承担非主线程的协议回调。
/// 调用方需自行持有实例直到回调触发。
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(LensError.captureFailed("照片数据为空")))
            return
        }
        completion(.success(data))
    }
}

/// 录像委托。
final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {

    var onStart: ((URL) -> Void)?
    var onFinish: ((URL, Error?) -> Void)?

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        onStart?(fileURL)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        onFinish?(outputFileURL, error)
    }
}
