//
//  IdentifiedTracksRepositoryTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class IdentifiedTracksRepositoryTests: XCTestCase {

    private var tempDir: URL!
    private var repo: IdentifiedTracksRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("identified-tracks.json")
        repo = IdentifiedTracksRepository(url: url)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        repo = nil
        tempDir = nil
    }

    // MARK: - Empty / load

    func testLoad_returnsEmpty_whenFileMissing() async {
        let history = await repo.load()
        XCTAssertEqual(history, [])
    }

    // MARK: - Append + load roundtrip

    func testAppend_singleEntry_roundtrip() async throws {
        let entry = IdentifiedTrackHistory(
            track: Track(title: "Song A", artist: "Artist A"),
            stationName: "Radio A"
        )
        try await repo.append(entry)

        let history = await repo.load()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.track.title, "Song A")
        XCTAssertEqual(history.first?.stationName, "Radio A")
    }

    func testAppend_multipleEntries_returnsNewestFirst() async throws {
        // Crea con timestamps explícitos para que el orden sea determinista
        let now = Date()
        let entry1 = IdentifiedTrackHistory(
            track: Track(title: "Old", artist: "X"),
            identifiedAt: now.addingTimeInterval(-100)
        )
        let entry2 = IdentifiedTrackHistory(
            track: Track(title: "New", artist: "X"),
            identifiedAt: now
        )
        let entry3 = IdentifiedTrackHistory(
            track: Track(title: "Middle", artist: "X"),
            identifiedAt: now.addingTimeInterval(-50)
        )

        try await repo.append(entry1)
        try await repo.append(entry2)
        try await repo.append(entry3)

        let history = await repo.load()
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0].track.title, "New", "Más reciente primero")
        XCTAssertEqual(history[1].track.title, "Middle")
        XCTAssertEqual(history[2].track.title, "Old", "Más antiguo último")
    }

    // MARK: - Clear

    func testClear_removesAllEntries() async throws {
        try await repo.append(IdentifiedTrackHistory(track: Track(title: "A", artist: "X")))
        try await repo.append(IdentifiedTrackHistory(track: Track(title: "B", artist: "Y")))
        let beforeClear = await repo.load()
        XCTAssertEqual(beforeClear.count, 2)

        await repo.clear()
        let afterClear = await repo.load()
        XCTAssertEqual(afterClear, [])
    }

    func testClear_idempotent_whenEmpty() async {
        await repo.clear()  // no throw
        let history = await repo.load()
        XCTAssertEqual(history, [])
    }

    // MARK: - Persistence across instances

    func testAppend_persistsAcrossInstances() async throws {
        let url = tempDir.appendingPathComponent("identified-tracks.json")

        try await repo.append(IdentifiedTrackHistory(track: Track(title: "Persisted", artist: "X")))

        // Nuevo repo apuntando al mismo archivo
        let repo2 = IdentifiedTracksRepository(url: url)
        let history = await repo2.load()

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.track.title, "Persisted")
    }
}
