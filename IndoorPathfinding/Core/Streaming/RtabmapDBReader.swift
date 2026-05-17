import Foundation
import SQLite3
import OSLog

/// rtabmap_working.db에서 RTABMap Node/Data/Link row를 읽어온다.
///
/// RTABMap이 쓰는 DB를 동시에 읽기 위해 readonly open + WAL 모드를 사용한다.
/// RTABMap native는 journal_mode=WAL로 열므로 reader는 savepoint 없이 BEGIN DEFERRED
/// 트랜잭션으로 consistent snapshot을 읽는다.
///
/// `flushForRead()` 진입 전에 호출자(StreamingPushService)가 RTABMapBridge에
/// 잠깐 pause를 요청해도 되지만, happy path에서는 그냥 읽는다.
actor RtabmapDBReader {

    private static let logger = Logger(
        subsystem: "ac.koreatech.indoorpathfinding",
        category: "rtabmap.dbreader"
    )

    private var dbPath: String
    private var db: OpaquePointer?

    // MARK: - NodeRow / LinkRow

    struct NodeRow {
        let nodeId: Int
        let stamp: Double
        let image: Data?
        let depth: Data?
        let calibration: Data?
        let pose: Data?
        let groundTruthPose: Data?
        let scan: Data?
        let scanInfo: Data?
        let label: String?
        let userData: Data?
        let mapId: Int
        let weight: Int
    }

    struct LinkRow {
        let fromId: Int
        let toId: Int
        let type: Int
        let transform: Data
        let informationMatrix: Data?
        let userData: Data?
    }

    // MARK: - Init / Open

    init(dbPath: String) throws {
        self.dbPath = dbPath
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard result == SQLITE_OK else {
            throw RtabmapDBReaderError.openFailed(result)
        }
        // WAL checkpoint 완료 여부 무관하게 readonly snapshot으로 읽는다.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        Self.logger.info("RtabmapDBReader opened: \(dbPath)")
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Node/Data 읽기

    /// cursor 이후 Node row를 최대 batchSize개 읽어 반환한다.
    /// - Parameter afterNodeId: 이 nodeId보다 큰 행만 반환 (0이면 전체)
    func readNodes(afterNodeId: Int, batchSize: Int) throws -> [NodeRow] {
        guard let db else { throw RtabmapDBReaderError.notOpen }

        // Node table: id, stamp, map_id, weight, label, time_enter, pose, ground_truth_pose, velocity, gps, env_sensors
        // Data table: id (FK → Node.id), image, depth, calibration, scan, scan_info, ground_truth_pose, user_data
        let sql = """
        SELECT
            n.id, n.stamp, n.map_id, n.weight, n.label,
            n.pose, n.ground_truth_pose,
            d.image, d.depth, d.calibration, d.scan, d.scan_info, d.user_data
        FROM Node n
        LEFT JOIN Data d ON d.id = n.id
        WHERE n.id > ?
        ORDER BY n.id ASC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RtabmapDBReaderError.prepareFailed(sqlite3_errmsg(db).map(String.init) ?? "")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(afterNodeId))
        sqlite3_bind_int(stmt, 2, Int32(batchSize))

        var rows: [NodeRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let row = extractNodeRow(stmt: stmt!)
            rows.append(row)
        }
        return rows
    }

    private func extractNodeRow(stmt: OpaquePointer) -> NodeRow {
        let nodeId  = Int(sqlite3_column_int(stmt, 0))
        let stamp   = sqlite3_column_double(stmt, 1)
        let mapId   = Int(sqlite3_column_int(stmt, 2))
        let weight  = Int(sqlite3_column_int(stmt, 3))
        let label: String? = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

        let pose            = columnBlob(stmt, col: 5)
        let groundTruthPose = columnBlob(stmt, col: 6)
        let image           = columnBlob(stmt, col: 7)
        let depth           = columnBlob(stmt, col: 8)
        let calibration     = columnBlob(stmt, col: 9)
        let scan            = columnBlob(stmt, col: 10)
        let scanInfo        = columnBlob(stmt, col: 11)
        let userData        = columnBlob(stmt, col: 12)

        return NodeRow(
            nodeId: nodeId,
            stamp: stamp,
            image: image,
            depth: depth,
            calibration: calibration,
            pose: pose,
            groundTruthPose: groundTruthPose,
            scan: scan,
            scanInfo: scanInfo,
            label: label,
            userData: userData,
            mapId: mapId,
            weight: weight
        )
    }

    // MARK: - Link 읽기

    /// cursor 이후 Link row를 읽어 반환한다.
    /// `afterLinkRowId`는 rowid 기반 cursor (Link 테이블의 INTEGER PRIMARY KEY가 없으므로 rowid 사용).
    func readLinks(afterRowid: Int, batchSize: Int) throws -> (rows: [LinkRow], lastRowid: Int) {
        guard let db else { throw RtabmapDBReaderError.notOpen }

        let sql = """
        SELECT rowid, from_id, to_id, type, transform, information_matrix, user_data
        FROM Link
        WHERE rowid > ?
        ORDER BY rowid ASC
        LIMIT ?
        """
        var stmtOpt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmtOpt, nil) == SQLITE_OK,
              let stmt = stmtOpt else {
            throw RtabmapDBReaderError.prepareFailed(sqlite3_errmsg(db).map(String.init) ?? "")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(afterRowid))
        sqlite3_bind_int(stmt, 2, Int32(batchSize))

        var rows: [LinkRow] = []
        var lastRowid = afterRowid
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid   = Int(sqlite3_column_int64(stmt, 0))
            let fromId  = Int(sqlite3_column_int(stmt, 1))
            let toId    = Int(sqlite3_column_int(stmt, 2))
            let type    = Int(sqlite3_column_int(stmt, 3))
            guard let transform = columnBlob(stmt, col: 4) else { continue }
            let infoMatrix  = columnBlob(stmt, col: 5)
            let userData    = columnBlob(stmt, col: 6)
            rows.append(LinkRow(
                fromId: fromId,
                toId: toId,
                type: type,
                transform: transform,
                informationMatrix: infoMatrix,
                userData: userData
            ))
            lastRowid = rowid
        }
        return (rows: rows, lastRowid: lastRowid)
    }

    // MARK: - Helpers

    private func columnBlob(_ stmt: OpaquePointer, col: Int32) -> Data? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        guard let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        let bytes = Int(sqlite3_column_bytes(stmt, col))
        guard bytes > 0 else { return nil }
        return Data(bytes: ptr, count: bytes)
    }
}

// MARK: - Error

enum RtabmapDBReaderError: LocalizedError {
    case openFailed(Int32)
    case notOpen
    case prepareFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code):
            return "rtabmap.db open 실패: SQLite error \(code)"
        case .notOpen:
            return "rtabmap.db가 열려 있지 않습니다."
        case .prepareFailed(let msg):
            return "SQL 준비 실패: \(msg)"
        }
    }
}
