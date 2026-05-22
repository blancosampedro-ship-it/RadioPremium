//
//  StationTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class StationTests: XCTestCase {

    private var decoder: JSONDecoder { JSONDecoder() }

    // MARK: - Parseo de JSON real de Radio Browser

    func testDecodes_radioBrowserResponse_realFields() throws {
        let json = """
        {
            "stationuuid": "962e6c40-0601-11e8-ae97-52543be04c81",
            "name": "Radio Paradise (Main Mix)",
            "url": "http://stream-tx3.radioparadise.com/aac-320",
            "url_resolved": "http://stream-tx3.radioparadise.com/aac-320",
            "homepage": "https://radioparadise.com/",
            "favicon": "https://radioparadise.com/favicon.ico",
            "tags": "eclectic,music,paradise,rock",
            "country": "United States",
            "countrycode": "US",
            "language": "english",
            "votes": 4283,
            "codec": "AAC",
            "bitrate": 320,
            "lastcheckok": 1
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)

        XCTAssertEqual(station.id, "962e6c40-0601-11e8-ae97-52543be04c81")
        XCTAssertEqual(station.name, "Radio Paradise (Main Mix)")
        XCTAssertEqual(station.streamURL?.absoluteString, "http://stream-tx3.radioparadise.com/aac-320")
        XCTAssertEqual(station.homepage?.absoluteString, "https://radioparadise.com/")
        XCTAssertEqual(station.faviconURL?.absoluteString, "https://radioparadise.com/favicon.ico")
        XCTAssertEqual(station.country, "United States")
        XCTAssertEqual(station.countryCode, "US")
        XCTAssertEqual(station.language, "english")
        XCTAssertEqual(station.tags, ["eclectic", "music", "paradise", "rock"])
        XCTAssertEqual(station.codec, "AAC")
        XCTAssertEqual(station.bitrate, 320)
        XCTAssertEqual(station.votes, 4283)
        XCTAssertTrue(station.isWorking)
    }

    // MARK: - Fallback url_resolved → url

    func testPrefers_urlResolved_over_url() throws {
        let json = """
        {
            "stationuuid": "test",
            "name": "Test",
            "url": "http://primary.example.com/stream",
            "url_resolved": "http://resolved.example.com/stream",
            "tags": ""
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)
        XCTAssertEqual(station.streamURL?.absoluteString, "http://resolved.example.com/stream")
    }

    func testFallbackTo_url_whenResolvedEmpty() throws {
        let json = """
        {
            "stationuuid": "test",
            "name": "Test",
            "url": "http://fallback.example.com/stream",
            "url_resolved": "",
            "tags": ""
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)
        XCTAssertEqual(station.streamURL?.absoluteString, "http://fallback.example.com/stream")
    }

    func testStreamURL_isNil_whenBothEmpty() throws {
        let json = """
        {
            "stationuuid": "test",
            "name": "Test",
            "url": "",
            "url_resolved": "",
            "tags": ""
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)
        XCTAssertNil(station.streamURL)
    }

    // MARK: - Optional / missing fields

    func testDecodes_missingOptionalFields() throws {
        let json = """
        {
            "stationuuid": "minimal",
            "name": "Minimal Station",
            "url": "http://stream.example.com/a",
            "tags": ""
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)
        XCTAssertEqual(station.id, "minimal")
        XCTAssertNil(station.country)
        XCTAssertNil(station.codec)
        XCTAssertNil(station.bitrate)
        XCTAssertNil(station.votes)
        XCTAssertNil(station.homepage)
        XCTAssertNil(station.faviconURL)
        XCTAssertEqual(station.tags, [])
        XCTAssertTrue(station.isWorking, "isWorking debe ser true por defecto si lastcheckok no viene")
    }

    // MARK: - lastcheckok

    func testIsWorking_falseWhenLastCheckOkZero() throws {
        let json = """
        {
            "stationuuid": "broken",
            "name": "Broken",
            "url": "http://broken.example.com/",
            "tags": "",
            "lastcheckok": 0
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)
        XCTAssertFalse(station.isWorking)
    }

    // MARK: - Tags whitespace

    func testTagsWhitespace_trimmed() throws {
        let json = """
        {
            "stationuuid": "test",
            "name": "Test",
            "url": "http://x",
            "tags": "rock , pop,  jazz  "
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)
        XCTAssertEqual(station.tags, ["rock", "pop", "jazz"])
    }

    func testTagsEmptyString_emptyArray() throws {
        let json = """
        {
            "stationuuid": "test",
            "name": "Test",
            "url": "http://x",
            "tags": ""
        }
        """.data(using: .utf8)!

        let station = try decoder.decode(Station.self, from: json)
        XCTAssertEqual(station.tags, [])
    }

    // MARK: - Codable roundtrip

    func testCodableRoundtrip() throws {
        let original = Station(
            id: "abc-123",
            name: "Test Radio",
            streamURL: URL(string: "http://test.example.com/stream"),
            homepage: URL(string: "http://test.example.com"),
            faviconURL: nil,
            country: "Spain",
            countryCode: "ES",
            language: "spanish",
            tags: ["rock", "pop"],
            codec: "MP3",
            bitrate: 128,
            votes: 100,
            isWorking: true
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(Station.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundtrip_brokenStation() throws {
        let original = Station(
            id: "xyz",
            name: "Broken",
            streamURL: nil,
            tags: [],
            isWorking: false
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(Station.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.isWorking)
    }

    // MARK: - Identifiable

    func testIdentifiable_idMatchesStationUuid() {
        let station = Station(id: "uuid-123", name: "Test")
        XCTAssertEqual(station.id, "uuid-123")
    }
}
