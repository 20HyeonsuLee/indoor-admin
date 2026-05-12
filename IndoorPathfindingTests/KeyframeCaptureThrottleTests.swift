import Testing
import Foundation
import CoreVideo
import simd
@testable import IndoorPathfinding

@Suite("KeyframeCaptureThrottle")
struct KeyframeCaptureThrottleTests {

    // MARK: - Helpers

    func makeSample(
        t: SIMD3<Float> = .zero,
        capturedAt: Date = Date(),
        trackingState: String = "normal"
    ) -> KeyframeSample {
        let width = 4, height = 4
        var pixelBuffer: CVPixelBuffer!
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return .forTest(
            pixelBuffer: pixelBuffer,
            transform: matrix,
            capturedAt: capturedAt,
            trackingStateLabel: trackingState
        )
    }

    // MARK: - Tests

    @Test("첫 번째 캡처는 무조건 통과")
    func firstCapturePasses() {
        let throttle = KeyframeCaptureThrottle()
        let sample = makeSample()
        #expect(throttle.decide(sample: sample, pendingCount: 0) == .capture)
    }

    @Test("시간 조건 (0.2s 미만) — 드롭 (Sprint 65: 5Hz)")
    func dropWhenTimeTooShort() {
        let throttle = KeyframeCaptureThrottle()
        let now = Date()
        _ = throttle.decide(sample: makeSample(capturedAt: now), pendingCount: 0)
        let next = makeSample(t: .zero, capturedAt: now.addingTimeInterval(0.05))
        #expect(throttle.decide(sample: next, pendingCount: 0) == .drop)
    }

    @Test("시간 조건 충족 (1.0s 이상) — 캡처")
    func captureWhenTimeElapsed() {
        let throttle = KeyframeCaptureThrottle()
        let now = Date()
        _ = throttle.decide(sample: makeSample(capturedAt: now), pendingCount: 0)
        let next = makeSample(t: .zero, capturedAt: now.addingTimeInterval(1.1))
        #expect(throttle.decide(sample: next, pendingCount: 0) == .capture)
    }

    @Test("거리 조건 충족 (0.3m 이상) — 캡처")
    func captureWhenDistanceMet() {
        let throttle = KeyframeCaptureThrottle()
        let now = Date()
        _ = throttle.decide(sample: makeSample(t: .zero, capturedAt: now), pendingCount: 0)
        let next = makeSample(t: SIMD3<Float>(0.4, 0, 0), capturedAt: now.addingTimeInterval(0.1))
        #expect(throttle.decide(sample: next, pendingCount: 0) == .capture)
    }

    @Test("백프레셔: 큐 포화 시 드롭 (Sprint 65: maxPending=10)")
    func backpressureWhenQueueFull() {
        let throttle = KeyframeCaptureThrottle()
        let sample = makeSample()
        // 첫 캡처는 통과해서 lastCaptureTime 설정
        _ = throttle.decide(sample: sample, pendingCount: 0)
        let next = makeSample(capturedAt: sample.capturedAt.addingTimeInterval(2.0))
        #expect(throttle.decide(sample: next, pendingCount: 10) == .backpressure)
    }

    @Test("tracking이 normal이 아니면 드롭")
    func dropWhenTrackingAbnormal() {
        let throttle = KeyframeCaptureThrottle()
        let sample = makeSample(trackingState: "limited.initializing")
        #expect(throttle.decide(sample: sample, pendingCount: 0) == .drop)
    }

    @Test("reset 후 첫 캡처 다시 통과")
    func captureAfterReset() {
        let throttle = KeyframeCaptureThrottle()
        let now = Date()
        _ = throttle.decide(sample: makeSample(capturedAt: now), pendingCount: 0)
        throttle.reset()
        let next = makeSample(t: .zero, capturedAt: now.addingTimeInterval(0.1))
        #expect(throttle.decide(sample: next, pendingCount: 0) == .capture)
    }
}
