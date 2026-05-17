import Accelerate
import CoreVideo
import Foundation
import OSLog

/// Sprint 95: 모션블러 frame reject용 sharpness gate.
///
/// 알고리즘: Variance of Laplacian (Pech-Pacheco 2000).
///   - 320×240 으로 downsample → Laplacian 3x3 convolution → variance.
///   - variance 가 threshold 미만이면 blur 로 판정해 reject.
///
/// 성능 목표: 480×360 frame당 < 1ms (vImage 사용).
/// Threshold default 80 — calibration evidence 기반 조정 가능. 200lux 학교 복도
/// 정상 frame 평균 variance ≈ 200-400, 빠른걸음 블러 frame 평균 ≈ 40-70.
final class BlurDetector {

    private static let logger = Logger(
        subsystem: "ac.koreatech.indoorpathfinding",
        category: "blur"
    )

    /// reject threshold. variance 가 이 값 미만이면 blur 판정.
    let threshold: Double

    /// downsample 목표 resolution. Sprint 96: 발열 완화를 위해 320x240으로 낮춤.
    private static let targetWidth = 320
    private static let targetHeight = 240

    /// 통계 (디버그용). reject 비율 모니터링.
    private(set) var totalEvaluated: Int = 0
    private(set) var totalRejected: Int = 0
    private(set) var lastVariance: Double = 0

    init(threshold: Double = 80.0) {
        self.threshold = threshold
    }

    /// blur 면 true (reject 권장). pixelBuffer 는 ARKit YUV 420f 가정.
    /// Y plane 만 사용 (luminance) — RGB 변환 비용 회피.
    func isBlurred(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let variance = computeLaplacianVariance(pixelBuffer)
        lastVariance = variance
        totalEvaluated += 1

        let blurred = variance < threshold
        if blurred {
            totalRejected += 1
        }

        // 60 frames 마다 1회 통계 로그
        if totalEvaluated % 60 == 1 {
            let rejectRate = Double(totalRejected) / Double(totalEvaluated) * 100
            Self.logger.info(
                "evaluated=\(self.totalEvaluated) rejected=\(self.totalRejected) (\(rejectRate, format: .fixed(precision: 1))%) lastVar=\(variance, format: .fixed(precision: 1))"
            )
        }
        return blurred
    }

    /// Y plane 에서 320x240 downsample → Laplacian convolution → variance 반환.
    private func computeLaplacianVariance(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount >= 1,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return Double.greatestFiniteMagnitude  // 못 읽으면 reject 안 함
        }

        let srcWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let srcRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        var srcBuffer = vImage_Buffer(
            data: yBase,
            height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth),
            rowBytes: srcRowBytes
        )

        // 1) downsample to ~480x360
        let dstW = Self.targetWidth
        let dstH = Self.targetHeight
        let dstRowBytes = ((dstW + 15) / 16) * 16  // 16-byte align
        let dstBytes = dstRowBytes * dstH
        guard let dstData = malloc(dstBytes) else { return Double.greatestFiniteMagnitude }
        defer { free(dstData) }

        var dstBuffer = vImage_Buffer(
            data: dstData,
            height: vImagePixelCount(dstH),
            width: vImagePixelCount(dstW),
            rowBytes: dstRowBytes
        )

        let scaleResult = vImageScale_Planar8(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
        guard scaleResult == kvImageNoError else { return Double.greatestFiniteMagnitude }

        // 2) Laplacian 3x3 convolution: [[0,1,0],[1,-4,1],[0,1,0]]
        let lapRowBytes = dstRowBytes
        let lapBytes = lapRowBytes * dstH
        guard let lapData = malloc(lapBytes) else { return Double.greatestFiniteMagnitude }
        defer { free(lapData) }

        var lapBuffer = vImage_Buffer(
            data: lapData,
            height: vImagePixelCount(dstH),
            width: vImagePixelCount(dstW),
            rowBytes: lapRowBytes
        )

        // vImageConvolve_Planar8 은 Int16 kernel + divisor 형식.
        // Laplacian: kernel sum=0, divisor=1.
        let kernel: [Int16] = [
            0, 1, 0,
            1, -4, 1,
            0, 1, 0,
        ]
        let convResult = kernel.withUnsafeBufferPointer { kPtr -> vImage_Error in
            vImageConvolve_Planar8(
                &dstBuffer, &lapBuffer, nil, 0, 0,
                kPtr.baseAddress!, 3, 3,
                1,                                   // divisor
                128,                                 // backgroundColor (signed → unsigned offset)
                vImage_Flags(kvImageEdgeExtend)
            )
        }
        guard convResult == kvImageNoError else { return Double.greatestFiniteMagnitude }

        // 3) variance 계산 (vDSP).
        // lapData 는 UInt8. 128 offset 빼고 signed 해석.
        let pixelCount = dstW * dstH
        var floatBuffer = [Float](repeating: 0, count: pixelCount)
        let lapPtr = lapData.bindMemory(to: UInt8.self, capacity: lapBytes)

        // row-by-row 복사 (rowBytes != width 일 수 있음)
        for row in 0..<dstH {
            let rowStart = row * lapRowBytes
            for col in 0..<dstW {
                let raw = Int(lapPtr[rowStart + col]) - 128
                floatBuffer[row * dstW + col] = Float(raw)
            }
        }

        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_normalize(
            floatBuffer, 1,
            nil, 0,
            &mean, &stdDev,
            vDSP_Length(pixelCount)
        )
        // vDSP_normalize 의 stdDev 는 sample std (분모 N). variance = stdDev^2.
        return Double(stdDev * stdDev)
    }
}
