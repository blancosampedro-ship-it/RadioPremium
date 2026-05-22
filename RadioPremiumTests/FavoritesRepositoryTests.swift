//
//  FavoritesRepositoryTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class FavoritesRepositoryTests: XCTestCase {

    private var tempDir: URL!
    private var repo: FavoritesRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("favorites.json")
        repo = FavoritesRepository(url: url)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        repo = nil
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
        let favorites = await repo.load()
        XCTAssertEqual(favorites, [])
    }

    func testIsFavorite_falseWhenEmpty() async {
        let result = await repo.isFavorite(stationId: "any")
        XCTAssertFalse(result)
    }

    // MARK: - Add

    func testAdd_storesStation() async throws {
        let station = makeStation(id: "s1", name: "Radio 1")
        let added = try await repo.add(station)

        XCTAssertTrue(added)
        let favorites = await repo.load()
        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites[0].station.id, "s1")
        XCTAssertEqual(favorites[0].station.name, "Radio 1")
    }

    func testAdd_idempotent_whenAlreadyFavorite() async throws {
        let station = makeStation(id: "s1")
        let firstAdd = try await repo.add(station)
        let secondAdd = try await repo.add(station)

        XCTAssertTrue(firstAdd)
        XCTAssertFalse(secondAdd, "Add idempotente: si ya está, devuelve false")

        let favorites = await repo.load()
        XCTAssertEqual(favorites.count, 1, "No debe duplicar")
    }

    // MARK: - Remove

    func testRemove_removesStation() async throws {
        let station = makeStation(id: "s1")
        try await repo.add(station)

        let removed = try await repo.remove(stationId: "s1")
        XCTAssertTrue(removed)

        let favorites = await repo.load()
        XCTAssertTrue(favorites.isEmpty)
    }

    func testRemove_idempotent_whenNotPresent() async throws {
        let removed = try await repo.remove(stationId: "non-existent")
        XCTAssertFalse(removed, "Remove idempotente: si no estaba, devuelve false")
    }

    // MARK: - isFavorite

    func testIsFavorite_trueAfterAdd() async throws {
        let station = makeStation(id: "s1")
        try await repo.add(station)

        let isFav = await repo.isFavorite(stationId: "s1")
        XCTAssertTrue(isFav)
    }

    func testIsFavorite_falseAfterRemove() async throws {
        let station = makeStation(id: "s1")
        try await repo.add(station)
        try await repo.remove(stationId: "s1")

        let isFav = await repo.isFavorite(stationId: "s1")
        XCTAssertFalse(isFav)
    }

    // MARK: - Toggle

    func testToggle_addsWhenNotPresent() async throws {
        let station = makeStation(id: "s1")
        let result = try await repo.toggle(station)

        XCTAssertTrue(result, "Toggle devuelve true al añadir")
        let favorites = await repo.load()
        XCTAssertEqual(favorites.count, 1)
    }

    func testToggle_removesWhenPresent() async throws {
        let station = makeStation(id: "s1")
        try await repo.add(station)

        let result = try await repo.toggle(station)
        XCTAssertFalse(result, "Toggle devuelve false al quitar")

        let favorites = await repo.load()
        XCTAssertTrue(favorites.isEmpty)
    }

    // MARK: - Order

    func testLoad_returnsMostRecentFirst() async throws {
        // Añadimos 3 con pequeñas pausas para que `addedAt` sea distinto.
        let s1 = makeStation(id: "s1", name: "Old")
        try await repo.add(s1)
        try await Task.sleep(for: .milliseconds(10))

        let s2 = makeStation(id: "s2", name: "Middle")
        try await repo.add(s2)
        try await Task.sleep(for: .milliseconds(10))

        let s3 = makeStation(id: "s3", name: "New")
        try await repo.add(s3)

        let favorites = await repo.load()
        XCTAssertEqual(favorites.count, 3)
        XCTAssertEqual(favorites[0].station.name, "New", "Más reciente primero")
        XCTAssertEqual(favorites[1].station.name, "Middle")
        XCTAssertEqual(favorites[2].station.name, "Old", "Más antiguo último")
    }

    // MARK: - Persistence

    func testAdd_persistsAcrossInstances() async throws {
        let url = tempDir.appendingPathComponent("favorites.json")

        let s = makeStation(id: "s1", name: "Persisted Radio")
        try await repo.add(s)

        // Nuevo repo apuntando al mismo archivo
        let repo2 = FavoritesRepository(url: url)
        let favorites = await repo2.load()

        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites[0].station.id, "s1")
        XCTAssertEqual(favorites[0].station.name, "Persisted Radio")
    }

    // MARK: - Clear

    func testClear_removesAllFavorites() async throws {
        try await repo.add(makeStation(id: "s1"))
        try await repo.add(makeStation(id: "s2"))

        await repo.clear()
        let favorites = await repo.load()
        XCTAssertEqual(favorites, [])
    }
}
