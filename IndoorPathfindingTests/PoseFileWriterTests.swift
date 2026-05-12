import Testing
import Foundation
import simd
@testable import IndoorPathfinding

/// Sprint 67 — PoseFileWriter binary 포맷 roundtrip 검증.
///
/// 서버 PoseMatcher 와 정확히 동일한 layout 으로 직렬화되는지 확인.
/// record = pts_ns Int64 LE (8B) + 16 × Float32 LE (column-major, 64B) = 72B.
@Suite("PoseFileWriter")
struct PoseFileWriterTests {

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pose_writer_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("poses.bin")
    }

    @Test("recordSize 는 정확히 72 bytes")
    func recordSizeContract() {
        #expect(PoseFileWriter.recordSize == 72)
    }

    @Test("append → close → 파일 사이즈 = recordCount × 72")
    func appendCloseProducesExpectedSize() throws {
        let url = tempURL()
        let writer = try PoseFileWriter(url: url)

        let m1 = matrix_identity_float4x4
        var m2 = matrix_identity_float4x4
        m2.columns.3 = SIMD4<Float>(1.5, 2.5, 3.5, 1.0)

        writer.append(ptsNanoseconds: 1_000_000_000, transform: m1)
        writer.append(ptsNanoseconds: 1_016_666_666, transform: m2)
        try writer.close()

        let data = try Data(contentsOf: url)
        #expect(data.count == 72 * 2)
    }

    @Test("binary layout: pts_ns Int64 LE + 16 Float32 LE column-major")
    func binaryLayoutRoundtrip() throws {
        let url = tempURL()
        let writer = try PoseFileWriter(url: url)

        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(7.0, -3.5, 2.25, 1.0)
        let expectedPts: Int64 = 1_500_000_000_500  // 1500.0005 sec

        writer.append(ptsNanoseconds: expectedPts, transform: m)
        try writer.close()

        let data = try Data(contentsOf: url)
        #expect(data.count == 72)

        let pts = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int64.self) }
        #expect(Int64(littleEndian: pts) == expectedPts)

        // column 3 (translation): byte offset 8 + 12*4 = 56
        let tx = data.withUnsafeBytes { $0.load(fromByteOffset: 8 + 12 * 4, as: Float.self) }
        let ty = data.withUnsafeBytes { $0.load(fromByteOffset: 8 + 13 * 4, as: Float.self) }
        let tz = data.withUnsafeBytes { $0.load(fromByteOffset: 8 + 14 * 4, as: Float.self) }
        #expect(tx == 7.0)
        #expect(ty == -3.5)
        #expect(tz == 2.25)

        // column 0 row 0 (identity diagonal): offset 8 + 0
        let m00 = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) }
        #expect(m00 == 1.0)
    }

    @Test("close 후 record count 누적 확인")
    func recordCountTracksAppends() throws {
        let url = tempURL()
        let writer = try PoseFileWriter(url: url)

        for i in 0..<10 {
            writer.append(
                ptsNanoseconds: Int64(i) * 16_666_666,
                transform: matrix_identity_float4x4
            )
        }
        try writer.close()

        let data = try Data(contentsOf: url)
        #expect(data.count == 72 * 10)
    }
}
