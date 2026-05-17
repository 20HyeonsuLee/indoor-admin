import Foundation
import OSLog

// MARK: - Cursor

/// push 진행 위치를 영속화하는 커서.
/// `scanURL/push_cursor.json`에 저장.
struct PushCursor: Codable {
    var lastNodeId: Int
    var lastLinkRowid: Int

    static let zero = PushCursor(lastNodeId: 0, lastLinkRowid: 0)
}

// MARK: - StreamingPushService

/// 백그라운드 actor — rtabmap_working.db에서 새 Node+Data+Link row를 읽어
/// 50개 단위로 StreamingScanClient.pushFrames를 순차 호출한다.
///
/// 정책:
/// - 단일 in-flight 요청: sequential await.
/// - batch 크기: 50 frames.
/// - cursor는 서버 응답의 lastNodeId로 갱신 (응답 수신 후에만 전진).
/// - idempotency: 서버가 nodeId skip으로 보장.
/// - 503 immediate retry 1회.
/// - drain(): 종료 시 남은 row 전부 push.
actor StreamingPushService {

    private static let batchSize = 50
    private static let logger = Logger(
        subsystem: "ac.koreatech.indoorpathfinding",
        category: "streaming.push"
    )

    // MARK: - State

    private let client: StreamingScanClient
    private let scanId: String
    private let scanURL: URL
    private let dbPath: String

    private var cursor: PushCursor
    private var dbReader: RtabmapDBReader?
    private var isRunning: Bool = false

    // MARK: - Observable push progress (MainActor 호출용)

    /// 마지막으로 서버에 확인된 nodeId. UI badge "전송 N/M"의 N.
    private(set) var lastConfirmedNodeId: Int = 0

    // MARK: - Init

    init(client: StreamingScanClient, scanId: String, scanURL: URL) {
        self.client = client
        self.scanId = scanId
        self.scanURL = scanURL
        self.dbPath = scanURL.appendingPathComponent("rtabmap_working.db").path
        self.cursor = PushCursor.zero
        loadCursor()
    }

    // MARK: - Lifecycle

    /// 주기적 push 루프 시작. Task 소유자는 ScanStore.
    func startPushLoop() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await runLoop()
        }
    }

    func stopPushLoop() {
        isRunning = false
    }

    /// scan 종료 시 호출 — 남은 row 전부 push하고 반환.
    func drain() async {
        isRunning = false
        await pushAllRemaining()
    }

    // MARK: - Push loop

    private func runLoop() async {
        NSLog("[StreamingPush] runLoop entered scanId=%@ dbPath=%@", scanId, dbPath)
        while isRunning {
            let pushed = await pushOneBatch()
            if !pushed {
                NSLog("[StreamingPush] tick: no new nodes (cursor=%d)", cursor.lastNodeId)
            }
            // 1초 대기 후 다음 batch (새 row가 충분히 쌓일 시간)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        NSLog("[StreamingPush] runLoop exit (isRunning=false)")
    }

    private func pushAllRemaining() async {
        var moreData = true
        while moreData {
            let pushed = await pushOneBatch()
            moreData = pushed
        }
    }

    /// 한 batch를 push. 전송한 frame이 있으면 true 반환.
    @discardableResult
    private func pushOneBatch() async -> Bool {
        let reader: RtabmapDBReader
        do {
            reader = try ensureReader()
        } catch {
            Self.logger.error("pushOneBatch: reader 열기 실패: \(error)")
            return false
        }

        let nodes: [RtabmapDBReader.NodeRow]
        do {
            nodes = try await reader.readNodes(
                afterNodeId: cursor.lastNodeId,
                batchSize: Self.batchSize
            )
        } catch {
            Self.logger.error("pushOneBatch: readNodes 실패: \(error)")
            return false
        }

        guard !nodes.isEmpty else {
            return false
        }

        let maxNodeIdInBatch = nodes.map { $0.nodeId }.max() ?? cursor.lastNodeId

        // links: 같은 batch의 fromId가 포함된 것들
        let nodeIdSet = Set(nodes.map { $0.nodeId })
        let links: [RtabmapDBReader.LinkRow]
        let newLinkRowid: Int
        do {
            let result = try await reader.readLinks(
                afterRowid: cursor.lastLinkRowid,
                batchSize: Self.batchSize * 2
            )
            links = result.rows.filter { nodeIdSet.contains($0.fromId) || nodeIdSet.contains($0.toId) }
            newLinkRowid = result.lastRowid
        } catch {
            Self.logger.error("pushOneBatch: readLinks 실패: \(error)")
            return false
        }

        let framePayloads = nodes.map { makeFramePayload($0) }
        let linkPayloads  = links.map { makeLinkPayload($0) }

        let request = ScanFramesRequest(frames: framePayloads, links: linkPayloads)

        let response: ScanFramesResponse
        do {
            response = try await pushWithRetry(request: request)
        } catch {
            Self.logger.error("pushOneBatch: push 실패: \(error)")
            return false
        }

        // cursor 갱신 — 응답 수신 후에만 전진
        cursor.lastNodeId = max(cursor.lastNodeId, response.lastNodeId)
        cursor.lastLinkRowid = max(cursor.lastLinkRowid, newLinkRowid)
        lastConfirmedNodeId = cursor.lastNodeId
        saveCursor()

        NSLog("[StreamingPush] pushOneBatch OK applied=%d skipped=%d lastNodeId=%d links=%d",
              response.framesApplied, response.framesSkipped, response.lastNodeId, links.count)
        return true
    }

    // MARK: - Retry (503 즉시 1회)

    private func pushWithRetry(request: ScanFramesRequest) async throws -> ScanFramesResponse {
        do {
            return try await client.pushFrames(scanId: scanId, request: request)
        } catch StreamingClientError.httpError(503, _) {
            Self.logger.warning("pushWithRetry: 503 수신 — 즉시 1회 재시도")
            return try await client.pushFrames(scanId: scanId, request: request)
        }
    }

    // MARK: - Payload builders

    private func makeFramePayload(_ row: RtabmapDBReader.NodeRow) -> FramePayload {
        FramePayload(
            nodeId: row.nodeId,
            stamp: row.stamp,
            pose: row.pose?.base64EncodedString() ?? "",
            image: row.image?.base64EncodedString() ?? "",
            calibration: row.calibration?.base64EncodedString() ?? "",
            mapId: row.mapId,
            weight: row.weight,
            depth: row.depth?.base64EncodedString(),
            scan: row.scan?.base64EncodedString(),
            scanInfo: row.scanInfo?.base64EncodedString(),
            label: row.label,
            userData: row.userData?.base64EncodedString()
        )
    }

    private func makeLinkPayload(_ row: RtabmapDBReader.LinkRow) -> FrameLinkPayload {
        FrameLinkPayload(
            fromId: row.fromId,
            toId: row.toId,
            transform: row.transform.base64EncodedString(),
            type: row.type,
            informationMatrix: row.informationMatrix?.base64EncodedString(),
            userData: row.userData?.base64EncodedString()
        )
    }

    // MARK: - Reader lifecycle

    private func ensureReader() throws -> RtabmapDBReader {
        if let existing = dbReader { return existing }
        let reader = try RtabmapDBReader(dbPath: dbPath)
        dbReader = reader
        return reader
    }

    // MARK: - Cursor persistence

    private var cursorURL: URL {
        scanURL.appendingPathComponent("push_cursor.json")
    }

    private func loadCursor() {
        guard let data = try? Data(contentsOf: cursorURL),
              let loaded = try? JSONDecoder().decode(PushCursor.self, from: data) else {
            cursor = PushCursor.zero
            return
        }
        cursor = loaded
        lastConfirmedNodeId = loaded.lastNodeId
    }

    private func saveCursor() {
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        try? data.write(to: cursorURL, options: .atomic)
    }
}
