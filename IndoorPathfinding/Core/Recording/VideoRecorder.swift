import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Sprint 67 — ARKit pixelBuffer 를 HEVC mp4 로 누적하는 writer.
///
/// 설계:
/// - AVAssetWriter + AVAssetWriterInput + AVAssetWriterInputPixelBufferAdaptor.
/// - Codec: HEVC (Apple ASIC hardware encoder, iOS 11+ 자유 라이센스).
/// - PTS source-of-truth: ARFrame.timestamp (CACurrentMediaTime monotonic).
///   timescale = 1_000_000_000 (nanosecond). PoseFileWriter 와 정확히 일치.
/// - bitrate: 5 Mbps (Sprint 67 plan Q3 결정). 1080p 60fps 기준 깨끗.
/// - thread: append 는 caller thread (ARSessionDelegate, MainActor).
///   AVAssetWriter input.expectsMediaDataInRealTime=true 로 backpressure 명시.
///
/// `cancel()` 은 file 삭제. `finish()` 는 무손실 close (success callback).
final class VideoRecorder {

    enum RecorderError: Error {
        case sessionAlreadyStarted
        case sessionNotStarted
        case writerFailed(Error?)
        case adaptorAppendFailed
    }

    /// 1080p 60fps + HEVC + 5 Mbps target.
    struct Config {
        let width: Int
        let height: Int
        let bitrate: Int
        let codec: AVVideoCodecType

        static let defaultHevc1080p5Mbps = Config(
            width: 1920, height: 1080,
            bitrate: 5_000_000,
            codec: .hevc
        )
    }

    static let videoFileName = "scan.mp4"

    private let url: URL
    private let config: Config
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted: Bool = false
    private(set) var appendedFrameCount: Int = 0
    private(set) var droppedFrameCount: Int = 0

    init(url: URL, config: Config = .defaultHevc1080p5Mbps) throws {
        self.url = url
        self.config = config
        try? FileManager.default.removeItem(at: url)
        try setupWriter()
    }

    private func setupWriter() throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.bitrate,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalKey: 60,                  // 1 keyframe / sec
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: config.codec,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: compression
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        // ARKit native portrait 1920x1440 (4:3). HEVC 1920x1080 으로 vertical center-crop 자동.
        input.transform = .identity

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                kCVPixelBufferWidthKey as String: config.width,
                kCVPixelBufferHeightKey as String: config.height
            ]
        )

        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed(nil)
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error)
        }

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    /// 첫 frame 도착 시 호출 (PTS 기준점 설정).
    /// 이후 cmTime = first frame pts ~ 현재 pts (양수 monotonic).
    private func startSessionIfNeeded(at cmTime: CMTime) {
        guard !sessionStarted, let writer else { return }
        writer.startSession(atSourceTime: cmTime)
        sessionStarted = true
    }

    /// caller: VideoRecorderConsumer (MainActor).
    /// pixelBuffer: ARFrame.capturedImage 의 deepCopy.
    /// ptsSeconds: ARFrame.timestamp.
    func append(pixelBuffer: CVPixelBuffer, ptsSeconds: TimeInterval) {
        guard let input, let adaptor else { return }
        guard input.isReadyForMoreMediaData else {
            droppedFrameCount += 1
            return
        }

        let cmTime = CMTimeMakeWithSeconds(
            ptsSeconds,
            preferredTimescale: 1_000_000_000
        )
        startSessionIfNeeded(at: cmTime)

        if adaptor.append(pixelBuffer, withPresentationTime: cmTime) {
            appendedFrameCount += 1
        } else {
            droppedFrameCount += 1
            NSLog("[VideoRecorder] append failed at pts=%.6f (writer.error=%@)",
                  ptsSeconds, String(describing: writer?.error))
        }
    }

    /// 동기 close. caller: ScanStore.finalize().
    /// completion 은 background. 호출자가 await Task 로 감쌀 것.
    func finish() async throws {
        guard let writer, let input else {
            throw RecorderError.sessionNotStarted
        }
        guard sessionStarted else {
            // frame 한 장도 없는 상태에서 finalize 호출. 빈 파일 정리.
            input.markAsFinished()
            try? FileManager.default.removeItem(at: url)
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            return
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error {
            throw RecorderError.writerFailed(err)
        }
        self.writer = nil
        self.input = nil
        self.adaptor = nil
    }

    func cancel() {
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: url)
        self.writer = nil
        self.input = nil
        self.adaptor = nil
    }
}
