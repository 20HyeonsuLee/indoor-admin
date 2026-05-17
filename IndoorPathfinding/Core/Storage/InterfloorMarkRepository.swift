import GRDB
import simd
import Foundation

/// `interfloor_mark` 테이블 CRUD 담당 Repository.
/// Sprint 65: ScanStore.InterfloorMark(in-memory) 와 별도로 sidecar v6 테이블 영속화.
/// Sprint 88 Cycle 6: v8 — keyframeTransform 인자 추가, dxLocal/dyLocal/dzLocal 계산.
final class InterfloorMarkRepository: @unchecked Sendable {
    private let db: ScanMetadataDatabase

    init(db: ScanMetadataDatabase) {
        self.db = db
    }

    /// 1건 INSERT. 같은 (scan_id, keyframe_seq, connector_type, prefix) 가 이미 있어도 허용 — UNIQUE 없음.
    /// Sprint 88 v8: keyframeTransform 인자 추가. interfloor는 markWorld==keyframe → delta=(0,0,0).
    @discardableResult
    func insert(
        scanId: String,
        keyframeSeq: Int,
        connectorType: String,
        prefix: String,
        transform: simd_float4x4,
        keyframeTransform: simd_float4x4? = nil
    ) throws -> Int64 {
        let blob = poseBlob(from: transform)
        let t = transform.columns.3
        let kf = keyframeTransform ?? transform
        let (dx, dy, dz) = markDeltaInKeyframeLocal(
            markTransform: transform,
            keyframeTransform: kf
        )
        var record = InterfloorMarkRecord(
            id: nil,
            scanId: scanId,
            keyframeSeq: keyframeSeq,
            createdAt: nowMs(),
            connectorType: connectorType,
            prefix: prefix,
            poseMatrix: blob,
            tx: Double(t.x),
            ty: Double(t.y),
            tz: Double(t.z),
            dxLocal: dx,
            dyLocal: dy,
            dzLocal: dz
        )
        try db.dbQueue.write { d in try record.save(d) }
        return record.id ?? 0
    }

    func fetchAll(scanId: String) throws -> [InterfloorMarkRecord] {
        try db.dbQueue.read { d in
            try InterfloorMarkRecord
                .filter(InterfloorMarkRecord.Columns.scanId == scanId)
                .order(InterfloorMarkRecord.Columns.id)
                .fetchAll(d)
        }
    }

    /// interfloor_mark 단건 삭제 (undo / overlay tap 용).
    func delete(id: Int64) throws {
        try db.dbQueue.write { d in
            try d.execute(sql: "DELETE FROM interfloor_mark WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Private

    private func poseBlob(from matrix: simd_float4x4) -> Data {
        var cols: [SIMD4<Float>] = [
            matrix.columns.0, matrix.columns.1,
            matrix.columns.2, matrix.columns.3
        ]
        return Data(bytes: &cols, count: 64)
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
