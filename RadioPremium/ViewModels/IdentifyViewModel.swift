//
//  IdentifyViewModel.swift
//  RadioPremium
//
//  State machine que orquesta el flujo completo de identify:
//
//    idle
//     → (startIdentify) → check permission
//     ├── granted     → capturing(0..1) → processing → result | noMatch | error
//     ├── denied      → permissionDenied (Open Settings)
//     └── unknown     → explainingPermission → requestingPermission → ...
//
//  Decisión 2A del /plan-design-review: cuando el permiso aún no está concedido
//  ni denegado, mostramos PRIMERO una card propia explicando "macOS llama
//  Screen Recording al permiso de capturar audio del sistema, no grabamos
//  imágenes" y luego dejamos que SCStream dispare el system dialog real.
//
//  Inyección por protocolo: el VM no toca tipos concretos. ScreenCaptureRecorder,
//  AcrCloudClient e IdentifiedTracksRepository conforman los protocolos de abajo
//  vía extensions; los tests usan stubs sin tocar audio ni red real.
//

import Foundation
import Observation
import os

// MARK: - Protocolos para DI

protocol ScreenCaptureRecording: Sendable {
    func capture(
        duration: Duration,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Data
}

protocol AcrCloudIdentifying: Sendable {
    func identify(_ pcmSample: Data, timestamp: Date) async throws -> Track
}

protocol IdentifiedTracksStoring: Sendable {
    func append(_ entry: IdentifiedTrackHistory) async throws
}

protocol PermissionProbing: Sendable {
    func screenRecordingStatus() async -> ScreenRecordingPermissionStatus
}

// Conformances de los services reales — sin cambios a su lógica.

extension ScreenCaptureRecorder: ScreenCaptureRecording {}
extension AcrCloudClient: AcrCloudIdentifying {}
extension IdentifiedTracksRepository: IdentifiedTracksStoring {}

struct RealPermissionProbe: PermissionProbing {
    func screenRecordingStatus() async -> ScreenRecordingPermissionStatus {
        await PermissionsHelper.screenRecordingStatus()
    }
}

// MARK: - State

enum IdentifyState: Sendable, Equatable {
    case idle
    case explainingPermission
    case requestingPermission
    case permissionDenied
    case capturing(progress: Double)
    case processing
    case result(IdentifiedTrackHistory)
    case noMatch
    case error(String)
}

// MARK: - View Model

@MainActor
@Observable
final class IdentifyViewModel {

    private(set) var state: IdentifyState = .idle
    private(set) var isPresented: Bool = false

    private let recorder: any ScreenCaptureRecording
    private let client: any AcrCloudIdentifying
    private let repo: any IdentifiedTracksStoring
    private let permissions: any PermissionProbing
    private let captureSeconds: Int

    private var lastStation: Station?
    private var currentTask: Task<Void, Never>?
    private var hasShownExplanation: Bool = false

    init(
        recorder: any ScreenCaptureRecording,
        client: any AcrCloudIdentifying,
        repo: any IdentifiedTracksStoring,
        permissions: any PermissionProbing = RealPermissionProbe(),
        captureSeconds: Int = 10
    ) {
        self.recorder = recorder
        self.client = client
        self.repo = repo
        self.permissions = permissions
        self.captureSeconds = captureSeconds
    }

    // MARK: - Public commands

    /// Inicia el flujo identify. Llamar desde el botón ♪ del NowPlayingBand.
    /// `currentStation` se guarda para incluirla en el historial.
    func startIdentify(currentStation: Station?) {
        cancelInFlight()
        lastStation = currentStation
        // Reset ANTES de presentar: sin esto, reabrir el sheet (o "Reintentar")
        // mostraba la tarjeta vieja de error/"sin resultados" hasta que la sonda
        // de permisos terminaba, y el botón parecía no responder.
        state = .idle
        isPresented = true

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runFlow()
        }
    }

    /// Continúa tras la PermissionExplanationCard. Pasa a requestingPermission
    /// y dispara el flujo real (que disparará el system dialog si aún no concedido).
    func continueAfterExplanation() {
        guard case .explainingPermission = state else { return }
        hasShownExplanation = true
        state = .requestingPermission
        currentTask = Task { @MainActor [weak self] in
            await self?.runFlow()
        }
    }

    /// Reintenta tras .noMatch o .error. Reusa la última emisora.
    func retry() {
        let station = lastStation
        startIdentify(currentStation: station)
    }

    /// Cierra el sheet sin cancelar nada más (la captura sigue si está en marcha).
    /// Si quieres parar todo, usa cancel().
    func dismiss() {
        isPresented = false
    }

    /// Cancela cualquier captura en curso y vuelve a idle. Cierra el sheet.
    func cancel() {
        cancelInFlight()
        state = .idle
        isPresented = false
    }

    /// Abre System Settings → Privacy & Security → Screen Recording.
    /// Llamar desde PermissionDeniedCard.
    func openSystemSettings() {
        PermissionsHelper.openScreenRecordingSettings()
    }

    // MARK: - Internals

    private func cancelInFlight() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func runFlow() async {
        // 1. Comprobar permiso (puede disparar el system dialog en .notDetermined).
        let status = await permissions.screenRecordingStatus()
        if Task.isCancelled { return }

        switch status {
        case .denied:
            // Si nunca hemos enseñado la card explicativa, hazlo PRIMERO.
            // Si ya la enseñamos y volvemos a estar denegados, es denegación firme.
            if hasShownExplanation {
                state = .permissionDenied
            } else {
                state = .explainingPermission
            }
            return
        case .notDetermined:
            state = .explainingPermission
            return
        case .granted:
            break
        }

        // 2. Capturar audio del sistema.
        state = .capturing(progress: 0)
        AppLogger.identify.info("starting capture for identify")

        let pcm: Data
        do {
            pcm = try await recorder.capture(
                duration: .seconds(captureSeconds),
                onProgress: { [weak self] p in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .capturing = self.state {
                            self.state = .capturing(progress: p)
                        }
                    }
                }
            )
        } catch let error as RadioPremiumError where error == .screenRecordingPermissionDenied {
            if Task.isCancelled { return }
            state = .permissionDenied
            return
        } catch {
            if Task.isCancelled { return }
            handleError(error)
            return
        }

        if Task.isCancelled { return }

        // 3. Subir a ACRCloud.
        state = .processing
        let track: Track
        do {
            track = try await client.identify(pcm, timestamp: Date())
        } catch let error as RadioPremiumError where error == .acrCloudNoMatch {
            if Task.isCancelled { return }
            state = .noMatch
            return
        } catch {
            if Task.isCancelled { return }
            handleError(error)
            return
        }

        if Task.isCancelled { return }

        // 4. Persistir en historial y mostrar resultado.
        let entry = IdentifiedTrackHistory.from(track: track, station: lastStation)
        do {
            try await repo.append(entry)
        } catch {
            // No rompemos el flujo si la persistencia falla; logueamos.
            AppLogger.identify.error("history append failed: \(error.localizedDescription, privacy: .public)")
        }

        if Task.isCancelled { return }
        state = .result(entry)
    }

    private func handleError(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        AppLogger.identify.error("identify failed: \(msg, privacy: .public)")
        state = .error(msg)
    }
}

// MARK: - Equatable helper para comparar errores en switch

private extension RadioPremiumError {
    static func == (lhs: RadioPremiumError, rhs: RadioPremiumError) -> Bool {
        switch (lhs, rhs) {
        case (.screenRecordingPermissionDenied, .screenRecordingPermissionDenied):
            return true
        case (.acrCloudNoMatch, .acrCloudNoMatch):
            return true
        default:
            return false
        }
    }
}
