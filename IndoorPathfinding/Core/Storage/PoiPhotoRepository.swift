import GRDB
import Foundation

/// `poi_photo` 테이블 CRUD 담당 Repository.
/// Sprint 65: bbox 인자 제거 — 수동 POI 단일 경로.
final class PoiPhotoRepository {
    private let db: ScanMetadataDatabase

    init(db: ScanMetadataDatabase) {
        self.db = db
    }

    /// poi_photo 1건 삽입.
    /// - Parameter imageBlob: jpeg encoded bytes. nil 이면 사진 미보관 (legacy 호환).
    /// - Returns: 삽입된 row id.
    @discardableResult
    func insert(
        poiMarkId: Int64,
        scanId: String,
        keyframeSeq: Int,
        capturedAt: Int64,
        className: String,
        confidence: Double,
        imageBlob: Data? = nil
    ) throws -> Int64 {
        try db.dbQueue.write { d in
            try d.execute(
                sql: """
                INSERT INTO poi_photo
                    (poi_mark_id, scan_id, keyframe_seq, captured_at,
                     class_name, confidence, image_blob)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    poiMarkId, scanId, keyframeSeq, capturedAt,
                    className, confidence, imageBlob
                ]
            )
            return d.lastInsertedRowID
        }
    }

    /// 특정 poi_mark_id에 속하는 모든 poi_photo를 id DESC 순으로 반환.
    func fetchAll(poiMarkId: Int64) throws -> [PoiPhoto] {
        try db.dbQueue.read { d in
            try PoiPhoto
                .filter(PoiPhoto.Columns.poiMarkId == poiMarkId)
                .order(PoiPhoto.Columns.id.desc)
                .fetchAll(d)
        }
    }
}
