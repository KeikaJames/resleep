import XCTest
@testable import SleepKit

final class ActiveSessionMarkerStoreTests: XCTestCase {

    private func freshURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active_session.json")
    }

    func testWriteThenReadRoundtrip() async {
        let url = freshURL()
        let s = ActiveSessionMarkerStore(fileURL: url)
        let m = ActiveSessionMarker(
            sessionId: "S1",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceRaw: TrackingSource.remoteWatch.rawValue,
            runtimeModeRaw: "live",
            smartAlarmEnabled: true,
            alarmTargetTsMs: 1_700_007_200_000,
            alarmWindowMinutes: 30
        )
        await s.write(m)

        let s2 = ActiveSessionMarkerStore(fileURL: url)
        let read = await s2.read()
        XCTAssertEqual(read?.sessionId, "S1")
        XCTAssertTrue(read?.smartAlarmEnabled ?? false)
        XCTAssertEqual(read?.alarmWindowMinutes, 30)
    }

    func testClearRemovesMarker() async {
        let url = freshURL()
        let s = ActiveSessionMarkerStore(fileURL: url)
        await s.write(ActiveSessionMarker(
            sessionId: "S2",
            startedAt: Date(),
            sourceRaw: TrackingSource.localPhone.rawValue,
            runtimeModeRaw: "live",
            smartAlarmEnabled: false
        ))
        await s.clear()
        let s2 = ActiveSessionMarkerStore(fileURL: url)
        let after = await s2.read()
        XCTAssertNil(after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptMarkerIsQuarantined() async throws {
        let url = freshURL()
        try "{ not json".data(using: .utf8)!.write(to: url)
        let s = ActiveSessionMarkerStore(fileURL: url)
        let read = await s.read()
        XCTAssertNil(read)
        // Corrupt file should have been moved to a quarantine sibling.
        let parent = url.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertTrue(siblings.contains(where: { $0.contains("corrupt-") }))
    }

    func testInMemoryMarkerStoreWorks() async {
        let s = InMemoryActiveSessionMarkerStore()
        let pre = await s.read()
        XCTAssertNil(pre)
        await s.write(ActiveSessionMarker(
            sessionId: "M",
            startedAt: Date(),
            sourceRaw: "localPhone",
            runtimeModeRaw: "live",
            smartAlarmEnabled: true
        ))
        let mid = await s.read()
        XCTAssertEqual(mid?.sessionId, "M")
        await s.clear()
        let post = await s.read()
        XCTAssertNil(post)
    }
}
