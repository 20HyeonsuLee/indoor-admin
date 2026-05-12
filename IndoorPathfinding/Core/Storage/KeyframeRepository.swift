import GRDB
import simd
import Foundation

// MARK: - Protocol

protocol KeyframeRepositoryProtocol {
    /// DB insert. Sprint 49 (Codex BLOCKER 5): JPEG 인코딩/파일 쓰기 제거.
    /// keyframe image source-of-truth 는 RTABMap.db Data 테이블이다.
    /// `keyframe_meta.image_path` 컬럼은 빈 문자열로 유지 (schema backward compat).
    func save(sample: KeyframeSample, seq: Int, scanId: String) throws
    func save(
        transform: simd_float4x4,
        capturedAt: Date,
        trackingStateLabel: String,
        seq: Int,
        scanId: String
    ) throws
}

// MARK: - 구현

/// DB insert 만 담당. Sprint 49 (Codex BLOCKER 5): keyframes/{seq}.jpg 별도 저장 제거.
/// RTABMap.db Data 테이블에 RTABMap accept 한 frame 의 image bytes 가 보관된다.
/// reject frame 의 image 는 영구 손실 (R-1 trade-off, manifest.json 에 명시).
final class KeyframeRepository: KeyframeRepositoryProtocol, @unchecked Sendable {
    private let fileStore: ScanFileStore
    private let db: ScanMetadataDatabase

    init(fileStore: ScanFileStore, db: ScanMetadataDatabase) {
        self.fileStore = fileStore
        self.db = db
    }

    func save(sample: KeyframeSample, seq: Int, scanId: String) throws {
        try save(
            transform: sample.transform,
            capturedAt: sample.capturedAt,
            trackingStateLabel: sample.trackingStateLabel,
            seq: seq,
            scanId: scanId
        )
    }

    func save(
        transform: simd_float4x4,
        capturedAt: Date,
        trackingStateLabel: String,
        seq: Int,
        scanId: String
    ) throws {
        // Sprint 49: jpg 별도 저장 제거. RTABMap 이 자체 db 에 image 보관.
        let poseData = poseBlob(from: transform)
        let t = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        // image_path 는 column 유지 (schema backward compat). 빈 문자열 저장.
        var meta = KeyframeMeta(
            scanId: scanId,
            seq: seq,
            capturedAt: Int64(capturedAt.timeIntervalSince1970 * 1000),
            imagePath: "",
            poseMatrix: poseData,
            tx: Double(t.x),
            ty: Double(t.y),
            tz: Double(t.z),
            trackingState: trackingStateLabel,
            rtabmapNodeId: nil
        )
        try db.dbQueue.write { db in
            try meta.save(db)
        }
    }

    // MARK: Private

    private func poseBlob(from matrix: simd_float4x4) -> Data {
        var cols: [SIMD4<Float>] = [
            matrix.columns.0,
            matrix.columns.1,
            matrix.columns.2,
            matrix.columns.3
        ]
        return Data(bytes: &cols, count: 64) // 4 columns × 4 floats × 4 bytes = 64
    }
}

enum KeyframeRepositoryError: Error {
    case jpegEncodingFailed
}
