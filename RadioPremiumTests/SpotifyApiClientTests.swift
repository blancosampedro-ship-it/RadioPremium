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

    func testFindTrack_buildsTrackArtistQuery() async throws {
        setOKHandler(body: Self.emptyTracksJSON)
        _ = try await client.findTrack(title: "Bohemian Rhapsody", artist: "Queen")

        let q = MockURLProtocol.lastRequest?.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == "q" }?.value
        XCTAssertEqual(q, "track:Bohemian Rhapsody artist:Queen")
    }

    func testFindTrack_stripsQuotesFromInput() async throws {
        // Input con comillas se sanea para evitar romper la query Spotify.
        setOKHandler(body: Self.emptyTracksJSON)
        _ = try await client.findTrack(title: "Bo\"hemian", artist: "Qu\"een")

        let q = MockURLProtocol.lastRequest?.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == "q" }?.value
        XCTAssertEqual(q, "track:Bohemian artist:Queen")
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
