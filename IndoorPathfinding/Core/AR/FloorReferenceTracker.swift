import ARKit
import os.log

// MARK: - FloorReferenceTracker

/// ARSession에서 바닥 평면 y 좌표를 결정하고 lock한다.
///
/// ## 결정 전략 (우선순위 순)
///
/// 1. **floorClassification** — ARPlaneAnchor.alignment == .horizontal &&
///    classification == .floor (LiDAR 단말, 1.5초 이내)
/// 2. **firstHorizontalPlane** — 첫 ARPlaneAnchor.alignment == .horizontal이고
///    anchor.y < cameraY - 0.5 (책상 제외 조건)
/// 3. **heuristic** — 1.5초 timeout 후 첫 corridor mark 시점에
///    cameraY - 1.5m로 lock (사람 키 가정)
///
/// lock 이후에는 session 동안 변경하지 않는다.
@MainActor
final class FloorReferenceTracker {

    // MARK: - Types

    enum Source: String {
        case floorClassification  = "horizontal_anchor_floor"
        case firstHorizontalPlane = "horizontal_anchor_first"
        case heuristic            = "camera_minus_1.5m"
    }

    // MARK: - Public State

    private(set) var floorY: Float?
    private(set) var source: Source?

    var isLocked: Bool { floorY != nil }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.indoorpathfinding", category: "ARPlacement")
    private let timeoutSec: TimeInterval
    private var sessionStartedAt: Date = .distantPast
    private var firstHorizontalCandidateY: Float?

    // MARK: - Init

    init(timeoutSec: TimeInterval = 1.5) {
        self.timeoutSec = timeoutSec
    }

    // MARK: - Session Lifecycle

    /// ARSession 시작 시 호출. 타임아웃 카운트다운 시작.
    func sessionStarted() {
        sessionStartedAt = Date()
        floorY = nil
        source = nil
        firstHorizontalCandidateY = nil
    }

    // MARK: - Anchor Events

    /// ARSession anchor add/update 이벤트를 라우팅 받는다.
    /// - Parameters:
    ///   - anchor: 추가/업데이트된 ARAnchor
    ///   - cameraY: 이벤트 시점의 카메라 y (world)
    func handleAnchorAdded(_ anchor: ARAnchor, cameraY: Float) {
        guard !isLocked else { return }
        guard let plane = anchor as? ARPlaneAnchor,
              plane.alignment == .horizontal else { return }

        let anchorY = anchor.transform.columns.3.y

        // Strategy 1: classification == .floor (LiDAR)
        if plane.classification == .floor {
            lock(y: anchorY, source: .floorClassification, anchorId: anchor.identifier.uuidString)
            return
        }

        // Strategy 2: 첫 horizontal + anchor.y < cameraY - 0.5 (책상 아님)
        if firstHorizontalCandidateY == nil, anchorY < cameraY - 0.5 {
            firstHorizontalCandidateY = anchorY

            // timeout 지났으면 즉시 lock
            if isTimedOut {
                lock(y: anchorY, source: .firstHorizontalPlane, anchorId: anchor.identifier.uuidString)
            } else {
                // timeout 1.5초 후 자동 lock 예약
                let capturedY = anchorY
                let capturedId = anchor.identifier.uuidString
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.timeoutSec * 1_000_000_000))
                    await MainActor.run { [weak self] in
                        guard let self, !self.isLocked else { return }
                        self.lock(y: capturedY, source: .firstHorizontalPlane, anchorId: capturedId)
                    }
                }
            }
        }
    }

    // MARK: - Heuristic Lock (Strategy 3)

    /// corridor mark 시점에 floorY가 없으면 즉시 heuristic으로 lock.
    /// - Parameter cameraY: 현재 카메라 y 좌표 (world)
    /// - Returns: lock된 floorY
    @discardableResult
    func handleFirstCorridorMark(cameraY: Float) -> Float {
        if let existing = floorY { return existing }

        let heuristicY = cameraY - 1.5
        lock(y: heuristicY, source: .heuristic, anchorId: nil)
        return heuristicY
    }

    // MARK: - Private

    private var isTimedOut: Bool {
        Date().timeIntervalSince(sessionStartedAt) >= timeoutSec
    }

    private func lock(y: Float, source: Source, anchorId: String?) {
        guard !isLocked else { return }
        floorY = y
        self.source = source
        logger.debug(
            "FLOOR_LOCK floorRefSource=\(source.rawValue, privacy: .public) floorY=\(y, format: .fixed(precision: 3)) anchorId=\(anchorId ?? "nil", privacy: .public)"
        )
    }
}
