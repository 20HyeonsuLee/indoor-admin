import Testing
import Foundation
import simd
import CoreVideo
@testable import IndoorPathfinding

/// ADR D2/D3 — KeyframeCaptureThrottle rollover-aggressive mode 테스트.
@Suite("KeyframeCaptureThrottle Rollover")
struct KeyframeCaptureThrottleRolloverTests {

    func makeSample(
        capturedAt: Date = .now,
        trackingState: String = "normal"
    ) -> KeyframeSample {
        var pixelBuffer: CVPixelBuffer!
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let matrix = matrix_identity_float4x4
        return .forTest(
            pixelBuffer: pixelBuffer,
            transform: matrix,
            capturedAt: capturedAt,
            trackingStateLabel: trackingState
        )
    }

    @Test("pause blocks all frames")
    func pauseBlocksFrames() {
        let throttle = KeyframeCaptureThrottle()
        throttle.pause()
        #expect(throttle.isPaused == true)
        let decision = throttle.decide(sample: makeSample(), pendingCount: 0)
        #expect(decision == .paused)
    }

    @Test("resume(aggressive: false) resumes normal mode")
    func resumeNormal() {
        let throttle = KeyframeCaptureThrottle()
        throttle.pause()
        throttle.resume(aggressive: false)
        #expect(throttle.isPaused == false)
        #expect(throttle.isAggressiveMode == false)
    }

    @Test("resume(aggressive: true) enables aggressive mode")
    func resumeAggressive() {
        let throttle = KeyframeCaptureThrottle()
        throttle.pause()
        throttle.resume(aggressive: true)
        #expect(throttle.isPaused == false)
        #expect(throttle.isAggressiveMode == true)
    }

    @Test("aggressive mode passes frames more frequently than normal")
    func aggressivePassesMoreFrames() {
        let throttle = KeyframeCaptureThrottle(
            minInterval: 1.0,   // normal: 1 Hz
            minDistance: 0.3,
            maxPending: 100
        )

        // normal mode: 0.2s 간격 frame은 drop
        let base = Date()
        let s1 = makeSample(capturedAt: base)
        let s2 = makeSample(capturedAt: base.addingTimeInterval(0.2))

        _ = throttle.decide(sample: s1, pendingCount: 0)  // capture (첫 frame)
        let normalDecision = throttle.decide(sample: s2, pendingCount: 0)
        #expect(normalDecision == .drop)

        // aggressive mode: 0.2s 간격 frame은 통과 (aggressiveInterval = 0.1s)
        throttle.reset()
        throttle.resume(aggressive: true)
        let base2 = Date()
        let a1 = makeSample(capturedAt: base2)
        let a2 = makeSample(capturedAt: base2.addingTimeInterval(0.2))

        _ = throttle.decide(sample: a1, pendingCount: 0)  // capture
        let aggressiveDecision = throttle.decide(sample: a2, pendingCount: 0)
        #expect(aggressiveDecision == .capture)
    }

    @Test("endAggressiveMode reverts to normal")
    func endAggressiveModeReverts() {
        let throttle = KeyframeCaptureThrottle()
        throttle.pause()
        throttle.resume(aggressive: true)
        #expect(throttle.isAggressiveMode == true)
        throttle.endAggressiveMode()
        #expect(throttle.isAggressiveMode == false)
    }

    @Test("reset clears all state including aggressive mode")
    func resetClearsAll() {
        let throttle = KeyframeCaptureThrottle()
        throttle.pause()
        throttle.resume(aggressive: true)
        throttle.reset()
        #expect(throttle.isPaused == false)
        #expect(throttle.isAggressiveMode == false)
    }
}
