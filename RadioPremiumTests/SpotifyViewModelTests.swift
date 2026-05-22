//
//  SpotifyViewModelTests.swift
//  RadioPremiumTests
//
//  Tests del state machine de SpotifyViewModel con stubs (auth + add).
//

import XCTest
@testable import RadioPremium

@MainActor
final class SpotifyViewModelTests: XCTestCase {

    private var auth: StubSpotifyAuth!
    private var api: StubSpotifyAdding!
    private var vm: SpotifyViewModel!

    override func setUp() async throws {
        try await super.setUp()
        auth = StubSpotifyAuth()
        api = StubSpotifyAdding()
        vm = SpotifyViewModel(auth: auth, api: api)
    }

    override func tearDown() async throws {
        vm.reset()
        vm = nil
        auth = nil
        api = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func waitFor(timeoutMs: Int = 1000, _ condition: @autoclosure () -> Bool) async {
        let stepMs = 5
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(stepMs))
            elapsed += stepMs
        }
    }

    private static let testTrack = Track(
        title: "Test Song",
        artist: "Test Artist",
        album: "Test Album",
        isrc: "TEST00000001"
    )

    private func isSuccessState(_ state: SpotifyState, expecting: SpotifyAddOutcome) -> Bool {
        if case .success(let outcome, _) = state, outcome == expecting { return true }
        return false
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - Authenticated → success

    func testAddToPlaylist_authenticated_success() async {
        auth.isAuthenticatedValue = true
        api.outcome = .added

        vm.addToPlaylist(Self.testTrack)
        await waitFor(isSuccessState(vm.state, expecting: .added))

        guard case .success(.added, let title) = vm.state else {
            return XCTFail("Esperaba .success(.added). Actual: \(vm.state)")
        }
        XCTAssertEqual(title, "Test Song")
        XCTAssertEqual(api.lastTrack?.isrc, "TEST00000001")
        XCTAssertFalse(auth.signInCalled, "Si ya estaba autenticado, NO debe disparar signIn")
    }

    func testAddToPlaylist_alreadyPresent_returnsAlreadyPresent() async {
        auth.isAuthenticatedValue = true
        api.outcome = .alreadyPresent

        vm.addToPlaylist(Self.testTrack)
        await waitFor(isSuccessState(vm.state, expecting: .alreadyPresent))

        guard case .success(.alreadyPresent, _) = vm.state else {
            return XCTFail("Esperaba .success(.alreadyPresent). Actual: \(vm.state)")
        }
    }

    // MARK: - Not authenticated → signs in → success

    func testAddToPlaylist_notAuthenticated_signsInFirstThenAdds() async {
        auth.isAuthenticatedValue = false
        auth.signInResult = .success(SpotifyTokens(
            accessToken: "fresh",
            refreshToken: "r",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "any"
        ))
        api.outcome = .added

        vm.addToPlaylist(Self.testTrack)
        await waitFor(isSuccessState(vm.state, expecting: .added))

        XCTAssertTrue(auth.signInCalled, "Debe disparar signIn cuando no autenticado")
    }

    // MARK: - Not found

    func testAddToPlaylist_trackNotInSpotify_reachesNotFoundState() async {
        auth.isAuthenticatedValue = true
        api.error = RadioPremiumError.spotifyTrackNotFound(query: "Test Artist — Test Song")

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .notFound = vm.state { return true } else { return false }
        }())

        guard case .notFound(let query) = vm.state else {
            return XCTFail("Esperaba .notFound. Actual: \(vm.state)")
        }
        XCTAssertEqual(query, "Test Artist — Test Song")
    }

    // MARK: - Error: API

    func testAddToPlaylist_apiError_reachesErrorState() async {
        auth.isAuthenticatedValue = true
        api.error = RadioPremiumError.network(URLError(.notConnectedToInternet))

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .error = vm.state { return true } else { return false }
        }())

        guard case .error = vm.state else {
            return XCTFail("Esperaba .error. Actual: \(vm.state)")
        }
    }

    // MARK: - Error: signIn fails

    func testAddToPlaylist_signInFails_reachesErrorState() async {
        auth.isAuthenticatedValue = false
        auth.signInResult = .failure(RadioPremiumError.spotifyAuthFailed(reason: "user cancelled"))

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .error = vm.state { return true } else { return false }
        }())

        XCTAssertFalse(api.addCalled, "No debe llamar a la API si signIn falla")
    }

    // MARK: - Error: token revoked mid-flow

    func testAddToPlaylist_authRequiredDuringFlow_specificMessage() async {
        auth.isAuthenticatedValue = true
        api.error = RadioPremiumError.spotifyAuthRequired

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .error = vm.state { return true } else { return false }
        }())

        guard case .error(let reason) = vm.state else {
            return XCTFail("Esperaba .error. Actual: \(vm.state)")
        }
        XCTAssertTrue(
            reason.contains("Sesión") || reason.contains("conectar"),
            "El mensaje debe sugerir reconectar. Got: \(reason)"
        )
    }

    // MARK: - Reset

    func testReset_returnsToIdle() async {
        auth.isAuthenticatedValue = true
        api.outcome = .added

        vm.addToPlaylist(Self.testTrack)
        await waitFor(isSuccessState(vm.state, expecting: .added))

        vm.reset()
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - SignOut

    func testSignOut_clearsAuth_returnsToIdle() async {
        auth.isAuthenticatedValue = true
        await vm.signOut()

        XCTAssertTrue(auth.signOutCalled)
        XCTAssertFalse(auth.isAuthenticatedValue)
        XCTAssertEqual(vm.state, .idle)
    }
}

// MARK: - Stubs

private final class StubSpotifyAuth: SpotifyAuthing, @unchecked Sendable {
    var isAuthenticatedValue: Bool = false
    var signInResult: Result<SpotifyTokens, Error>?
    private(set) var signInCalled: Bool = false
    private(set) var signOutCalled: Bool = false

    func isAuthenticated() async -> Bool {
        isAuthenticatedValue
    }

    func signIn() async throws -> SpotifyTokens {
        signInCalled = true
        switch signInResult {
        case .success(let tokens):
            isAuthenticatedValue = true
            return tokens
        case .failure(let error):
            throw error
        case nil:
            throw RadioPremiumError.spotifyAuthFailed(reason: "stub no configurado")
        }
    }

    func signOut() async {
        signOutCalled = true
        isAuthenticatedValue = false
    }
}

private final class StubSpotifyAdding: SpotifyAdding, @unchecked Sendable {
    var outcome: SpotifyAddOutcome = .added
    var error: Error?
    private(set) var addCalled: Bool = false
    private(set) var lastTrack: Track?

    func addTrackToRadioLikes(_ track: Track) async throws -> SpotifyAddOutcome {
        addCalled = true
        lastTrack = track
        if let error { throw error }
        return outcome
    }
}
