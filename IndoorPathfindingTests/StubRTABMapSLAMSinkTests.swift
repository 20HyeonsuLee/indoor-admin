import Testing
import Foundation
@testable import IndoorPathfinding

/// StubRTABMapSLAMSink 유닛 테스트.
/// - no-op 동작 검증 (start/pause는 오류 없음).
/// - finalize: stub 마커 파일이 생성되는지 확인.
/// - pushFrame: 항상 nil 반환.
@MainActor
@Suite("StubRTABMapSLAMSink")
struct StubRTABMapSLAMSinkTests {

    private func makeTempScanURL() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("start()는 오류 없이 완료됨")
    func startNoThrow() throws {
        let sink = StubRTABMapSLAMSink()
        let url = try makeTempScanURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try sink.start(scanURL: url)
        // no-op: 아무 파일도 생성하지 않음
        #expect(true)
    }

    @Test("pushFrame()은 항상 nil 반환")
    func pushFrameReturnsNil() throws {
        let sink = StubRTABMapSLAMSink()
        var buf: CVPixelBuffer!
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buf)
        let sample = KeyframeSample.forTest(
            pixelBuffer: buf,
            transform: .init(diagonal: SIMD4<Float>(1, 1, 1, 1)),
            capturedAt: Date(),
            trackingStateLabel: "normal"
        )
        let nodeID = sink.pushFrame(sample)
        #expect(nodeID == nil)
    }

    @Test("finalize()는 rtabmap.db 파일을 생성하고 빈 nodeStamps를 반환함")
    func finalizeCreatesMarkerFile() throws {
        let sink = StubRTABMapSLAMSink()
        let url = try makeTempScanURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Sprint 35 v4: finalize는 (dbURL, nodeStamps) 튜플을 반환한다.
        let result = try sink.finalize(scanURL: url)
        let dbURL = result.dbURL
        let nodeStamps = result.nodeStamps

        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(dbURL.lastPathComponent == "rtabmap.db")
        // stub 마커는 비어있지 않음
        let content = try String(contentsOf: dbURL, encoding: .utf8)
        #expect(content.contains("stub"))
        // stub은 노드 없음
        #expect(nodeStamps.isEmpty)
    }

    @Test("stats 초기값은 모두 0")
    func statsInitialValueZero() {
        let sink = StubRTABMapSLAMSink()
        #expect(sink.stats.nodeCount == 0)
        #expect(sink.stats.loopClosureCount == 0)
        #expect(sink.stats.dbBytes == 0)
    }
}

// CVPixelBuffer import (테스트 타겟에서도 필요)
import CoreVideo
