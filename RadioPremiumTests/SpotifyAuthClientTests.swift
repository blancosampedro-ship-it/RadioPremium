//
//  SpotifyAuthClientTests.swift
//  RadioPremiumTests
//
//  Tests del flujo de tokens (persistencia + refresh) y la API de auth.
//  El paso de ASWebAuthenticationSession no se puede automatizar — eso queda
//  para smoke test manual de Tanda G2.
//

import XCTest
@testable import RadioPremium

final class SpotifyAuthClientTests: XCTestCase {

    private let testKeychainService = "com.blancosampedro.RadioPremium.spotify.authtests"
    private var http: HTTPClient!
    private var keychain: KeychainStore!
    private var client: SpotifyAuthClient!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        http = HTTPClient(session: URLSession.mocked())
        keychain = KeychainStore(service: testKeychainService)
        try keychain.clearAll()

        client = SpotifyAuthClient(
            http: http,
            keychain: keychain,
            clientId: "test-client",
            redirectUri: "radiopremium://callback",
            scopes: ["scope-a", "scope-b"]
        )
    }

    override func tearDown() async throws {
        try? keychain.clearAll()
        MockURLProtocol.reset()
        client = nil
        keychain = nil
        http = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testIsAuthenticated_falseWhenKeychainEmpty() async {
        let result = await client.isAuthenticated()
        XCTAssertFalse(result)
    }

    func testCurrentTokens_nilWhenKeychainEmpty() async {
        let tokens = await client.currentTokens()
        XCTAssertNil(tokens)
    }

    // MARK: - Token persistence

    func testIsAuthenticated_trueAfterTokensStoredInKeychain() async throws {
        // Simulamos haber pasado por signIn manualmente seteando el Keychain.
        let formatter = ISO8601DateFormatter()
        try keychain.set("test-access", for: "accessToken")
        try keychain.set("test-refresh", for: "refreshToken")
        try keychain.set("Bearer", for: "tokenType")
        try keychain.set(formatter.string(from: Date().addingTimeInterval(3600)), for: "expiresAt")
        try keychain.set("scope-a scope-b", for: "scope")

        let result = await client.isAuthenticated()
        XCTAssertTrue(result)

        let tokens = await client.currentTokens()
        XCTAssertEqual(tokens?.accessToken, "test-access")
        XCTAssertEqual(tokens?.refreshToken, "test-refresh")
        XCTAssertEqual(tokens?.scope, "scope-a scope-b")
    }

    // MARK: - signOut

    func testSignOut_clearsKeychain() async throws {
        let formatter = ISO8601DateFormatter()
        try keychain.set("test-access", for: "accessToken")
        try keychain.set("test-refresh", for: "refreshToken")
        try keychain.set("Bearer", for: "tokenType")
        try keychain.set(formatter.string(from: Date().addingTimeInterval(3600)), for: "expiresAt")
        try keychain.set("scope-a", for: "scope")

        let beforeSignOut = await client.isAuthenticated()
        XCTAssertTrue(beforeSignOut)

        await client.signOut()

        let afterSignOut = await client.isAuthenticated()
        XCTAssertFalse(afterSignOut)
        XCTAssertNil(try keychain.get("accessToken"))
    }

    // MARK: - getValidAccessToken: cached non-expired

    func testGetValidAccessToken_returnsCachedWhenNotExpired() async throws {
        let formatter = ISO8601DateFormatter()
        try keychain.set("cached-token", for: "accessToken")
        try keychain.set("refresh-x", for: "refreshToken")
        try keychain.set("Bearer", for: "tokenType")
        try keychain.set(formatter.string(from: Date().addingTimeInterval(3600)), for: "expiresAt")
        try keychain.set("any", for: "scope")

        let token = try await client.getValidAccessToken()
        XCTAssertEqual(token, "cached-token", "Token no expirado debe devolverse sin red")

        // Verifica que NO hubo request a la red
        XCTAssertNil(MockURLProtocol.lastRequest, "No debería haber llamado a /api/token")
    }

    // MARK: - getValidAccessToken: refresh on expiry

    func testGetValidAccessToken_refreshesWhenExpired() async throws {
        let formatter = ISO8601DateFormatter()
        try keychain.set("old-token", for: "accessToken")
        try keychain.set("refresh-x", for: "refreshToken")
        try keychain.set("Bearer", for: "tokenType")
        try keychain.set(formatter.string(from: Date(timeIntervalSinceNow: -100)), for: "expiresAt")
        try keychain.set("scope-a", for: "scope")

        // Mock /api/token con respuesta que da nuevo access token
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://accounts.spotify.com/api/token")
            let body = """
            {"access_token":"fresh-token","token_type":"Bearer","expires_in":3600,"scope":"scope-a scope-b"}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8))
        }

        let token = try await client.getValidAccessToken()
        XCTAssertEqual(token, "fresh-token")

        // El nuevo token debe estar persistido
        XCTAssertEqual(try keychain.get("accessToken"), "fresh-token")
    }

    func testGetValidAccessToken_signsOutWhenRefreshFails() async throws {
        let formatter = ISO8601DateFormatter()
        try keychain.set("old-token", for: "accessToken")
        try keychain.set("refresh-x", for: "refreshToken")
        try keychain.set("Bearer", for: "tokenType")
        try keychain.set(formatter.string(from: Date(timeIntervalSinceNow: -100)), for: "expiresAt")
        try keychain.set("scope-a", for: "scope")

        // Mock refresh failure
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, """
            {"error":"invalid_grant"}
            """.data(using: .utf8))
        }

        do {
            _ = try await client.getValidAccessToken()
            XCTFail("Expected throw")
        } catch let error as RadioPremiumError {
            guard case .spotifyAuthRequired = error else {
                return XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }

        // Tokens deben haberse limpiado tras el fallo de refresh
        XCTAssertNil(try keychain.get("accessToken"))
    }

    // MARK: - Tokens.isExpired logic

    func testTokensIsExpired_falseWhenInFuture() {
        let tokens = SpotifyTokens(
            accessToken: "x",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "any"
        )
        XCTAssertFalse(tokens.isExpired)
    }

    func testTokensIsExpired_trueWhenInPast() {
        let tokens = SpotifyTokens(
            accessToken: "x",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSinceNow: -10),
            scope: "any"
        )
        XCTAssertTrue(tokens.isExpired)
    }

    func testTokensIsExpired_trueWithinSafetyMargin() {
        // 30s de margen — un token que expira en 10s ya cuenta como expirado
        let tokens = SpotifyTokens(
            accessToken: "x",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(10),
            scope: "any"
        )
        XCTAssertTrue(tokens.isExpired)
    }

    // MARK: - Scopes

    func testHasScopes_emptyScopeStringTreatedAsAll() {
        let tokens = SpotifyTokens(
            accessToken: "x",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3600),
            scope: ""
        )
        XCTAssertTrue(
            tokens.hasScopes(["any-scope"]),
            "Si Spotify no devuelve scope (refresh response), confiamos en que la API hace el check final"
        )
    }

    func testHasScopes_truePartialMatch() {
        let tokens = SpotifyTokens(
            accessToken: "x",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "scope-a scope-b scope-c"
        )
        XCTAssertTrue(tokens.hasScopes(["scope-a", "scope-c"]))
    }

    func testHasScopes_falseWhenMissing() {
        let tokens = SpotifyTokens(
            accessToken: "x",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "scope-a scope-b"
        )
        XCTAssertFalse(tokens.hasScopes(["scope-a", "scope-missing"]))
    }
}
