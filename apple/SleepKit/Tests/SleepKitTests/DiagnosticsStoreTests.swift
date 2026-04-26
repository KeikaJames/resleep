import XCTest
@testable import SleepKit

final class DiagnosticsStoreTests: XCTestCase {

    private func freshURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.jsonl")
    }

    func testAppendThenReadRoundtrip() async {
        let url = freshURL()
        let s = DiagnosticsStore(fileURL: url)
        await s.append(DiagnosticEvent(type: .appLaunch))
        await s.append(DiagnosticEvent(type: .sessionStart, sessionId: "S1"))
        await s.append(DiagnosticEvent(type: .telemetryBatchReceived,
                                        sessionId: "S1",
                                        counters: ["hr": 12, "accel": 6]))
        await s.append(DiagnosticEvent(type: .sessionStop, sessionId: "S1"))

        let events = await s.all()
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.map { $0.type }, [.appLaunch, .sessionStart, .telemetryBatchReceived, .sessionStop])
        XCTAssertEqual(events[2].counters?["hr"], 12)
    }

    func testReadAfterReinit() async {
        let url = freshURL()
        let s1 = DiagnosticsStore(fileURL: url)
        await s1.append(DiagnosticEvent(type: .sessionStart, sessionId: "X"))
        await s1.append(DiagnosticEvent(type: .sessionStop, sessionId: "X"))
        // Drop and reopen.
        let s2 = DiagnosticsStore(fileURL: url)
        let events = await s2.all()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.type, .sessionStop)
    }

    func testCorruptLineIsSkipped() async throws {
        let url = freshURL()
        // Write a deliberately malformed line followed by a valid one.
        let s = DiagnosticsStore(fileURL: url)
        await s.append(DiagnosticEvent(type: .appLaunch))

        // Append a corrupt line manually.
        var data = try Data(contentsOf: url)
        data.append("\n{not json}\n".data(using: .utf8)!)
        try data.write(to: url)

        await s.append(DiagnosticEvent(type: .appForeground))
        let events = await s.all()
        XCTAssertEqual(events.count, 2, "corrupt line should be silently skipped")
        XCTAssertEqual(events.map { $0.type }, [.appLaunch, .appForeground])
    }

    func testClearRemovesEverything() async {
        let url = freshURL()
        let s = DiagnosticsStore(fileURL: url)
        for _ in 0..<5 {
            await s.append(DiagnosticEvent(type: .inferenceTick, sessionId: "C"))
        }
        await s.clear()
        let events = await s.all()
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRotationKeepsRecentAndPriorEvents() async {
        let url = freshURL()
        // Tiny budget so rotation kicks in fast.
        let s = DiagnosticsStore(fileURL: url, maxBytesPerFile: 256)
        for i in 0..<60 {
            await s.append(DiagnosticEvent(type: .inferenceTick,
                                            sessionId: "R",
                                            message: "tick-\(i)"))
        }
        let all = await s.all()
        XCTAssertGreaterThan(all.count, 0)
        // Sorted ascending by ts; final entry must be the latest tick.
        XCTAssertEqual(all.last?.message, "tick-59")
        // The rotated file should exist (size budget exceeded).
        let rotated = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
    }

    func testRecentLimit() async {
        let url = freshURL()
        let s = DiagnosticsStore(fileURL: url)
        for i in 0..<10 {
            await s.append(DiagnosticEvent(type: .inferenceTick, message: "m-\(i)"))
        }
        let recent = await s.recent(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.last?.message, "m-9")
    }

    func testInMemoryStoreAlsoWorks() async {
        let s = InMemoryDiagnosticsStore()
        await s.append(DiagnosticEvent(type: .appLaunch))
        await s.append(DiagnosticEvent(type: .appForeground))
        let pre = await s.all()
        XCTAssertEqual(pre.count, 2)
        await s.clear()
        let post = await s.all()
        XCTAssertTrue(post.isEmpty)
    }
}
