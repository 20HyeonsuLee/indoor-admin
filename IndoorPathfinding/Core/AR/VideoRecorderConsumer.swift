import Foundation

/// Sprint 67 — ARKit frame 60Hz 전량을 VideoRecorder + PoseFileWriter 로 흘려보내는 Consumer.
///
/// FrameFanout attach 순서 규약: SLAM → VideoRecorder → Keyframe.
/// SLAM 이 먼저 RTAB-Map raw recording 에 frame 을 push 하고,
/// VideoRecorder 가 그와 독립적으로 mp4 + poses.bin 을 누적한다.
/// Keyframe 은 KeyframeCaptureThrottle (5Hz) 통과분만 RTAB-Map enqueue + sidecar DB.
///
/// 본 Consumer 는 throttle 없음 — 60Hz 전량을 video 에 기록.
/// trackingState != normal 인 frame 은 ARSessionManager 가 이미 걸러내므로
/// 도달하는 sample 은 모두 normal frame 만.
@MainActor
final class VideoRecorderConsumer: FrameConsumer {

    private let videoRecorder: VideoRecorder
    private let poseFileWriter: PoseFileWriter

    init(videoRecorder: VideoRecorder, poseFileWriter: PoseFileWriter) {
        self.videoRecorder = videoRecorder
        self.poseFileWriter = poseFileWriter
    }

    func consume(manager: ARSessionManager, sample: KeyframeSample) {
        let pts = sample.arFrameTimestamp
        videoRecorder.append(pixelBuffer: sample.pixelBuffer, ptsSeconds: pts)
        let ptsNs = Int64(pts * 1_000_000_000)
        poseFileWriter.append(ptsNanoseconds: ptsNs, transform: sample.transform)
    }
}
