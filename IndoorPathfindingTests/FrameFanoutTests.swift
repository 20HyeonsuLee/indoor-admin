import Testing
import Foundation
import simd
import CoreVideo
@testable import IndoorPathfinding

/// FrameFanout 유닛 테스트.
///
/// Sprint 4 재구성된 다중 Consumer fan-out 검증:
/// - attach된 모든 Consumer에 전량 전달.
/// - detach 후 해당 Consumer에 미전달.
/// - 주기 제한은 Consumer 내부 — FrameFanout 자체는 throttle 없음.
@MainActor
@Suite("FrameFanout")
struct FrameFanoutTests {

    // MARK: - Helpers

    private func makeSample(
        translation: SIMD3<Float> = .zero,
        capturedAt: Date = Date(),
        state: String = "normal"
    ) -> KeyframeSample {
        var buf: CVPixelBuffer!
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buf)
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return .forTest(pixelBuffer: buf, transform: m, capturedAt: capturedAt, trackingStateLabel: state)
    }

    // MARK: - 모든 Consumer에 전달

    @Test("attach된 Consumer 전체에 전달됨")
    func allConsumersReceiveFrame() {
        let fanout = FrameFanout()
        let c1 = SpyFrameConsumer()
        let c2 = SpyFrameConsumer()
        fanout.attach(c1)
        fanout.attach(c2)
        let fake = FakeARSessionManager()
        fanout.sessionManager(fake, didCapture: makeSample())

        #expect(c1.consumeCallCount == 1)
        #expect(c2.consumeCallCount == 1)
    }

    @Test("100 frame push → 각 Consumer consume 100회")
    func allFramesReachAllConsumers() {
        let fanout = FrameFanout()
        let c1 = SpyFrameConsumer()
        let c2 = SpyFrameConsumer()
        let c3 = SpyFrameConsumer()
        fanout.attach(c1)
        fanout.attach(c2)
        fanout.attach(c3)
        let fake = FakeARSessionManager()
        let now = Date()
        for i in 0..<100 {
            fanout.sessionManager(fake, didCapture: makeSample(capturedAt: now.addingTimeInterval(Double(i) * 0.016)))
        }
        #expect(c1.consumeCallCount == 100)
        #expect(c2.consumeCallCount == 100)
        #expect(c3.consumeCallCount == 100)
    }

    // MARK: - detach

    @Test("detach 후 해당 Consumer 미호출")
    func detachRemovesConsumer() {
        let fanout = FrameFanout()
        let c1 = SpyFrameConsumer()
        let c2 = SpyFrameConsumer()
        fanout.attach(c1)
        fanout.attach(c2)
        fanout.detach(c1)
        let fake = FakeARSessionManager()
        fanout.sessionManager(fake, didCapture: makeSample())

        #expect(c1.consumeCallCount == 0)
        #expect(c2.consumeCallCount == 1)
    }

    // MARK: - attach 순서

    @Test("consume 호출 순서: 첫 번째 attach가 먼저")
    func consumeOrderMatchesAttachOrder() {
        let fanout = FrameFanout()
        var order: [Int] = []
        let c1 = OrderedSpyFrameConsumer(id: 1, order: &order)
        let c2 = OrderedSpyFrameConsumer(id: 2, order: &order)
        fanout.attach(c1)
        fanout.attach(c2)
        let fake = FakeARSessionManager()
        fanout.sessionManager(fake, didCapture: makeSample())

        #expect(order == [1, 2])
    }

    // MARK: - tracking 이벤트

    @Test("tracking 이벤트는 trackingDelegate로 전달됨")
    func trackingChangeForwarded() {
        let spy = SpyARSessionManagerDelegate()
        let fanout = FrameFanout(trackingDelegate: spy)
        let fake = FakeARSessionManager()

        fanout.sessionManager(fake, trackingStateDidChange: "limited.excessiveMotion")

        #expect(spy.lastTrackingLabel == "limited.excessiveMotion")
    }

    // MARK: - reset

    @Test("reset 후 Consumer 목록 비워짐")
    func resetClearsConsumers() {
        let fanout = FrameFanout()
        let c1 = SpyFrameConsumer()
        fanout.attach(c1)
        fanout.reset()
        let fake = FakeARSessionManager()
        fanout.sessionManager(fake, didCapture: makeSample())

        #expect(c1.consumeCallCount == 0)
    }

    // MARK: - SLAMConsumer 통합

    @Test("SLAMConsumer attach → 모든 frame pushFrame 호출됨")
    func slamConsumerReceivesAllFrames() {
        let fanout = FrameFanout()
        let sink = SpyRTABMapSLAMSink()
        let slamConsumer = SLAMConsumer(sink: sink)
        fanout.attach(slamConsumer)
        let fake = FakeARSessionManager()
        let now = Date()
        for i in 0..<5 {
            fanout.sessionManager(fake, didCapture: makeSample(capturedAt: now.addingTimeInterval(Double(i))))
        }
        #expect(sink.pushCount == 5)
    }

    // MARK: - KeyframeConsumer 통합

    @Test("KeyframeConsumer throttle 통과분만 downstream 전달")
    func keyframeConsumerThrottlesDownstream() {
        let fanout = FrameFanout()
        let spy = SpyARSessionManagerDelegate()
        // minInterval=100s: 첫 번째만 통과
        // Sprint 35 Task 1 v3: slamConsumer → rtabmapBridge (nil 가능)
        let keyframeConsumer = KeyframeConsumer(
            throttle: KeyframeCaptureThrottle(minInterval: 100, minDistance: 100),
            downstream: spy,
            rtabmapBridge: nil
        )
        fanout.attach(keyframeConsumer)
        let fake = FakeARSessionManager()
        let now = Date()
        fanout.sessionManager(fake, didCapture: makeSample(capturedAt: now))
        fanout.sessionManager(fake, didCapture: makeSample(capturedAt: now.addingTimeInterval(0.1)))

        #expect(spy.capturedSamples.count == 1)
    }

    // MARK: - onNodeIDAssigned 콜백 (Sprint 35 Task 1 v3: deprecated path — enqueue 검증으로 대체)

    @Test("KeyframeConsumer throttle 통과 시 rtabmapBridge.enqueue 호출됨")
    func keyframeConsumerEnqueuesOnThrottlePass() {
        let fanout = FrameFanout()
        let spy = SpyARSessionManagerDelegate()
        let spyBridge = SpyRTABMapBridgeEnqueue()
        let keyframeConsumer = KeyframeConsumer(
            throttle: KeyframeCaptureThrottle(minInterval: 0, minDistance: 0),
            downstream: spy,
            rtabmapBridge: spyBridge
        )
        fanout.attach(keyframeConsumer)
        let fake = FakeARSessionManager()

        fanout.sessionManager(fake, didCapture: makeSample())
        fanout.sessionManager(fake, didCapture: makeSample())

        // 두 프레임 모두 throttle 통과 → enqueue 2회
        #expect(spyBridge.enqueueCallCount == 2)
    }
}

// MARK: - Spy Helpers

@MainActor
final class SpyFrameConsumer: FrameConsumer {
    var consumeCallCount: Int = 0

    func consume(manager: ARSessionManager, sample: KeyframeSample) {
        consumeCallCount += 1
    }
}

/// Sprint 35 Task 1 v3: RTABMapBridgeEnqueueProtocol spy — enqueue 호출 횟수 및 인자 검증용.
@MainActor
final class SpyRTABMapBridgeEnqueue: RTABMapBridgeEnqueueProtocol {
    var enqueueCallCount: Int = 0
    var enqueuedSeqs: [Int] = []
    var enqueuedStamps: [TimeInterval] = []

    func enqueuePendingKeyframe(seq: Int, capturedAt: TimeInterval) {
        enqueueCallCount += 1
        enqueuedSeqs.append(seq)
        enqueuedStamps.append(capturedAt)
    }
}

@MainActor
final class OrderedSpyFrameConsumer: FrameConsumer {
    let id: Int
    var orderRef: UnsafeMutablePointer<[Int]>

    init(id: Int, order: inout [Int]) {
        self.id = id
        self.orderRef = withUnsafeMutablePointer(to: &order) { $0 }
    }

    func consume(manager: ARSessionManager, sample: KeyframeSample) {
        orderRef.pointee.append(id)
    }
}

@MainActor
final class SpyARSessionManagerDelegate: ARSessionManagerDelegate {
    var capturedSamples: [KeyframeSample] = []
    var lastTrackingLabel: String?
    var lastError: Error?

    func sessionManager(_ manager: ARSessionManager, didCapture sample: KeyframeSample) {
        capturedSamples.append(sample)
    }
    func sessionManager(_ manager: ARSessionManager, trackingStateDidChange label: String) {
        lastTrackingLabel = label
    }
    func sessionManagerDidFail(_ manager: ARSessionManager, error: Error) {
        lastError = error
    }
}

@MainActor
final class SpyRTABMapSLAMSink: RTABMapSLAMSink {
    var pushCount: Int = 0
    var startCalled = false
    var pauseCalled = false
    var finalizeCalled = false
    var stats: RTABMapStats = RTABMapStats()

    func start(scanURL: URL) throws { startCalled = true }
    func pushFrame(_ sample: KeyframeSample) -> RTABMapNodeID? {
        pushCount += 1
        return nil
    }
    func pause() { pauseCalled = true }
    func finalize(scanURL: URL) throws -> (dbURL: URL, nodeStamps: [(nodeId: Int, stamp: Double)]) {
        finalizeCalled = true
        return (dbURL: scanURL.appendingPathComponent("rtabmap.db"), nodeStamps: [])
    }
}
