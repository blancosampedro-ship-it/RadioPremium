//
//  RecentStationsStoreTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class RecentStationsStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: RecentStationsStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("recent-stations.json")
        store = RecentStationsStore(url: url)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        store = nil
        tempDir = nil
    }

    // MARK: - Helpers

    private func makeStation(id: String, name: String = "Test Radio") -> Station {
        Station(
            id: id,
            name: name,
            streamURL: URL(string: "https://example.com/stream"),
            countryCode: "ES",
            codec: "MP3",
            bitrate: 128
        )
    }

    // MARK: - Empty / load

    func testLoad_returnsEmpty_whenFileMissing() async {
        let recents = await store.load()
        XCTAssertEqual(recents, [])
    }

    func testLastPlayed_nilWhenEmpty() async {
        let last = await store.lastPlayed()
        XCTAssertNil(last)
    }

    // MARK: - recordPlayed básico

    func testRecordPlayed_addsStation() async throws {
        let recorded = try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())
        XCTAssertTrue(recorded)

        let recents = await store.load()
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.station.id, "a")
    }

    func testLastPlayed_isFirstPosition() async throws {
        try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())
        try await store.recordPlayed(makeStation(id: "b"), sessionID: UUID())

        let last = await store.lastPlayed()
        XCTAssertEqual(last?.id, "b", "La última reproducida debe ser la primera posición")
    }

    // MARK: - Una vez por sesión

    func testRecordPlayed_sameSession_recordsOnlyOnce() async throws {
        let session = UUID()
        let first = try await store.recordPlayed(makeStation(id: "a"), sessionID: session)
        let second = try await store.recordPlayed(makeStation(id: "a"), sessionID: session)
        let third = try await store.recordPlayed(makeStation(id: "a"), sessionID: session)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "Rebuffering de la misma sesión NO debe re-registrar")
        XCTAssertFalse(third)

        let recents = await store.load()
        XCTAssertEqual(recents.count, 1)
    }

    func testRecordPlayed_sameSession_doesNotBumpDate() async throws {
        let session = UUID()
        try await store.recordPlayed(makeStation(id: "a"), sessionID: session)
        let dateAfterFirst = await store.load().first!.lastPlayedAt

        try await store.recordPlayed(makeStation(id: "a"), sessionID: session)
        let dateAfterSecond = await store.load().first!.lastPlayedAt

        XCTAssertEqual(dateAfterFirst, dateAfterSecond, "La misma sesión no debe tocar lastPlayedAt")
    }

    func testRecordPlayed_newSession_recordsAgain() async throws {
        try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())
        let again = try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())
        XCTAssertTrue(again, "Una sesión nueva SÍ registra")
    }

    // MARK: - Dedup por emisora

    func testRecordPlayed_duplicateStation_movesToTop_noDuplicate() async throws {
        try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())
        try await store.recordPlayed(makeStation(id: "b"), sessionID: UUID())
        try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())

        let recents = await store.load()
        XCTAssertEqual(recents.count, 2, "Re-reproducir no duplica")
        XCTAssertEqual(recents.first?.station.id, "a", "Re-reproducir sube arriba")
    }

    // MARK: - Cap 10

    func testRecordPlayed_capsAtTen() async throws {
        for i in 0..<15 {
            try await store.recordPlayed(makeStation(id: "s\(i)"), sessionID: UUID())
        }

        let recents = await store.load()
        XCTAssertEqual(recents.count, RecentStationsStore.maxEntries)
        XCTAssertEqual(recents.first?.station.id, "s14", "La más reciente sobrevive")
        XCTAssertFalse(recents.contains { $0.station.id == "s0" }, "La más antigua se descarta")
    }

    // MARK: - remove / clear

    func testRemove_deletesOnlyThatStation() async throws {
        try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())
        try await store.recordPlayed(makeStation(id: "b"), sessionID: UUID())

        try await store.remove(stationId: "a")

        let recents = await store.load()
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.station.id, "b")
    }

    func testRemove_nonexistent_isNoop() async throws {
        try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())
        try await store.remove(stationId: "zzz")
        let recents = await store.load()
        XCTAssertEqual(recents.count, 1)
    }

    func testClear_emptiesAndAllowsReRecording() async throws {
        let session = UUID()
        try await store.recordPlayed(makeStation(id: "a"), sessionID: session)
        await store.clear()

        let recents = await store.load()
        XCTAssertEqual(recents, [])

        // Tras clear, incluso la misma sesión puede volver a registrar
        // (el tracking de sesión también se resetea).
        let recorded = try await store.recordPlayed(makeStation(id: "a"), sessionID: session)
        XCTAssertTrue(recorded)
    }

    // MARK: - Persistencia entre instancias

    func testPersistence_survivesReload() async throws {
        try await store.recordPlayed(makeStation(id: "a"), sessionID: UUID())

        let url = tempDir.appendingPathComponent("recent-stations.json")
        let second = RecentStationsStore(url: url)
        let recents = await second.load()

        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.station.id, "a")
    }
}
