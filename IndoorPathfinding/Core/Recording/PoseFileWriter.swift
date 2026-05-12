import Foundation
import simd

/// Sprint 67 — ARFrame timestamp + transform 을 binary 로 누적하는 writer.
///
/// 포맷:
///   record = pts_ns (Int64 little-endian, 8B)
///         + transform 16 × Float32 little-endian (column-major, 64B)
///   = 72B / record. 36000 frame (10분 60Hz) = 2.6MB.
///
/// 헤더 없음. 의도적으로 단순. record 개수는 manifest.json 의 `pose_record_count` 로 알린다.
/// intrinsics 는 session 동안 고정이므로 manifest 에 한 번만 기록 (record 에 포함 안 함).
///
/// 서버 PoseMatcher 가 같은 layout 으로 mmap 하여 binary search 한다.
final class PoseFileWriter {

    enum WriterError: Error {
        case alreadyClosed
        case ioFailed(Error)
    }

    static let recordSize: Int = 72
    static let posesFileName = "poses.bin"

    private let url: URL
    private var handle: FileHandle?
    private(set) var recordCount: Int = 0
    private let queue = DispatchQueue(label: "scan.pose.writer", qos: .utility)

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    /// 호출자: VideoRecorderConsumer (MainActor). 내부적으로 직렬 큐로 dispatch.
    func append(ptsNanoseconds: Int64, transform: simd_float4x4) {
        let queueRef = queue
        queueRef.async { [weak self] in
            guard let self, let handle = self.handle else { return }

            var buffer = Data(count: PoseFileWriter.recordSize)
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                var pts = ptsNanoseconds.littleEndian
                memcpy(base, &pts, 8)

                let cols = (transform.columns.0, transform.columns.1,
                            transform.columns.2, transform.columns.3)
                var floats: [Float] = [
                    cols.0.x, cols.0.y, cols.0.z, cols.0.w,
                    cols.1.x, cols.1.y, cols.1.z, cols.1.w,
                    cols.2.x, cols.2.y, cols.2.z, cols.2.w,
                    cols.3.x, cols.3.y, cols.3.z, cols.3.w
                ]
                memcpy(base.advanced(by: 8), &floats, 64)
            }

            do {
                try handle.write(contentsOf: buffer)
                self.recordCount += 1
            } catch {
                NSLog("[PoseFileWriter] write failed: %@", String(describing: error))
            }
        }
    }

    /// 동기 close. 호출자: ScanStore.finalize().
    /// queue 를 비우고 fsync 후 handle close.
    func close() throws {
        try queue.sync {
            guard let handle = self.handle else { return }
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                throw WriterError.ioFailed(error)
            }
            self.handle = nil
        }
    }

    deinit {
        try? close()
    }
}
