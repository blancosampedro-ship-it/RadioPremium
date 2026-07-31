//
//  RadioBrowserFailoverTests.swift
//  RadioPremiumTests
//
//  Cubre la resiliencia añadida a RadioBrowserClient: failover entre espejos
//  y reintento con backoff.
//
//  Contexto: los espejos de Radio Browser devuelven `503 no available server`
//  con frecuencia. Antes ese 503 llegaba crudo a la UI y el usuario tenía que
//  pulsar "Reintentar" a mano.
//

import XCTest
@testable import RadioPremium

// MARK: - Helper: registro de hosts golpeados

/// Registra qué host recibió cada petición, en orden.
/// Thread-safe: el handler de MockURLProtocol corre en el hilo de URLSession.
private final class HostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []

    func record(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        _hosts.append(host)
    }

    var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _hosts
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _hosts.count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _hosts = []
    }
}

final class RadioBrowserFailoverTests: XCTestCase {

    private static let mirrors = [
        URL(string: "https://mirror1.test/json")!,
        URL(string: "https://mirror2.test/json")!,
        URL(string: "https://mirror3.test/json")!
    ]

    private static let stationJSON = """
    [{
        "stationuuid": "ok-1",
        "name": "Emisora Viva",
        "url": "http://stream.example.com",
        "url_resolved": "http://stream.example.com",
        "tags": "test",
        "country": "Spain",
        "countrycode": "ES",
        "language": "spanish",
        "votes": 10,
        "lastcheckok": 1
    }]
    """

    private var okBody: Data { Self.stationJSON.data(using: .utf8)! }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient(
        baseURLs: [URL] = RadioBrowserFailoverTests.mirrors,
        retryRounds: Int = 2
    ) -> RadioBrowserClient {
        RadioBrowserClient(
            http: HTTPClient(session: URLSession.mocked()),
            baseURLs: baseURLs,
            userAgent: "TestAgent/1.0",
            retryRounds: retryRounds
        )
    }

    private func ok(_ request: URLRequest, body: Data) -> (HTTPURLResponse, Data?) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    private func status(_ code: Int, _ request: URLRequest, body: String = "") -> (HTTPURLResponse, Data?) {
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        return (response, body.data(using: .utf8))
    }

    // MARK: - Failover

    func testFailover_usesNextMirror_when503() async throws {
        let recorder = HostRecorder()
        let body = okBody

        MockURLProtocol.setHandler { [weak self] request in
            guard let self else { throw URLError(.unknown) }
            let host = request.url?.host ?? "?"
            recorder.record(host)
            if host == "mirror1.test" {
                // El error real que devuelve el proxy de Radio Browser.
                return self.status(503, request, body: "no available server")
            }
            return self.ok(request, body: body)
        }

        let client = makeClient()
        let stations = try await client.popular(limit: 5)

        XCTAssertEqual(stations.count, 1, "Debe devolver los datos del espejo sano.")
        XCTAssertEqual(stations.first?.id, "ok-1")
        XCTAssertEqual(
            recorder.hosts,
            ["mirror1.test", "mirror2.test"],
            "Ante un 503 debe saltar al siguiente espejo inmediatamente, sin reintentar el caído."
        )
    }

    func testFailover_survivesNetworkError() async throws {
        let recorder = HostRecorder()
        let body = okBody

        MockURLProtocol.setHandler { [weak self] request in
            guard let self else { throw URLError(.unknown) }
            let host = request.url?.host ?? "?"
            recorder.record(host)
            if host == "mirror1.test" {
                throw URLError(.cannotConnectToHost)
            }
            return self.ok(request, body: body)
        }

        let stations = try await makeClient().popular(limit: 5)

        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(recorder.hosts, ["mirror1.test", "mirror2.test"])
    }

    func testFailover_isSticky_acrossCalls() async throws {
        let recorder = HostRecorder()
        let body = okBody

        MockURLProtocol.setHandler { [weak self] request in
            guard let self else { throw URLError(.unknown) }
            let host = request.url?.host ?? "?"
            recorder.record(host)
            if host == "mirror1.test" {
                return self.status(503, request, body: "no available server")
            }
            return self.ok(request, body: body)
        }

        let client = makeClient()
        _ = try await client.popular(limit: 5)
        recorder.reset()

        _ = try await client.search(query: "rock")

        XCTAssertEqual(
            recorder.hosts,
            ["mirror2.test"],
            "Tras el failover debe recordar el espejo sano y no volver a golpear el caído."
        )
    }

    func testNoFailover_onNonTransientError() async {
        let recorder = HostRecorder()

        MockURLProtocol.setHandler { [weak self] request in
            guard let self else { throw URLError(.unknown) }
            recorder.record(request.url?.host ?? "?")
            return self.status(404, request)
        }

        do {
            _ = try await makeClient().popular(limit: 5)
            XCTFail("Esperaba throw")
        } catch let error as RadioPremiumError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("Caso de error incorrecto: \(error)")
            }
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Tipo de error incorrecto: \(error)")
        }

        XCTAssertEqual(
            recorder.count, 1,
            "Un 404 fallaría igual en el resto de espejos: no debe malgastar peticiones."
        )
    }

    func testAllMirrorsDown_throwsAfterTryingEachOnce() async {
        let recorder = HostRecorder()

        MockURLProtocol.setHandler { [weak self] request in
            guard let self else { throw URLError(.unknown) }
            recorder.record(request.url?.host ?? "?")
            return self.status(503, request, body: "no available server")
        }

        do {
            _ = try await makeClient(retryRounds: 1).popular(limit: 5)
            XCTFail("Esperaba throw")
        } catch let error as RadioPremiumError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("Caso de error incorrecto: \(error)")
            }
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Tipo de error incorrecto: \(error)")
        }

        XCTAssertEqual(
            recorder.hosts,
            ["mirror1.test", "mirror2.test", "mirror3.test"],
            "Con una sola vuelta debe probar cada espejo exactamente una vez."
        )
    }

    // MARK: - Reintento con backoff

    func testRetry_recoversWhenSingleMirrorRecovers() async throws {
        let recorder = HostRecorder()
        let body = okBody

        MockURLProtocol.setHandler { [weak self] request in
            guard let self else { throw URLError(.unknown) }
            let isFirstAttempt = recorder.count == 0
            recorder.record(request.url?.host ?? "?")
            if isFirstAttempt {
                return self.status(503, request, body: "no available server")
            }
            return self.ok(request, body: body)
        }

        // Un solo espejo: no hay a dónde hacer failover, así que la recuperación
        // solo puede venir del reintento con backoff.
        let client = makeClient(baseURLs: [Self.mirrors[0]], retryRounds: 2)
        let stations = try await client.popular(limit: 5)

        XCTAssertEqual(stations.count, 1, "El reintento debe recuperar el 503 pasajero.")
        XCTAssertEqual(recorder.count, 2)
    }

    // MARK: - Construcción de la lista de espejos

    func testMirrors_configuredHostGoesFirst() {
        let configured = URL(string: "https://de1.api.radio-browser.info/json")!
        let urls = RadioBrowserMirrors.baseURLs(preferring: configured)

        XCTAssertEqual(urls.first, configured, "El servidor de Secrets.plist debe seguir siendo el primero.")
        XCTAssertGreaterThan(urls.count, 1, "Debe añadir espejos de fallback.")
    }

    func testMirrors_deduplicatesConfiguredHost() {
        let configured = URL(string: "https://de1.api.radio-browser.info/json")!
        let urls = RadioBrowserMirrors.baseURLs(preferring: configured)

        let de1Count = urls.filter { $0.host == "de1.api.radio-browser.info" }.count
        XCTAssertEqual(de1Count, 1, "No debe golpear dos veces el mismo servidor por vuelta.")
    }

    func testMirrors_preserveSchemeAndPath() {
        let configured = URL(string: "https://de1.api.radio-browser.info/json")!
        let urls = RadioBrowserMirrors.baseURLs(preferring: configured)

        for url in urls {
            XCTAssertEqual(url.scheme, "https", "Nunca degradar a http: \(url)")
            XCTAssertEqual(url.path, "/json", "El path de la API debe conservarse: \(url)")
        }
    }

    func testMirrors_includeRecommendedAllEntryPoint() {
        let configured = URL(string: "https://de1.api.radio-browser.info/json")!
        let urls = RadioBrowserMirrors.baseURLs(preferring: configured)

        XCTAssertEqual(
            urls[1].host, "all.api.radio-browser.info",
            "El primer fallback debe ser el entry point que recomienda la API."
        )
    }
}
