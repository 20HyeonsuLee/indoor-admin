import Observation
import Foundation

@Observable
@MainActor
final class ExportProgressModel {

    enum State: Equatable {
        case idle
        case archiving(fraction: Double, processedBytes: Int64, totalBytes: Int64)
        case ready(url: URL)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.archiving(let f1, let p1, let t1), .archiving(let f2, let p2, let t2)):
                return f1 == f2 && p1 == p2 && t1 == t2
            case (.ready(let u1), .ready(let u2)):
                return u1 == u2
            case (.failed(let m1), .failed(let m2)):
                return m1 == m2
            default:
                return false
            }
        }
    }

    private(set) var state: State = .idle

    func markArchivingStart() {
        state = .archiving(fraction: 0, processedBytes: 0, totalBytes: 0)
    }

    func update(_ progress: ArchiveProgress) {
        state = .archiving(
            fraction: progress.fraction,
            processedBytes: progress.processedBytes,
            totalBytes: progress.totalBytes
        )
    }

    func markReady(url: URL) { state = .ready(url: url) }
    func markFailed(_ message: String) { state = .failed(message) }
    func reset() { state = .idle }
}
