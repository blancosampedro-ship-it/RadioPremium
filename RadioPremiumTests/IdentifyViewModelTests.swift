//
//  IdentifyViewModelTests.swift
//  RadioPremiumTests
//
//  Tests del state machine de IdentifyViewModel con stubs de las
//  dependencias (recorder, client, repo, permission probe).
//

import XCTest
@testable import RadioPremium

@MainActor
final class IdentifyViewModelTests: XCTestCase {

    private var recorder: StubRecorder!
    private var client: StubAcrClient!
    private var repo: StubRepo!
    private var permissions: StubPermissions!
    private var vm: IdentifyViewModel!

    override func setUp() async throws {
        try await super.setUp()
        recorder = StubRecorder()
        client = StubAcrClient()
        repo = StubRepo()
        permissions = StubPermissions(status: .granted)
        vm = IdentifyViewModel(
            recorder: recorder,
            client: client,
            repo: repo,
            permissions: permissions,
            captureSeconds: 1
        )
    }

    override func tearDown() async throws {
        vm.cancel()
        vm = nil
        recorder = nil
        client = nil
        repo = nil
        permissions = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func waitFor(
        timeoutMs: Int = 1000,
        _ condition: @autoclosure () -> Bool
    ) async {
        let stepMs = 5
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(stepMs))
            elapsed += stepMs
        }
    }

    private static let testStation = Station(
        id: "test-1",
        name: "Test Radio",
        countryCode: "ES"
    )

    private static let testTrack = Track(
        title: "Test Song",
        artist: "Test Artist",
        album: "Test Album"
    )

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertEqual(vm.state, .idle)
        XCTAssertFalse(vm.isPresented)
    }

    // MARK: - Granted permission flow

    func testStartIdentify_grantedPermission_reachesResultState() async {
        recorder.resultData = Data([0x00, 0x01, 0x02])
        client.resultTrack = Self.testTrack

        vm.startIdentify(currentStation: Self.testStation)
        await waitFor(isResultState(vm.state))

        XCTAssertTrue(vm.isPresented, "Sheet debe quedar abierto al llegar al resultado")

        guard case .result(let history) = vm.state else {
            return XCTFail("Estado final debe ser .result, fue \(vm.state)")
        }
        XCTAssertEqual(history.track.title, "Test Song")
        XCTAssertEqual(history.track.artist, "Test Artist")
        XCTAssertEqual(history.stationName, "Test Radio")
    }

    func testStartIdentify_appendsToHistory() async {
        recorder.resultData = Data([0x00])
        client.resultTrack = Self.testTrack

        vm.startIdentify(currentStation: Self.testStation)
        await waitFor(isResultState(vm.state))

        XCTAssertEqual(repo.appendCallCount, 1)
        XCTAssertEqual(repo.lastAppended?.track.title, "Test Song")
    }

    func testStartIdentify_passesPCMToAcrCloud() async {
        recorder.resultData = Data([0xAA, 0xBB, 0xCC])
        client.resultTrack = Self.testTrack

        vm.startIdentify(currentStation: nil)
        await waitFor(isResultState(vm.state))

        XCTAssertEqual(client.lastPCM, Data([0xAA, 0xBB, 0xCC]))
    }

    // MARK: - No match

    func testStartIdentify_acrCloudNoMatch_reachesNoMatchState() async {
        recorder.resultData = Data()
        client.error = RadioPremiumError.acrCloudNoMatch

        vm.startIdentify(currentStation: Self.testStation)
        await waitFor(vm.state == .noMatch)

        XCTAssertEqual(vm.state, .noMatch)
        XCTAssertEqual(repo.appendCallCount, 0, "No se persiste si no hay match")
    }

    // MARK: - Error

    func testStartIdentify_acrCloudFailure_reachesErrorState() async {
        recorder.resultData = Data()
        client.error = RadioPremiumError.acrCloudFailed(reason: "test failure")

        vm.startIdentify(currentStation: Self.testStation)
        await waitFor(isErrorState(vm.state))

        guard case .error(let reason) = vm.state else {
            return XCTFail("Estado final debe ser .error, fue \(vm.state)")
        }
        XCTAssertTrue(reason.contains("test failure"), "Razón debe contener mensaje original: \(reason)")
    }

    func testStartIdentify_recorderFailure_reachesErrorState() async {
        recorder.error = RadioPremiumError.audioFormatUnsupported(detail: "bad format")

        vm.startIdentify(currentStation: Self.testStation)
        await waitFor(isErrorState(vm.state))

        guard case .error = vm.state else {
            return XCTFail("Estado final debe ser .error, fue \(vm.state)")
        }
    }

    // MARK: - Permission flow

    func testStartIdentify_deniedPermission_firstTime_showsExplanation() async {
        permissions.status = .denied

        vm.startIdentify(currentStation: nil)
        await waitFor(vm.state == .explainingPermission)

        XCTAssertEqual(vm.state, .explainingPermission,
                       "Primera vez con permiso denegado debe enseñar PRIMERO la card explicativa.")
    }

    func testStartIdentify_notDeterminedPermission_showsExplanation() async {
        permissions.status = .notDetermined

        vm.startIdentify(currentStation: nil)
        await waitFor(vm.state == .explainingPermission)

        XCTAssertEqual(vm.state, .explainingPermission)
    }

    func testContinueAfterExplanation_thenDenied_reachesPermissionDenied() async {
        permissions.status = .denied

        vm.startIdentify(currentStation: nil)
        await waitFor(vm.state == .explainingPermission)

        vm.continueAfterExplanation()
        await waitFor(vm.state == .permissionDenied)

        XCTAssertEqual(vm.state, .permissionDenied,
                       "Tras la card y seguir denegado, va a permissionDenied (Open Settings).")
    }

    // MARK: - Cancel / dismiss

    func testCancel_returnsToIdle_andClosesSheet() async {
        recorder.resultData = Data()
        recorder.captureDelayMs = 200  // captura tarda — damos tiempo a cancelar
        client.resultTrack = Self.testTrack

        vm.startIdentify(currentStation: nil)
        await waitFor(vm.state.isCapturing)

        vm.cancel()

        XCTAssertEqual(vm.state, .idle)
        XCTAssertFalse(vm.isPresented)
    }

    func testDismiss_closesSheetWithoutChangingState() async {
        recorder.resultData = Data()
        client.resultTrack = Self.testTrack

        vm.startIdentify(currentStation: nil)
        await waitFor(isResultState(vm.state))

        vm.dismiss()

        XCTAssertFalse(vm.isPresented, "dismiss cierra sheet")
        // state queda en .result — no se borra al dismiss
        guard case .result = vm.state else {
            return XCTFail("dismiss no debe cambiar el state. Actual: \(vm.state)")
        }
    }

    // MARK: - Retry

    func testRetry_fromNoMatch_reusesLastStation() async {
        recorder.resultData = Data()
        client.error = RadioPremiumError.acrCloudNoMatch

        vm.startIdentify(currentStation: Self.testStation)
        await waitFor(vm.state == .noMatch)

        // Cambiamos para que retry encuentre match
        client.error = nil
        client.resultTrack = Self.testTrack

        vm.retry()
        await waitFor(isResultState(vm.state))

        guard case .result(let history) = vm.state else {
            return XCTFail("retry desde noMatch debe alcanzar .result si ahora matchea")
        }
        XCTAssertEqual(history.stationName, "Test Radio",
                       "retry debe reusar la lastStation original.")
    }
}

// MARK: - Helpers de matching de state

@MainActor
private func isResultState(_ state: IdentifyState) -> Bool {
    if case .result = state { return true }
    return false
}

@MainActor
private func isErrorState(_ state: IdentifyState) -> Bool {
    if case .error = state { return true }
    return false
}

private extension IdentifyState {
    var isCapturing: Bool {
        if case .capturing = self { return true }
        return false
    }
}

// MARK: - Stubs

private final class StubRecorder: ScreenCaptureRecording, @unchecked Sendable {
    var resultData: Data?
    var error: Error?
    var captureDelayMs: Int = 5

    func capture(
        duration: Duration,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Data {
        // Simular progreso 0..1 durante captureDelayMs total.
        let steps = 4
        let stepMs = max(1, captureDelayMs / steps)
        for i in 1...steps {
            try await Task.sleep(for: .milliseconds(stepMs))
            onProgress?(Double(i) / Double(steps))
            if Task.isCancelled { throw CancellationError() }
        }

        if let error { throw error }
        return resultData ?? Data()
    }
}

private final class StubAcrClient: AcrCloudIdentifying, @unchecked Sendable {
    var resultTrack: Track?
    var error: Error?
    private(set) var lastPCM: Data?

    func identify(_ pcmSample: Data, timestamp: Date) async throws -> Track {
        lastPCM = pcmSample
        if let error { throw error }
        guard let track = resultTrack else {
            throw RadioPremiumError.acrCloudFailed(reason: "stub no configurado")
        }
        return track
    }
}

private final class StubRepo: IdentifiedTracksStoring, @unchecked Sendable {
    private(set) var appendCallCount = 0
    private(set) var lastAppended: IdentifiedTrackHistory?

    func append(_ entry: IdentifiedTrackHistory) async throws {
        appendCallCount += 1
        lastAppended = entry
    }
}

private final class StubPermissions: PermissionProbing, @unchecked Sendable {
    var status: ScreenRecordingPermissionStatus

    init(status: ScreenRecordingPermissionStatus) {
        self.status = status
    }

    func screenRecordingStatus() async -> ScreenRecordingPermissionStatus {
        status
    }
}
