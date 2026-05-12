import Testing
import Foundation
@testable import IndoorPathfinding

@Suite("ExportDestinationResolver")
struct ExportDestinationResolverTests {

    private func makeTempExportsDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports-\(UUID().uuidString)")
        return tmp
    }

    @Test("makeFileURL — 충돌 없으면 primary 경로 반환")
    func makeFileURLNoConflictReturnsPrimary() throws {
        let exportsDir = try makeTempExportsDir()
        defer { try? FileManager.default.removeItem(at: exportsDir) }

        let resolver = ExportDestinationResolver(exportsDirectory: exportsDir)
        let scanId = "test-scan-id"
        let url = resolver.makeFileURL(scanId: scanId)

        #expect(url == exportsDir.appendingPathComponent("\(scanId).zip"))
    }

    @Test("makeFileURL — 충돌 시 timestamp suffix 추가")
    func makeFileURLConflictAppendsTimestamp() throws {
        let exportsDir = try makeTempExportsDir()
        defer { try? FileManager.default.removeItem(at: exportsDir) }

        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let resolver = ExportDestinationResolver(exportsDirectory: exportsDir)
        let scanId = "test-scan-id"

        // 기존 파일 생성
        let primary = exportsDir.appendingPathComponent("\(scanId).zip")
        try Data().write(to: primary)

        // 고정된 날짜로 suffix 테스트
        let fixedDate = Date(timeIntervalSince1970: 0)   // 19700101000000
        let url = resolver.makeFileURL(scanId: scanId, now: fixedDate)

        #expect(url != primary)
        #expect(url.lastPathComponent.hasPrefix(scanId + "_"))
        #expect(url.pathExtension == "zip")
    }

    @Test("ensureDirectory — 폴더 생성")
    func ensureDirectoryCreatesFolder() throws {
        let exportsDir = try makeTempExportsDir()
        defer { try? FileManager.default.removeItem(at: exportsDir) }

        let resolver = ExportDestinationResolver(exportsDirectory: exportsDir)
        #expect(!FileManager.default.fileExists(atPath: exportsDir.path))

        try resolver.ensureDirectory()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: exportsDir.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)
    }

    @Test("ensureDirectory — 이미 존재해도 에러 없음")
    func ensureDirectoryIdempotent() throws {
        let exportsDir = try makeTempExportsDir()
        defer { try? FileManager.default.removeItem(at: exportsDir) }

        let resolver = ExportDestinationResolver(exportsDirectory: exportsDir)
        try resolver.ensureDirectory()
        // 두 번 호출해도 에러 없어야 함
        try resolver.ensureDirectory()

        #expect(FileManager.default.fileExists(atPath: exportsDir.path))
    }
}
