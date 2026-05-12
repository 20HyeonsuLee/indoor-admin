import GRDB
import Foundation

// MARK: - Protocol

protocol BranchEdgeRepositoryProtocol {
    /// finalize 시 markingState.edges 전체를 INSERT.
    /// - Parameters:
    ///   - scanId: ScanStore.scanId
    ///   - edges: MarkingState.edges 전체 (sequential / proximity / transition / cornerPolygon)
    ///   - nodes: MarkingState.nodes (markSessionId 룩업용)
    ///   - closedSessions: tryCloseCornerPolygon 으로 닫힌 session UUID set
    func insertAll(
        scanId: String,
        edges: [BranchMarkEdge],
        nodes: [BranchMarkNode],
        closedSessions: Set<UUID>
    ) throws

    func fetchAll(scanId: String) throws -> [BranchEdgeRecord]
}

// MARK: - Implementation

final class BranchEdgeRepository: BranchEdgeRepositoryProtocol, @unchecked Sendable {
    private let db: ScanMetadataDatabase

    init(db: ScanMetadataDatabase) {
        self.db = db
    }

    /// finalize 시 markingState.edges 전체를 INSERT.
    /// closedSessions: tryCloseCornerPolygon 으로 닫힌 session UUID set.
    ///
    /// - cornerPolygon edge: mark_session_id = session UUID, polygon_closed = 1(닫힘)/0(미완)
    /// - 다른 kind: mark_session_id = NULL, polygon_closed = NULL
    func insertAll(
        scanId: String,
        edges: [BranchMarkEdge],
        nodes: [BranchMarkNode],
        closedSessions: Set<UUID>
    ) throws {
        // node id → markSessionId? 룩업
        let sessionByNodeId: [BranchMarkNodeId: UUID?] = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, $0.markSessionId) }
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        try db.dbQueue.write { db in
            for e in edges {
                let session: UUID?
                let polygonClosed: Int?

                if e.kind == .cornerPolygon {
                    // cornerPolygon edge 의 from node 에서 markSessionId 를 가져온다.
                    session = sessionByNodeId[e.from] ?? nil
                    if let s = session, closedSessions.contains(s) {
                        polygonClosed = 1
                    } else {
                        polygonClosed = 0
                    }
                } else {
                    session = nil
                    polygonClosed = nil
                }

                var rec = BranchEdgeRecord(
                    id: nil,
                    scanId: scanId,
                    fromNodeId: String(e.from),
                    toNodeId: String(e.to),
                    kind: e.kind.rawValue,
                    lengthM: e.lengthM,
                    markSessionId: session?.uuidString,
                    polygonClosed: polygonClosed,
                    createdAt: now
                )
                try rec.insert(db)
            }
        }
    }

    func fetchAll(scanId: String) throws -> [BranchEdgeRecord] {
        try db.dbQueue.read { db in
            try BranchEdgeRecord
                .filter(Column("scan_id") == scanId)
                .order(Column("id").asc)
                .fetchAll(db)
        }
    }
}
