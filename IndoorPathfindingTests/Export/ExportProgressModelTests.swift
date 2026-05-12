import Testing
import Foundation
@testable import IndoorPathfinding

@MainActor
@Suite("ExportProgressModel")
struct ExportProgressModelTests {

    @Test("초기 상태는 idle")
    func initialStateIsIdle() {
        let model = ExportProgressModel()
        #expect(model.state == .idle)
    }

    @Test("markArchivingStart — fraction/bytes 모두 0인 archiving 상태")
    func markArchivingStartSetsZeroState() {
        let model = ExportProgressModel()
        model.markArchivingStart()
        #expect(model.state == .archiving(fraction: 0, processedBytes: 0, totalBytes: 0))
    }

    @Test("update — fraction 반영")
    func updateReflectsFraction() {
        let model = ExportProgressModel()
        let progress = ArchiveProgress(processedBytes: 512, totalBytes: 1024)
        model.update(progress)
        #expect(model.state == .archiving(fraction: 0.5, processedBytes: 512, totalBytes: 1024))
    }

    @Test("update — totalBytes 0이면 fraction 0")
    func updateWithZeroTotalBytesFractionIsZero() {
        let model = ExportProgressModel()
        let progress = ArchiveProgress(processedBytes: 0, totalBytes: 0)
        model.update(progress)
        #expect(model.state == .archiving(fraction: 0, processedBytes: 0, totalBytes: 0))
    }

    @Test("markReady — url 저장")
    func markReadyStoresUrl() {
        let model = ExportProgressModel()
        let url = URL(fileURLWithPath: "/tmp/test.zip")
        model.markReady(url: url)
        #expect(model.state == .ready(url: url))
    }

    @Test("markFailed — 메시지 저장")
    func markFailedStoresMessage() {
        let model = ExportProgressModel()
        model.markFailed("테스트 에러")
        #expect(model.state == .failed("테스트 에러"))
    }

    @Test("reset — idle로 복귀")
    func resetReturnsToIdle() {
        let model = ExportProgressModel()
        model.markArchivingStart()
        model.reset()
        #expect(model.state == .idle)
    }

    @Test("0 → 1 진행률 흐름")
    func progressFlowZeroToOne() {
        let model = ExportProgressModel()
        model.markArchivingStart()

        let steps: [ArchiveProgress] = [
            ArchiveProgress(processedBytes: 0, totalBytes: 1000),
            ArchiveProgress(processedBytes: 250, totalBytes: 1000),
            ArchiveProgress(processedBytes: 500, totalBytes: 1000),
            ArchiveProgress(processedBytes: 750, totalBytes: 1000),
            ArchiveProgress(processedBytes: 1000, totalBytes: 1000),
        ]

        var fractions: [Double] = []
        for step in steps {
            model.update(step)
            fractions.append(step.fraction)
        }

        #expect(fractions.first == 0.0)
        #expect(fractions.last == 1.0)

        // 단조 증가 검증
        for index in 1..<fractions.count {
            #expect(fractions[index] >= fractions[index - 1])
        }
    }
}
