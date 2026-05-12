import GRDB
import simd
import Foundation

// MARK: - Protocol

protocol MarkRepositoryProtocol {
    func insertPOI(scanId: String, keyframeSeq: Int, transform: simd_float4x4) throws
    func insertBranch(scanId: String, keyframeSeq: Int, transform: simd_float4x4) throws
}


// MARK: - 구현

/// POI / Branch mark DB insert. KeyframeRepository와 동일 background serial queue에서 사용.
/// Sprint 65: trackId 인자 제거 — 수동 POI 단일 경로 (source 항상 'manual').
/// Sprint 88 Cycle 2: v7 schema 확장 — insertBranch 시그니처 확장 + update/delete/fetchAll 추가.
/// Sprint 88 Cycle 6: v8 schema 확장 — keyframeTransform 인자 추가, delta 자동 계산.
final class MarkRepository: MarkRepositoryProtocol, @unchecked Sendable {
    private let db: ScanMetadataDatabase

    init(db: ScanMetadataDatabase) {
        self.db = db
    }

    /// Protocol 충족 (v6 호환 시그니처). delta=(0,0,0) 명시 저장.
    func insertPOI(scanId: String, keyframeSeq: Int, transform: simd_float4x4) throws {
        try insertPOI(
            scanId: scanId,
            keyframeSeq: keyframeSeq,
            transform: transform,
            keyframeTransform: transform,
            label: nil
        )
    }

    /// Sprint 88 v8: keyframeTransform 인자 추가. POI는 markWorld==keyframe → delta=(0,0,0).
    @discardableResult
    func insertPOI(
        scanId: String,
        keyframeSeq: Int,
        transform: simd_float4x4,
        keyframeTransform: simd_float4x4,
        label: String? = nil
    ) throws -> Int64 {
        let blob = poseBlob(from: transform)
        let t = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let dx = Double(transform.columns.3.x - keyframeTransform.columns.3.x)
        let dy = Double(transform.columns.3.y - keyframeTransform.columns.3.y)
        let dz = Double(transform.columns.3.z - keyframeTransform.columns.3.z)
        var mark = PoiMark(
            id: nil,
            scanId: scanId,
            keyframeSeq: keyframeSeq,
            createdAt: nowMs(),
            poseMatrix: blob,
            tx: Double(t.x),
            ty: Double(t.y),
            tz: Double(t.z),
            label: label,
            source: PoiMark.Source.manual.rawValue,
            dxLocal: dx,
            dyLocal: dy,
            dzLocal: dz
        )
        return try db.dbQueue.write { db in
            try mark.save(db)
            return db.lastInsertedRowID
        }
    }

    /// Protocol 충족 (v6 호환 시그니처). 신규 컬럼은 default 값.
    func insertBranch(scanId: String, keyframeSeq: Int, transform: simd_float4x4) throws {
        try insertBranch(
            scanId: scanId,
            keyframeSeq: keyframeSeq,
            transform: transform,
            keyframeTransform: transform,
            nodeType: .corridor,
            widthM: nil,
            connectHint: nil,
            connectNodeId: nil,
            markSessionId: nil
        )
    }

    // MARK: v7 호환 시그니처 (keyframeTransform 없음 → delta=0 폴백)

    /// keyframeTransform 없는 v7 호환 호출. delta=(0,0,0) 명시 저장.
    @discardableResult
    func insertBranch(
        scanId: String,
        keyframeSeq: Int,
        transform: simd_float4x4,
        nodeType: BranchMark.NodeTypeValue = .corridor,
        widthM: Double? = nil,
        connectHint: BranchMark.ConnectHintValue? = nil,
        connectNodeId: String? = nil,
        markSessionId: String? = nil
    ) throws -> Int64 {
        try insertBranch(
            scanId: scanId,
            keyframeSeq: keyframeSeq,
            transform: transform,
            keyframeTransform: transform,
            nodeType: nodeType,
            widthM: widthM,
            connectHint: connectHint,
            connectNodeId: connectNodeId,
            markSessionId: markSessionId
        )
    }

    // MARK: v8 확장 시그니처

    /// Sprint 88 v8: keyframeTransform 인자 추가, dx/dy/dz 자동 계산.
    /// corridor: delta=(0, floorY−camY, 0), corner: (hitX−camX, floorY−camY, hitZ−camZ).
    @discardableResult
    func insertBranch(
        scanId: String,
        keyframeSeq: Int,
        transform: simd_float4x4,
        keyframeTransform: simd_float4x4,
        nodeType: BranchMark.NodeTypeValue = .corridor,
        widthM: Double? = nil,
        connectHint: BranchMark.ConnectHintValue? = nil,
        connectNodeId: String? = nil,
        markSessionId: String? = nil
    ) throws -> Int64 {
        let blob = poseBlob(from: transform)
        let t = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let dx = Double(transform.columns.3.x - keyframeTransform.columns.3.x)
        let dy = Double(transform.columns.3.y - keyframeTransform.columns.3.y)
        let dz = Double(transform.columns.3.z - keyframeTransform.columns.3.z)
        var mark = BranchMark(
            id: nil,
            scanId: scanId,
            keyframeSeq: keyframeSeq,
            createdAt: nowMs(),
            poseMatrix: blob,
            tx: Double(t.x),
            ty: Double(t.y),
            tz: Double(t.z),
            nodeType: nodeType.rawValue,
            widthM: widthM,
            connectHint: connectHint?.rawValue,
            connectNodeId: connectNodeId,
            markSessionId: markSessionId,
            dxLocal: dx,
            dyLocal: dy,
            dzLocal: dz
        )
        return try db.dbQueue.write { db in
            try mark.save(db)
            return db.lastInsertedRowID
        }
    }

    /// Sprint 88 v7: branch_mark 수정 (수정 sheet). nodeType과 widthM만 갱신.
    func updateBranch(id: Int64, nodeType: BranchMark.NodeTypeValue, widthM: Double?) throws {
        try db.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE branch_mark
                   SET node_type = ?, width_m = ?
                 WHERE id = ?
                """,
                arguments: [nodeType.rawValue, widthM, id]
            )
        }
    }

    /// Sprint 88 v7: branch_mark 단건 삭제. overlay tap 삭제 + undo 용.
    func deleteBranch(id: Int64) throws {
        try db.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM branch_mark WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Sprint 88 v7: scanId 기준 모든 branch_mark 조회. overlay/finalize sheet 입력.
    func fetchAllBranches(scanId: String) throws -> [BranchMark] {
        try db.dbQueue.read { db in
            try BranchMark.filter(Column("scan_id") == scanId)
                .order(Column("created_at").asc)
                .fetchAll(db)
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

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - BranchMark NodeType/ConnectHint enum 보조 타입

extension BranchMark {
    /// node_type 컬럼 타입 안전 접근.
    enum NodeTypeValue: String {
        case corridor
        case corner
    }

    /// connect_hint 컬럼 타입 안전 접근.
    enum ConnectHintValue: String {
        case proximity
    }
}
