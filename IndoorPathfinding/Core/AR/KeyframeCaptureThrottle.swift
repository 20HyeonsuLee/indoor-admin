import simd
import Foundation

/// Keyframe 캡처 정책 판정기.
/// - 조건: `(Δt ≥ minInterval) OR (Δposition ≥ minDistance)` 이면서 tracking이 normal.
/// - 백프레셔: pendingCount >= maxPending 이면 드롭 반환.
/// Main thread에서만 사용한다 (ARFrame 도착 시점과 동일 스레드).
///
/// Sprint 65 hotfix (2026-04-30): heatmap dense capture 위해 1Hz/0.3m → 5Hz/0.1m 완화.
/// Sprint 92 (2026-05-09): heatmap 폐기 + RTAB-Map raw mode node 생성도 ~1Hz라
///   원래 정책 1Hz/0.3m로 복원. 매칭률·DB 사이즈·발열 모두 개선.
/// ADR D2/D3: rollover-aggressive mode 추가 — chunk rollover 직후 1s window 동안
///   새 DB가 공간 overlap keyframe을 빠르게 확보하도록 throttle 완화.
final class KeyframeCaptureThrottle {
    let minInterval: TimeInterval
    let minDistance: Float
    let maxPending: Int

    private var lastCaptureTime: Date?
    private var lastCapturePosition: SIMD3<Float>?

    /// rollover-aggressive mode. true일 때 interval/distance 조건을 완화.
    /// ADR D2: rollover 후 1s window 동안 새 DB keyframe ≥ 5 확보가 목표.
    private(set) var isAggressiveMode: Bool = false

    /// aggressive mode에서 사용할 완화된 파라미터.
    private static let aggressiveInterval: TimeInterval = 0.2   // 5 Hz
    private static let aggressiveDistance: Float = 0.05          // 5 cm

    /// pause 상태. true이면 모든 frame을 drop한다.
    /// ADR D2: rollover 시퀀스에서 0.5s drain 대기 동안 SLAMConsumer는 계속 consume하지만
    /// throttle이 pause돼 있으면 pushFrame으로 가지 않는다.
    private(set) var isPaused: Bool = false

    init(
        minInterval: TimeInterval = 1.0,  // 1 Hz (Sprint 92 heatmap 폐기 후 복원)
        minDistance: Float = 0.3,         // 30 cm
        maxPending: Int = 10
    ) {
        self.minInterval = minInterval
        self.minDistance = minDistance
        self.maxPending = maxPending
    }

    enum Decision {
        case capture
        case drop       // 조건 미충족
        case backpressure // 큐 포화
        case paused     // throttle pause 상태
    }

    /// rollover 시퀀스 시작 시 throttle을 pause.
    /// SLAMConsumer.consume()에서 decide()가 .paused를 반환하면 pushFrame을 건너뛴다.
    func pause() {
        isPaused = true
        lastCaptureTime = nil
        lastCapturePosition = nil
    }

    /// rollover 완료 후 throttle 재개.
    /// - Parameter aggressive: true이면 1s 동안 aggressive mode로 재개.
    func resume(aggressive: Bool) {
        isPaused = false
        isAggressiveMode = aggressive
        // aggressive 진입 시 직전 캡처 기록 reset → 첫 frame 즉시 통과
        if aggressive {
            lastCaptureTime = nil
            lastCapturePosition = nil
        }
    }

    /// aggressive mode 해제 (1s overlap window 종료 후 호출).
    func endAggressiveMode() {
        isAggressiveMode = false
    }

    /// sample이 캡처 조건을 충족하는지 판정.
    /// - Parameters:
    ///   - sample: 현재 ARKit 프레임에서 복사된 스냅샷.
    ///   - pendingCount: 저장 큐에 대기 중인 작업 수.
    /// - Returns: 캡처 여부 결정.
    func decide(sample: KeyframeSample, pendingCount: Int) -> Decision {
        guard !isPaused else { return .paused }
        guard sample.trackingStateLabel == "normal" else { return .drop }
        guard pendingCount < maxPending else { return .backpressure }

        let now = sample.capturedAt
        let pos = sample.translation

        let effectiveInterval = isAggressiveMode ? Self.aggressiveInterval : minInterval
        let effectiveDistance = isAggressiveMode ? Self.aggressiveDistance : minDistance

        let timePassed: Bool
        if let last = lastCaptureTime {
            timePassed = now.timeIntervalSince(last) >= effectiveInterval
        } else {
            timePassed = true
        }

        let distancePassed: Bool
        if let last = lastCapturePosition {
            distancePassed = simd_distance(pos, last) >= effectiveDistance
        } else {
            distancePassed = true
        }

        guard timePassed || distancePassed else { return .drop }

        lastCaptureTime = now
        lastCapturePosition = pos
        return .capture
    }

    /// 세션 리셋 시 상태 초기화.
    func reset() {
        lastCaptureTime = nil
        lastCapturePosition = nil
        isPaused = false
        isAggressiveMode = false
    }
}
