import Foundation
import simd
import CoreVideo
import ARKit
@testable import IndoorPathfinding

/// 테스트용 ARSessionManager stub. start/pause 상태만 추적.
/// ARSessionManagerDelegate가 @MainActor이므로 delegate 호출은 Main thread에서 수행.
@MainActor
final class FakeARSessionManager: ARSessionManager {
    weak var delegate: ARSessionManagerDelegate?
    var isStarted = false

    nonisolated func start() { Task { @MainActor in self.isStarted = true } }
    nonisolated func pause() { Task { @MainActor in self.isStarted = false } }

    /// 테스트에서 직접 호출해 sample 주입. @MainActor 컨텍스트에서 호출해야 한다.
    func injectSample(
        translation: SIMD3<Float> = .zero,
        capturedAt: Date = Date(),
        trackingState: String = "normal"
    ) {
        let width = 4, height = 4
        var pixelBuffer: CVPixelBuffer!
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        let sample = KeyframeSample.forTest(
            pixelBuffer: pixelBuffer,
            transform: matrix,
            capturedAt: capturedAt,
            trackingStateLabel: trackingState
        )
        delegate?.sessionManager(self, didCapture: sample)
    }
}
