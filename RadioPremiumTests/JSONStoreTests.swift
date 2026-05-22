//
//  JSONStoreTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class JSONStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    private func tempURL(filename: String = "test") -> URL {
        tempDir.appendingPathComponent("\(filename).json")
    }

    private struct TestModel: Codable, Sendable, Equatable {
        var name: String
        var count: Int
    }

    private static let defaultModel = TestModel(name: "default", count: 0)

    // MARK: - Load

    func testLoad_returnsDefault_whenFileMissing() async {
        let store = JSONStore<TestModel>(url: tempURL(), defaultValue: Self.defaultModel)
        let value = await store.load()
        XCTAssertEqual(value, Self.defaultModel)
    }

    func testLoad_returnsValue_whenFileExists() async throws {
        let store = JSONStore<TestModel>(url: tempURL(), defaultValue: Self.defaultModel)
        let saved = TestModel(name: "saved", count: 42)
        try await store.save(saved)

        let loaded = await store.load()
        XCTAssertEqual(loaded, saved)
    }

    func testLoad_returnsDefault_andDeletesFile_whenJSONCorrupted() async throws {
        let url = tempURL()
        try "this is not json {{ broken".data(using: .utf8)!.write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let store = JSONStore<TestModel>(url: url, defaultValue: Self.defaultModel)
        let loaded = await store.load()

        XCTAssertEqual(loaded, Self.defaultModel)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Archivo corrupto debe borrarse tras recovery."
        )
    }

    // MARK: - Save

    func testSave_writesJSON() async throws {
        let url = tempURL()
        let store = JSONStore<TestModel>(url: url, defaultValue: Self.defaultModel)
        try await store.save(TestModel(name: "test", count: 5))

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "test")
        XCTAssertEqual(json?["count"] as? Int, 5)
    }

    func testSave_overwritesExisting() async throws {
        let store = JSONStore<TestModel>(url: tempURL(), defaultValue: Self.defaultModel)
        try await store.save(TestModel(name: "first", count: 1))
        try await store.save(TestModel(name: "second", count: 2))

        let loaded = await store.load()
        XCTAssertEqual(loaded, TestModel(name: "second", count: 2))
    }

    // MARK: - Reset

    func testReset_deletesFile() async throws {
        let url = tempURL()
        let store = JSONStore<TestModel>(url: url, defaultValue: Self.defaultModel)
        try await store.save(TestModel(name: "x", count: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await store.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReset_idempotent_whenFileMissing() async {
        let url = tempURL()
        let store = JSONStore<TestModel>(url: url, defaultValue: Self.defaultModel)
        await store.reset()  // no debe lanzar
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - AppSettings roundtrip (modelo real del proyecto)

    func testAppSettingsRoundtrip() async throws {
        let store = JSONStore<AppSettings>(
            url: tempURL(filename: "settings"),
            defaultValue: .default
        )
        var settings = AppSettings.default
        settings.volume = 0.5
        settings.captureSeconds = 15
        settings.defaultCountryCode = "ES"

        try await store.save(settings)
        let loaded = await store.load()
        XCTAssertEqual(loaded, settings)
    }

    func testAppSettingsLoadDefault_whenFileMissing() async {
        let store = JSONStore<AppSettings>(
            url: tempURL(filename: "settings-missing"),
            defaultValue: .default
        )
        let loaded = await store.load()
        XCTAssertEqual(loaded, AppSettings.default)
    }

    // MARK: - List of items

    func testHistoryRoundtrip_emptyAndPopulated() async throws {
        let store = JSONStore<[IdentifiedTrackHistory]>(
            url: tempURL(filename: "history"),
            defaultValue: []
        )

        let empty = await store.load()
        XCTAssertEqual(empty, [])

        let entry = IdentifiedTrackHistory(
            track: Track(title: "Test Song", artist: "Test Artist"),
            stationName: "Test Radio"
        )
        try await store.save([entry])

        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.track.title, "Test Song")
        XCTAssertEqual(loaded.first?.stationName, "Test Radio")
    }
}
