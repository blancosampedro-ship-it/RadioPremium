//
//  AppleMusicViewModel.swift
//  RadioPremium
//
//  State machine para añadir un track identificado a la playlist
//  "Radio Likes" en Apple Music. Espejo de SpotifyViewModel.
//
//  Flow:
//    idle
//     ↓ addToPlaylist(track)
//     ├── (autorización pendiente) → authenticating → diálogo sistema
//     ├── (ya autorizado) → directly continue
//     ↓ processing (auth → search → find/create playlist → add)
//     ├── added         → success(.added, title)
//     ├── alreadyPresent → success(.alreadyPresent, title)
//     ├── notFound      → notFound(query)
//     └── otros errores → error(reason)
//
//  Inyección por protocolo (AppleMusicAdding) para que los tests usen un
//  stub sin tocar MusicKit ni la red real.
//

import Foundation
import MusicKit
import Observation
import os

// MARK: - Protocolo para DI

protocol AppleMusicAdding: Sendable {
    func addTrackToRadioLikes(_ track: Track) async throws -> SpotifyAddOutcome
}

extension AppleMusicClient: AppleMusicAdding {}

// MARK: - State

enum AppleMusicState: Sendable, Equatable {
    case idle
    case authenticating
    case processing
    case success(SpotifyAddOutcome, trackTitle: String)
    case notFound(query: String)
    case error(reason: String)
}

// MARK: - View Model

@MainActor
@Observable
final class AppleMusicViewModel {

    private(set) var state: AppleMusicState = .idle

    private let api: any AppleMusicAdding
    private var currentTask: Task<Void, Never>?

    init(api: any AppleMusicAdding) {
        self.api = api
    }

    /// Init de conveniencia: construye el client real.
    init() {
        self.api = AppleMusicClient()
    }

    // MARK: - Public commands

    func addToPlaylist(_ track: Track) {
        currentTask?.cancel()
        currentTask = Task { @MainActor [weak self] in
            await self?.runFlow(for: track)
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    // MARK: - Internals

    private func runFlow(for track: Track) async {
        // En Apple Music la auth está integrada en el flujo: el primer
        // `addTrackToRadioLikes` que el cliente ve dispara el diálogo del
        // sistema vía `MusicAuthorization.request()`. Si ya estamos autorizados
        // (el caso habitual tras el primer uso) no hay diálogo que esperar, así
        // que mostramos directamente `.processing` — antes `.processing` era
        // inalcanzable y el botón decía "Autorizando…" durante toda la operación.
        state = MusicAuthorization.currentStatus == .authorized ? .processing : .authenticating
        do {
            let outcome = try await api.addTrackToRadioLikes(track)
            if Task.isCancelled { return }
            state = .success(outcome, trackTitle: track.title)
            AppLogger.appleMusic.info("addToPlaylist outcome=\(String(describing: outcome), privacy: .public) for '\(track.title, privacy: .public)'")
        } catch RadioPremiumError.appleMusicTrackNotFound(let query) {
            if Task.isCancelled { return }
            state = .notFound(query: query)
            AppLogger.appleMusic.info("track not found in Apple Music: \(query, privacy: .public)")
        } catch RadioPremiumError.appleMusicAuthRequired {
            if Task.isCancelled { return }
            state = .error(reason: "Necesitas autorizar Apple Music. Vuelve a intentarlo.")
        } catch RadioPremiumError.appleMusicAuthDenied {
            if Task.isCancelled { return }
            state = .error(reason: "Permiso de Apple Music denegado. Actívalo en System Settings → Privacy & Security → Media & Apple Music.")
        } catch RadioPremiumError.appleMusicSubscriptionRequired {
            if Task.isCancelled { return }
            state = .error(reason: "Necesitas una suscripción activa de Apple Music para añadir canciones.")
        } catch is CancellationError {
            // No tocar state: si la cancelación vino de un reemplazo (nuevo
            // addToPlaylist), la Task nueva ya gestiona el estado y poner .idle
            // aquí lo pisaría. reset() ya pone .idle por su cuenta.
            return
        } catch {
            if Task.isCancelled { return }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLogger.appleMusic.error("add failed: \(reason, privacy: .public)")
            state = .error(reason: reason)
        }
    }
}
