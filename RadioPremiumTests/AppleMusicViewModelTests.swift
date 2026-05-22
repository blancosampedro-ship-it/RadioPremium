//
//  AppleMusicViewModelTests.swift
//  RadioPremiumTests
//
//  Tests del state machine de AppleMusicViewModel con stub del client.
//  No tocan MusicKit real (no hay sesión Apple Music en CI / unit tests).
//

import XCTest
@testable import RadioPremium

@MainActor
final class AppleMusicViewModelTests: XCTestCase {

    private var api: StubAppleMusicAdding!
    private var vm: AppleMusicViewModel!

    override func setUp() async throws {
        try await super.setUp()
        api = StubAppleMusicAdding()
        vm = AppleMusicViewModel(api: api)
    }

    override func tearDown() async throws {
        vm.reset()
        vm = nil
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

    private func isSuccessState(_ state: AppleMusicState, expecting: SpotifyAddOutcome) -> Bool {
        if case .success(let outcome, _) = state, outcome == expecting { return true }
        return false
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - Success: added

    func testAddToPlaylist_success_added() async {
        api.outcome = .added

        vm.addToPlaylist(Self.testTrack)
        await waitFor(isSuccessState(vm.state, expecting: .added))

        guard case .success(.added, let title) = vm.state else {
            return XCTFail("Esperaba .success(.added). Actual: \(vm.state)")
        }
        XCTAssertEqual(title, "Test Song")
        XCTAssertEqual(api.lastTrack?.isrc, "TEST00000001")
    }

    // MARK: - Success: alreadyPresent

    func testAddToPlaylist_alreadyPresent() async {
        api.outcome = .alreadyPresent

        vm.addToPlaylist(Self.testTrack)
        await waitFor(isSuccessState(vm.state, expecting: .alreadyPresent))

        guard case .success(.alreadyPresent, _) = vm.state else {
            return XCTFail("Esperaba .success(.alreadyPresent). Actual: \(vm.state)")
        }
    }

    // MARK: - Not found

    func testAddToPlaylist_trackNotInAppleMusic_reachesNotFoundState() async {
        api.error = RadioPremiumError.appleMusicTrackNotFound(query: "Test Artist — Test Song")

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .notFound = vm.state { return true } else { return false }
        }())

        guard case .notFound(let query) = vm.state else {
            return XCTFail("Esperaba .notFound. Actual: \(vm.state)")
        }
        XCTAssertEqual(query, "Test Artist — Test Song")
    }

    // MARK: - Auth denied

    func testAddToPlaylist_authDenied_specificMessage() async {
        api.error = RadioPremiumError.appleMusicAuthDenied

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .error = vm.state { return true } else { return false }
        }())

        guard case .error(let reason) = vm.state else {
            return XCTFail("Esperaba .error. Actual: \(vm.state)")
        }
        XCTAssertTrue(
            reason.contains("denegado") || reason.contains("Settings"),
            "El mensaje debe sugerir abrir System Settings. Got: \(reason)"
        )
    }

    // MARK: - Subscription required

    func testAddToPlaylist_subscriptionRequired_specificMessage() async {
        api.error = RadioPremiumError.appleMusicSubscriptionRequired

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .error = vm.state { return true } else { return false }
        }())

        guard case .error(let reason) = vm.state else {
            return XCTFail("Esperaba .error. Actual: \(vm.state)")
        }
        XCTAssertTrue(
            reason.contains("suscripción") || reason.contains("Apple Music"),
            "El mensaje debe explicar que falta suscripción. Got: \(reason)"
        )
    }

    // MARK: - Generic error

    func testAddToPlaylist_genericError_reachesErrorState() async {
        api.error = RadioPremiumError.appleMusicFailed(reason: "network down")

        vm.addToPlaylist(Self.testTrack)
        await waitFor({
            if case .error = vm.state { return true } else { return false }
        }())

        guard case .error = vm.state else {
            return XCTFail("Esperaba .error. Actual: \(vm.state)")
        }
    }

    // MARK: - Reset

    func testReset_returnsToIdle() async {
        api.outcome = .added

        vm.addToPlaylist(Self.testTrack)
        await waitFor(isSuccessState(vm.state, expecting: .added))

        vm.reset()
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - State sequence

    func testAddToPlaylist_passesThrough_authenticating_state() async {
        // El primer estado al llamar addToPlaylist debe ser .authenticating
        // (luego será .processing internamente o se salta directo a .success).
        // Verificamos que no se queda en .idle.
        api.outcome = .added
        api.delayMs = 50

        vm.addToPlaylist(Self.testTrack)

        // Damos un pequeño tiempo para que el Task inicie pero antes de que
        // el stub responda.
        try? await Task.sleep(for: .milliseconds(10))
        if case .idle = vm.state {
            XCTFail("VM no debe quedarse en .idle tras addToPlaylist. Actual: \(vm.state)")
        }

        // Y termina en success.
        await waitFor(isSuccessState(vm.state, expecting: .added))
    }
}

// MARK: - Stub

private final class StubAppleMusicAdding: AppleMusicAdding, @unchecked Sendable {
    var outcome: SpotifyAddOutcome = .added
    var error: Error?
    var delayMs: Int = 0
    private(set) var addCalled: Bool = false
    private(set) var lastTrack: Track?

    func addTrackToRadioLikes(_ track: Track) async throws -> SpotifyAddOutcome {
        addCalled = true
        lastTrack = track
        if delayMs > 0 {
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        if let error { throw error }
        return outcome
    }
}
