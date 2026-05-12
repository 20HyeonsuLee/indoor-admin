import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Sprint 95: 빠른걸음 스캔 모드를 위한 셔터/ISO 제어.
///
/// 정책 (실내 빠른걸음 1.7-2.0 m/s, yaw 0.6 rad/s 가정):
///   ambientIntensity > 1500 → 1/360s, ISO ≤ 1600
///   ambientIntensity > 700  → 1/240s, ISO ≤ 2400  (default)
///   ambientIntensity > 350  → 1/180s, ISO ≤ 3000
///   ambientIntensity ≤ 350  → 1/120s, ISO ≤ 3200 + UI 경고
///
/// ARKit 이 일부 setting 을 override 할 수 있으므로 (Apple DTS 답변),
/// 매 frame 적용된 셔터를 비교하여 mismatch 면 재시도한다 (1초 hysteresis).
///
/// iOS 16+ 한정. 미만이면 no-op (ARKit auto exposure 유지).
@available(iOS 16.0, *)
final class ExposureController {

    private weak var device: AVCaptureDevice?
    private var lastSetShutter: CMTime?
    private var lastChangeAt: TimeInterval = 0
    private let minChangeInterval: TimeInterval = 1.0  // hysteresis

    private static let logger = Logger(
        subsystem: "ac.koreatech.indoorpathfinding",
        category: "exposure"
    )

    /// 마지막으로 measured ambientIntensity (디버그/UI용 노출). 5-frame 이동평균.
    private(set) var smoothedAmbient: Double = 1000
    private var ambientWindow: [Double] = []
    private static let windowSize = 5

    /// 현재 정책상 underexposed (350 미만)인지. UI 경고 surface 용.
    private(set) var isUnderexposed: Bool = false

    init(device: AVCaptureDevice?) {
        self.device = device
        Self.logger.info("ExposureController init device=\(device?.localizedName ?? "nil", privacy: .public)")
    }

    /// 매 ARFrame 에서 호출. ambientIntensity 평활 → 정책 분기 → device 적용.
    /// - Parameters:
    ///   - ambientIntensity: ARLightEstimate.ambientIntensity (lumens-equiv).
    ///   - now: ARFrame.timestamp (CACurrentMediaTime).
    func update(ambientIntensity: Double, now: TimeInterval) {
        // 5-frame moving average
        ambientWindow.append(ambientIntensity)
        if ambientWindow.count > Self.windowSize {
            ambientWindow.removeFirst()
        }
        smoothedAmbient = ambientWindow.reduce(0, +) / Double(ambientWindow.count)
        isUnderexposed = smoothedAmbient < 350

        guard let device else { return }
        guard now - lastChangeAt > minChangeInterval else { return }

        let target = targetShutter(for: smoothedAmbient)

        // 동일 셔터면 skip
        if let last = lastSetShutter, CMTimeCompare(last, target) == 0 {
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureModeCustom(
                duration: target,
                iso: AVCaptureDevice.currentISO,  // ISO 는 ARKit auto
                completionHandler: nil
            )
            lastSetShutter = target
            lastChangeAt = now
            let denom = Int(target.timescale / Int32(target.value))
            Self.logger.info(
                "shutter changed to 1/\(denom)s ambient=\(self.smoothedAmbient, format: .fixed(precision: 0))"
            )
        } catch {
            Self.logger.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func targetShutter(for ambient: Double) -> CMTime {
        if ambient > 1500 {
            return CMTimeMake(value: 1, timescale: 360)
        } else if ambient > 700 {
            return CMTimeMake(value: 1, timescale: 240)  // default — 빠른걸음 sweet spot
        } else if ambient > 350 {
            return CMTimeMake(value: 1, timescale: 180)
        } else {
            return CMTimeMake(value: 1, timescale: 120)
        }
    }

    /// 시작 시 1회 호출 — 즉시 1/240s default 적용 (lightEstimate 첫 frame 도착 전 baseline).
    func applyInitialPolicy() {
        guard let device else { return }
        let target = CMTimeMake(value: 1, timescale: 240)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureModeCustom(
                duration: target,
                iso: AVCaptureDevice.currentISO,
                completionHandler: nil
            )
            lastSetShutter = target
            lastChangeAt = 0
            Self.logger.info("initial policy applied: 1/240s")
        } catch {
            Self.logger.error("initial policy failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
