//
//  SpotifyApiClientTests.swift
//  RadioPremiumTests
//

import XCTest
@testable import RadioPremium

final class SpotifyApiClientTests: XCTestCase {

    private var http: HTTPClient!
    private var auth: SpotifyAuthClient!
    private var keychain: KeychainStore!
    private var client: SpotifyApiClient!

    private let testKeychainService = "com.blancosampedro.RadioPremium.spotify.tests"

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        http = HTTPClient(session: URLSession.mocked())
        keychain = KeychainStore(service: testKeychainService)
        try keychain.clearAll()

        auth = SpotifyAuthClient(
            http: http,
            keychain: keychain,
            clientId: "test-client",
            redirectUri: "radiopremium://callback",
            scopes: ["test-scope"]
        )

        // Pre-cargar tokens válidos para que getValidAccessToken no dispare auth
        let formatter = ISO8601DateFormatter()
        try keychain.set("test-access-token", for: "accessToken")
        try keychain.set("test-refresh-token", for: "refreshToken")
        try keychain.set("Bearer", for: "tokenType")
        try keychain.set(formatter.string(from: Date().addingTimeInterval(3600)), for: "expiresAt")
        try keychain.set("test-scope", for: "scope")

        client = SpotifyApiClient(http: http, auth: auth)
    }

    override func tearDown() async throws {
        try? keychain.clearAll()
        MockURLProtocol.reset()
        client = nil
        auth = nil
        keychain = nil
        http = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func setOKHandler(body: String) {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8))
        }
    }

    // MARK: - Auth header

    func testAllRequests_includeBearerHeader() async throws {
        setOKHandler(body: """
        {"id":"u1","display_name":"Test"}
        """)

        _ = try await client.currentUser()

        let auth = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer test-access-token")
    }

    // MARK: - currentUser

    func testCurrentUser_parsesResponse() async throws {
        setOKHandler(body: """
        {
            "id": "spotify-user-123",
            "display_name": "Test User",
            "email": "test@example.com",
            "country": "ES",
            "product": "premium",
            "uri": "spotify:user:spotify-user-123"
        }
        """)

        let user = try await client.currentUser()
        XCTAssertEqual(user.id, "spotify-user-123")
        XCTAssertEqual(user.displayName, "Test User")
        XCTAssertEqual(user.country, "ES")
        XCTAssertEqual(user.product, "premium")
    }

    func testCurrentUser_callsCorrectEndpoint() async throws {
        setOKHandler(body: """
        {"id":"u1"}
        """)

        _ = try await client.currentUser()

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/me")
    }

    // MARK: - Search by ISRC

    func testFindTrackByISRC_buildsCorrectQuery() async throws {
        setOKHandler(body: Self.emptyTracksJSON)
        _ = try await client.findTrackByISRC("GBUM71029604")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/v1/search")

        let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == "q" }?.value
        XCTAssertEqual(q, "isrc:GBUM71029604")

        let type = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == "type" }?.value
        XCTAssertEqual(type, "track")
    }

    func testFindTrackByISRC_returnsTrack() async throws {
        setOKHandler(body: Self.singleTrackSearchJSON)
        let track = try await client.findTrackByISRC("any")
        XCTAssertNotNil(track)
        XCTAssertEqual(track?.id, "track123")
        XCTAssertEqual(track?.uri, "spotify:track:track123")
        XCTAssertEqual(track?.primaryArtist, "Queen")
    }

    func testFindTrackByISRC_returnsNilOnNoMatch() async throws {
        setOKHandler(body: Self.emptyTracksJSON)
        let track = try await client.findTrackByISRC("DOES-NOT-EXIST")
        XCTAssertNil(track)
    }

    // MARK: - Search by title+artist

    func testFindTrack_buildsQuotedTrackArtistQuery() async throws {
        setOKHandler(body: Self.emptyTracksJSON)
        _ = try await client.findTrack(title: "Bohemian Rhapsody", artist: "Queen")

        let q = MockURLProtocol.lastRequest?.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == "q" }?.value
        // Los valores DEBEN ir entrecomillados: sin comillas, Spotify aplica el
        // filtro solo a la palabra siguiente y `track:Bohemian Rhapsody` acaba
        // preguntando por una canción llamada "Bohemian".
        XCTAssertEqual(q, "track:\"Bohemian Rhapsody\" artist:\"Queen\"")
    }

    func testFindTrack_stripsQuotesFromInput() async throws {
        // Input con comillas se sanea para no romper el entrecomillado.
        setOKHandler(body: Self.emptyTracksJSON)
        _ = try await client.findTrack(title: "Bo\"hemian", artist: "Qu\"een")

        let q = MockURLProtocol.lastRequest?.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == "q" }?.value
        XCTAssertEqual(q, "track:\"Bohemian\" artist:\"Queen\"")
    }

    func testFindTrack_returnsFirstResult() async throws {
        // Confiamos en el ranking de Spotify: tomamos el primero.
        let body = """
        {
            "tracks": {
                "items": [
                    {
                        "id": "first",
                        "name": "Bohemian Rhapsody",
                        "artists": [{"name": "Queen"}],
                        "uri": "spotify:track:first"
                    },
                    {
                        "id": "second",
                        "name": "Bohemian Rhapsody Live",
                        "artists": [{"name": "Queen"}],
                        "uri": "spotify:track:second"
                    }
                ]
            }
        }
        """
        setOKHandler(body: body)

        let track = try await client.findTrack(title: "Bohemian Rhapsody", artist: "Queen")
        XCTAssertEqual(track?.id, "first")
    }

    // MARK: - Playlists

    /// REGRESSION: URL.appendingPathComponent("/path?q=x") URL-encoda el `?` a
    /// `%3F` rompiendo la query. Spotify responde 404 "Service not found".
    /// Este test verifica que paths con query string se construyen correctamente.
    func testUserPlaylists_buildsURLWithQueryString_notUrlEncoded() async throws {
        setOKHandler(body: """
        {"items":[],"total":0,"limit":50,"offset":0}
        """)

        _ = try await client.userPlaylists()

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/v1/me/playlists",
                       "Path no debe contener `?` ni `limit=50`. Actual path: \(url?.path ?? "nil")")
        XCTAssertEqual(url?.query, "limit=50",
                       "Query string debe ir separada del path. Actual query: \(url?.query ?? "nil")")
        XCTAssertFalse(
            url?.absoluteString.contains("%3F") ?? false,
            "URL no debe contener `%3F` (signo `?` URL-encoded). Actual: \(url?.absoluteString ?? "nil")"
        )
    }

    func testTrackUrisInPlaylist_buildsURLWithQueryString_notUrlEncoded() async throws {
        setOKHandler(body: """
        {"items":[]}
        """)

        _ = try await client.trackUrisInPlaylist("playlist123")

        let url = MockURLProtocol.lastRequest?.url
        XCTAssertEqual(url?.path, "/v1/playlists/playlist123/tracks")
        XCTAssertEqual(url?.query, "limit=100")
    }

    func testUserPlaylists_returnsList() async throws {
        let body = """
        {
            "items": [
                {"id":"p1","name":"Radio Likes","uri":"spotify:playlist:p1"},
                {"id":"p2","name":"Other","uri":"spotify:playlist:p2"}
            ],
            "total": 2,
            "limit": 50,
            "offset": 0
        }
        """
        setOKHandler(body: body)

        let playlists = try await client.userPlaylists()
        XCTAssertEqual(playlists.count, 2)
        XCTAssertEqual(playlists[0].name, "Radio Likes")
    }

    // MARK: - addTrackToPlaylist (dedup)

    func testAddTrackToPlaylist_alreadyPresent_returnsAlreadyPresent() async throws {
        // Mock: la playlist ya contiene el URI que vamos a añadir.
        var calls = 0
        MockURLProtocol.setHandler { request in
            calls += 1
            let body: String
            if request.url?.path.contains("/tracks") == true && request.httpMethod == "GET" {
                body = """
                {
                    "items": [
                        {"track": {"id":"t1","name":"X","artists":[{"name":"A"}],"uri":"spotify:track:already-in"}}
                    ]
                }
                """
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8))
        }

        let outcome = try await client.addTrackToPlaylist(
            playlistId: "p1",
            trackUri: "spotify:track:already-in"
        )

        XCTAssertEqual(outcome, .alreadyPresent)
    }

    // El path de "401 al recibir + retry" es defense-in-depth contra tokens
    // revocados server-side. Difícil de mockear limpiamente sin el proactive
    // refresh interfiriendo. La cobertura del refresh-on-expiry está en
    // SpotifyAuthClientTests.testGetValidAccessToken_refreshesWhenExpired.

    // MARK: - Resolución del track (el ID de ACRCloud primero)

    /// Registra los paths golpeados, para verificar QUÉ vía se usó.
    private final class PathRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        func record(_ path: String) { lock.lock(); defer { lock.unlock() }; _paths.append(path) }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    }

    private static let trackByIdJSON = """
    {
        "id": "35nt3SIMscp0VqsVkBkawZ",
        "name": "Sing It Back - (I Feel Love)",
        "artists": [{"name": "Kevin McKay"}],
        "uri": "spotify:track:35nt3SIMscp0VqsVkBkawZ"
    }
    """

    /// El caso real del usuario: ACRCloud da el ID, el título NO coincide con el
    /// de Spotify ("(Extended Feel Love Mix)" vs "- (I Feel Love)"). Antes se
    /// ignoraba el ID y la búsqueda por texto devolvía vacío → "no encontrada".
    func testFindTrackUri_usesAcrCloudSpotifyId_withoutSearching() async throws {
        let recorder = PathRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request.url?.path ?? "?")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.trackByIdJSON.data(using: .utf8))
        }

        let track = Track(
            title: "Sing It Back (Extended Feel Love Mix)",
            artist: "Kevin McKay",
            spotifyId: "35nt3SIMscp0VqsVkBkawZ"
        )
        let uri = try await client.findTrackUri(for: track)

        XCTAssertEqual(uri, "spotify:track:35nt3SIMscp0VqsVkBkawZ")
        XCTAssertEqual(
            recorder.paths, ["/v1/tracks/35nt3SIMscp0VqsVkBkawZ"],
            "Con ID de ACRCloud debe ir directo al track y NO tocar /v1/search."
        )
    }

    func testFindTrackUri_fallsBackToSearch_whenAcrCloudIdIsDead() async throws {
        let recorder = PathRecorder()
        MockURLProtocol.setHandler { request in
            let path = request.url?.path ?? "?"
            recorder.record(path)
            if path.hasPrefix("/v1/tracks/") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, nil)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.singleTrackSearchJSON.data(using: .utf8))
        }

        let track = Track(title: "Bohemian Rhapsody", artist: "Queen", spotifyId: "id-muerto")
        let uri = try await client.findTrackUri(for: track)

        XCTAssertEqual(uri, "spotify:track:track123")
        XCTAssertTrue(recorder.paths.contains("/v1/tracks/id-muerto"))
        XCTAssertTrue(recorder.paths.contains("/v1/search"), "Un ID muerto no debe abortar: sigue con la búsqueda.")
    }

    func testFindTrackUri_fallsBackToFreeText_whenFieldSearchFails() async throws {
        let recorder = PathRecorder()
        let queries = PathRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request.url?.path ?? "?")
            let q = request.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "q" }?.value ?? ""
            queries.record(q)
            // La búsqueda con filtros devuelve vacío; la de texto libre acierta.
            let body = q.contains("track:") ? Self.emptyTracksJSON : Self.singleTrackSearchJSON
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8))
        }

        let track = Track(title: "Sing It Back (Extended Feel Love Mix)", artist: "Kevin McKay, Someone Else")
        let uri = try await client.findTrackUri(for: track)

        XCTAssertEqual(uri, "spotify:track:track123")
        XCTAssertEqual(
            queries.paths.last, "Sing It Back Kevin McKay",
            "El último intento debe ser texto libre: título sin sufijo + artista principal."
        )
    }

    func testFindTrackUri_throwsNotFound_whenNothingMatches() async {
        setOKHandler(body: Self.emptyTracksJSON)
        let track = Track(title: "Cancion Inexistente", artist: "Nadie")

        do {
            _ = try await client.findTrackUri(for: track)
            XCTFail("Esperaba spotifyTrackNotFound")
        } catch RadioPremiumError.spotifyTrackNotFound(let query) {
            XCTAssertEqual(query, "Nadie — Cancion Inexistente")
        } catch {
            XCTFail("Error incorrecto: \(error)")
        }
    }

    // MARK: - Normalización para búsqueda

    func testSearchableTitle_stripsVersionSuffixes() {
        XCTAssertEqual(SpotifyApiClient.searchableTitle("Sing It Back (Extended Feel Love Mix)"), "Sing It Back")
        XCTAssertEqual(
            SpotifyApiClient.searchableTitle("Spotlight (feat. Sarah Ikumu) [Mousse T. Extended Shizzle Mix]"),
            "Spotlight"
        )
        XCTAssertEqual(SpotifyApiClient.searchableTitle("Sing It Back - Radio Edit"), "Sing It Back")
        XCTAssertEqual(SpotifyApiClient.searchableTitle("Icarus"), "Icarus", "Un título limpio no debe tocarse.")
        XCTAssertEqual(
            SpotifyApiClient.searchableTitle("(Everything I Do) I Do It For You"),
            "I Do It For You",
            "Si queda texto tras quitar el paréntesis, se usa ese."
        )
        XCTAssertEqual(
            SpotifyApiClient.searchableTitle("(Reprise)"), "(Reprise)",
            "Si quitarlo dejaría el título vacío, se conserva el original."
        )
    }

    func testPrimaryArtist_takesFirstCredit() {
        XCTAssertEqual(SpotifyApiClient.primaryArtist("S.A.M., Sarah Ikumu"), "S.A.M.")
        XCTAssertEqual(SpotifyApiClient.primaryArtist("Majed/Luna Orbit/Master Produções Remix"), "Majed")
        XCTAssertEqual(SpotifyApiClient.primaryArtist("Stefano Pain feat. Andrea Serratore"), "Stefano Pain")
        XCTAssertEqual(SpotifyApiClient.primaryArtist("Queen"), "Queen")
    }

    // MARK: - Fixtures

    private static let emptyTracksJSON = """
    {"tracks":{"items":[],"total":0,"limit":1,"offset":0}}
    """

    private static let singleTrackSearchJSON = """
    {
        "tracks": {
            "items": [
                {
                    "id": "track123",
                    "name": "Bohemian Rhapsody",
                    "artists": [{"name": "Queen", "id": "art1", "uri": "spotify:artist:art1"}],
                    "album": {
                        "id": "alb1",
                        "name": "A Night at the Opera",
                        "release_date": "1975-10-31"
                    },
                    "uri": "spotify:track:track123",
                    "external_ids": {"isrc": "GBUM71029604"},
                    "duration_ms": 354320,
                    "explicit": false
                }
            ],
            "total": 1,
            "limit": 1,
            "offset": 0
        }
    }
    """
}
