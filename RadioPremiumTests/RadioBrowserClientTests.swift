//
//  RadioBrowserClientTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class RadioBrowserClientTests: XCTestCase {

    private var client: RadioBrowserClient!
    private let baseURL = URL(string: "https://test.example.com/json")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let http = HTTPClient(session: URLSession.mocked())
        client = RadioBrowserClient(http: http, baseURL: baseURL, userAgent: "TestAgent/1.0")
    }

    override func tearDown() {
        MockURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private static let radioParadiseJSON = """
    {
        "stationuuid": "rp-1",
        "name": "Radio Paradise",
        "url": "http://stream.radioparadise.com",
        "url_resolved": "http://stream.radioparadise.com/aac",
        "homepage": "https://radioparadise.com",
        "favicon": "https://radioparadise.com/favicon.ico",
        "tags": "rock,eclectic",
        "country": "United States",
        "countrycode": "US",
        "language": "english",
        "votes": 4283,
        "codec": "AAC",
        "bitrate": 320,
        "lastcheckok": 1
    }
    """

    private static let cadenaSerJSON = """
    {
        "stationuuid": "ser-1",
        "name": "Cadena SER",
        "url": "http://stream.cadenaser.com",
        "url_resolved": "http://stream.cadenaser.com",
        "tags": "news,spanish",
        "country": "Spain",
        "countrycode": "ES",
        "language": "spanish",
        "votes": 1234,
        "lastcheckok": 1
    }
    """

    private func arrayResponse(_ items: String...) -> Data {
        let body = "[\(items.joined(separator: ","))]"
        return body.data(using: .utf8)!
    }

    private func setOKHandler(body: Data) {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
    }

    // MARK: - Search: URL construction

    func testSearch_buildsCorrectPath() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.search(query: "paradise")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/json/stations/search")
        XCTAssertEqual(url?.host, "test.example.com")
    }

    func testSearch_includesRequiredQueryParams() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.search(query: "rock")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.queryValue(for: "name"), "rock")
        XCTAssertEqual(url?.queryValue(for: "limit"), "50")
        XCTAssertEqual(url?.queryValue(for: "hidebroken"), "true")
        XCTAssertEqual(url?.queryValue(for: "order"), "votes")
        XCTAssertEqual(url?.queryValue(for: "reverse"), "true")
    }

    func testSearch_withCountry_includesCountryCode() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.search(query: "rock", countryCode: "ES")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.queryValue(for: "countrycode"), "ES")
    }

    func testSearch_emptyQuery_omitsNameParam() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.search(query: "")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertNil(url?.queryValue(for: "name"),
                    "Query vacío debe omitir el param name (evita el quirk de Radio Browser).")
    }

    func testSearch_whitespaceOnlyQuery_omitsNameParam() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.search(query: "   \t  ")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertNil(url?.queryValue(for: "name"))
    }

    func testSearch_customLimit() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.search(query: "rock", limit: 10)

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.queryValue(for: "limit"), "10")
    }

    // MARK: - Search: response parsing

    func testSearch_returnsDecodedStations() async throws {
        setOKHandler(body: arrayResponse(Self.radioParadiseJSON, Self.cadenaSerJSON))

        let stations = try await client.search(query: "any")

        XCTAssertEqual(stations.count, 2)
        XCTAssertEqual(stations[0].id, "rp-1")
        XCTAssertEqual(stations[0].name, "Radio Paradise")
        XCTAssertEqual(stations[0].countryCode, "US")
        XCTAssertEqual(stations[1].id, "ser-1")
        XCTAssertEqual(stations[1].countryCode, "ES")
    }

    func testSearch_returnsEmpty_whenAPIReturnsEmpty() async throws {
        setOKHandler(body: arrayResponse())

        let stations = try await client.search(query: "no-such-station")
        XCTAssertEqual(stations, [])
    }

    // MARK: - Popular

    func testPopular_global_callsTopVoteEndpoint() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.popular(limit: 25)

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/json/stations/topvote/25",
                      "Popular global debe usar /stations/topvote/{limit}")
    }

    func testPopular_withCountry_callsByCountryCodeExact() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.popular(countryCode: "ES", limit: 30)

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/json/stations/bycountrycodeexact/ES")
        XCTAssertEqual(url?.queryValue(for: "limit"), "30")
        XCTAssertEqual(url?.queryValue(for: "order"), "votes")
        XCTAssertEqual(url?.queryValue(for: "reverse"), "true")
        XCTAssertEqual(url?.queryValue(for: "hidebroken"), "true")
    }

    func testPopular_emptyCountryCode_treatedAsGlobal() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.popular(countryCode: "  ", limit: 10)

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/json/stations/topvote/10",
                      "countryCode whitespace debe tratarse como global.")
    }

    // MARK: - byUUID

    func testByUUID_callsCorrectEndpoint() async throws {
        setOKHandler(body: arrayResponse(Self.radioParadiseJSON))
        _ = try await client.byUUID("rp-1")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/json/stations/byuuid/rp-1")
    }

    func testByUUID_returnsFirstStation() async throws {
        setOKHandler(body: arrayResponse(Self.radioParadiseJSON))

        let station = try await client.byUUID("rp-1")
        XCTAssertEqual(station?.id, "rp-1")
        XCTAssertEqual(station?.name, "Radio Paradise")
    }

    func testByUUID_returnsNil_whenAPIReturnsEmpty() async throws {
        setOKHandler(body: arrayResponse())

        let station = try await client.byUUID("does-not-exist")
        XCTAssertNil(station)
    }

    // MARK: - Headers

    func testIncludesUserAgentHeader() async throws {
        setOKHandler(body: arrayResponse())
        _ = try await client.search(query: "any")

        XCTAssertEqual(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "User-Agent"),
            "TestAgent/1.0"
        )
    }

    func testUserAgent_defaultIncludesAppIdentifier() async throws {
        // Sin userAgent custom, el default debe contener identificación de la app.
        let http = HTTPClient(session: URLSession.mocked())
        let defaultClient = RadioBrowserClient(http: http, baseURL: baseURL)
        setOKHandler(body: arrayResponse())
        _ = try await defaultClient.search(query: "any")

        let ua = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "User-Agent") ?? ""
        XCTAssertTrue(ua.contains("RadioPremium"), "User-Agent default debe contener 'RadioPremium': \(ua)")
        XCTAssertTrue(ua.contains("macOS"), "User-Agent default debe contener 'macOS': \(ua)")
    }

    // MARK: - Error propagation

    func testSearch_propagatesNetworkError() async {
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.search(query: "any")
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .network = error else {
                return XCTFail("Wrong error case: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testSearch_propagatesHttpStatusError() async {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }

        do {
            _ = try await client.search(query: "any")
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("Wrong error case: \(error)")
            }
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testByUUID_propagatesDecodingError() async {
        MockURLProtocol.setHandler { request in
            let body = "not json at all".data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        do {
            _ = try await client.byUUID("any")
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .decodingFailed = error else {
                return XCTFail("Wrong error case: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}

// MARK: - Test helpers

private extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
