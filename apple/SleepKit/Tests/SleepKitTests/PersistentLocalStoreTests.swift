import XCTest
@testable import SleepKit

final class PersistentLocalStoreTests: XCTestCase {

    // MARK: Helpers

    private func freshURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plstore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local_store.json")
    }

    private func sampleSummary(id: String, dur: Int = 6 * 3600, score: Int = 80) -> SessionSummary {
        SessionSummary(sessionId: id,
                       durationSec: dur,
                       timeInWakeSec: 600,
                       timeInLightSec: 3000,
                       timeInDeepSec: 1800,
                       timeInRemSec: 1200,
                       sleepScore: score)
    }

    private func sampleRecord(id: String, started: Date, ended: Date,
                              timeline: [TimelineEntry] = []) -> StoredSessionRecord {
        StoredSessionRecord(
            id: id,
            startedAt: started,
            endedAt: ended,
            summary: sampleSummary(id: id),
            alarm: StoredAlarmMeta(
                enabled: true,
                finalStateRaw: AlarmState.dismissed.rawValue,
                targetTsMs: Int64(ended.timeIntervalSince1970 * 1000),
                windowMinutes: 30,
                triggeredAtTsMs: Int64((ended.timeIntervalSince1970 - 60) * 1000),
                dismissedAtTsMs: Int64(ended.timeIntervalSince1970 * 1000)
            ),
            sourceRaw: TrackingSource.localPhone.rawValue,
            runtimeModeRaw: "live",
            notes: nil,
            timeline: timeline
        )
    }

    // MARK: 1. Roundtrip across reinitialization

    func testPersistedRecordSurvivesReinit() async throws {
        let url = freshURL()
        let s1 = PersistentLocalStore(fileURL: url)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let ended = started.addingTimeInterval(3600)
        let rec = sampleRecord(id: "sess-A", started: started, ended: ended)
        try await s1.recordSessionRecord(rec)

        // Drop the actor; reinitialize from disk.
        let s2 = PersistentLocalStore(fileURL: url)
        let restored = try await s2.record(for: "sess-A")
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.id, "sess-A")
        XCTAssertEqual(restored?.summary?.sleepScore, 80)
        XCTAssertEqual(restored?.alarm?.finalState, .dismissed)
        XCTAssertEqual(restored?.sourceRaw, TrackingSource.localPhone.rawValue)

        let listed = try await s2.listSessions(limit: 10)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, "sess-A")
    }

    // MARK: 2. Timeline chronological order

    func testTimelineEntriesPersistedInOrder() async throws {
        let url = freshURL()
        let s = PersistentLocalStore(fileURL: url)
        let t0 = Date(timeIntervalSince1970: 1_700_010_000)
        let entries = [
            TimelineEntry(stage: .deep,  start: t0.addingTimeInterval(1800), end: t0.addingTimeInterval(2700)),
            TimelineEntry(stage: .wake,  start: t0,                          end: t0.addingTimeInterval(600)),
            TimelineEntry(stage: .light, start: t0.addingTimeInterval(600),  end: t0.addingTimeInterval(1800)),
        ]
        let rec = sampleRecord(id: "sess-T",
                               started: t0,
                               ended: t0.addingTimeInterval(2700),
                               timeline: entries)
        try await s.recordSessionRecord(rec)

        let s2 = PersistentLocalStore(fileURL: url)
        let read = try await s2.timeline(for: "sess-T")
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read.map { $0.stage }, [.wake, .light, .deep])
        for i in 1..<read.count {
            XCTAssertLessThanOrEqual(read[i-1].start, read[i].start)
        }
    }

    // MARK: 3. Latest-completed restore

    func testLatestCompletedSummaryReturnsMostRecent() async throws {
        let url = freshURL()
        let s = PersistentLocalStore(fileURL: url)
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        try await s.recordSessionRecord(
            sampleRecord(id: "old", started: base, ended: base.addingTimeInterval(3600))
        )
        try await s.recordSessionRecord(
            sampleRecord(id: "new",
                         started: base.addingTimeInterval(86_400),
                         ended:   base.addingTimeInterval(86_400 + 3600))
        )
        let s2 = PersistentLocalStore(fileURL: url)
        let latest = try await s2.latestCompletedSummary()
        XCTAssertEqual(latest?.sessionId, "new")
    }

    // MARK: 4. Corrupt-file recovery

    func testCorruptFileDoesNotCrashAndIsQuarantined() async throws {
        let url = freshURL()
        try Data("{ this is not json ".utf8).write(to: url)
        let s = PersistentLocalStore(fileURL: url)
        let listed = try await s.listSessions(limit: 10)
        XCTAssertTrue(listed.isEmpty)
        let err = await s.loadError
        XCTAssertNotNil(err)

        // After recovery a fresh write must succeed.
        let started = Date(timeIntervalSince1970: 1_700_200_000)
        try await s.recordSessionRecord(
            sampleRecord(id: "after-corrupt",
                         started: started,
                         ended: started.addingTimeInterval(1800))
        )
        let s2 = PersistentLocalStore(fileURL: url)
        let listed2 = try await s2.listSessions(limit: 10)
        XCTAssertEqual(listed2.first?.id, "after-corrupt")
    }

    // MARK: 5. Clear-all wipes everything

    func testClearAllRemovesEveryRecord() async throws {
        let url = freshURL()
        let s = PersistentLocalStore(fileURL: url)
        let base = Date(timeIntervalSince1970: 1_700_300_000)
        try await s.recordSessionRecord(
            sampleRecord(id: "x", started: base, ended: base.addingTimeInterval(3600))
        )
        try await s.clearAllLocalData()

        let s2 = PersistentLocalStore(fileURL: url)
        let listed = try await s2.listSessions(limit: 10)
        XCTAssertTrue(listed.isEmpty)
        let latest = try await s2.latestCompletedSummary()
        XCTAssertNil(latest)
    }

    // MARK: 6. InMemoryLocalStore satisfies the new protocol

    func testInMemoryStoreRoundtripsFullRecord() async throws {
        let s: LocalStoreProtocol = InMemoryLocalStore()
        let started = Date(timeIntervalSince1970: 1_700_400_000)
        let entry = TimelineEntry(stage: .light, start: started, end: started.addingTimeInterval(900))
        let rec = sampleRecord(id: "mem-1",
                               started: started,
                               ended: started.addingTimeInterval(900),
                               timeline: [entry])
        try await s.recordSessionRecord(rec)
        let back = try await s.record(for: "mem-1")
        XCTAssertEqual(back?.timeline.count, 1)
        let latest = try await s.latestCompletedSummary()
        XCTAssertEqual(latest?.sessionId, "mem-1")

        try await s.clearAllLocalData()
        let after = try await s.listSessions(limit: 10)
        XCTAssertTrue(after.isEmpty)
    }
}
