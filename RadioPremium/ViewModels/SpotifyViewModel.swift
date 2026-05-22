//
//  SpotifyViewModel.swift
//  RadioPremium
//
//  State machine para el flujo "añadir track identificado a playlist Radio Likes".
//  Disparado desde el botón "Añadir a Spotify" del IdentifySheet.
//
//  Flow:
//    idle
//     ↓ addToPlaylist(track)
//     ├── (no auth) → authenticating → ASWebAuthSession → continúa
//     ├── (auth ya) → directly continue
//     ↓ processing (find by ISRC → fallback title+artist → find/create playlist → add)
//     ├── added         → success(.added, title)
//     ├── alreadyPresent → success(.alreadyPresent, title)
//     ├── notFound      → notFound(query)
//     └── otros errores → error(reason)
//
//  Inyección por protocolo: SpotifyAuthClient y SpotifyApiClient conforman
//  los protocolos de abajo. Tests usan stubs sin tocar Keychain ni red real.
//

import Foundation
import Observation
import os
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Protocolos para DI

protocol SpotifyAuthing: Sendable {
    func isAuthenticated() async -> Bool
    func signIn() async throws -> SpotifyTokens
    func signOut() async
}

protocol SpotifyAdding: Sendable {
    func addTrackToRadioLikes(_ track: Track) async throws -> SpotifyAddOutcome
}

/// Protocolo separado del `SpotifyAdding` para el flujo "Abrir en Spotify".
/// Se mantiene aparte para no obligar a los stubs de tests existentes a
/// implementar el método cuando solo prueban el flujo de añadir.
protocol SpotifyFinding: Sendable {
    func findTrackUri(for track: Track) async throws -> String
}

extension SpotifyAuthClient: SpotifyAuthing {}
extension SpotifyApiClient: SpotifyAdding {}
extension SpotifyApiClient: SpotifyFinding {}

// MARK: - State

enum SpotifyState: Sendable, Equatable {
    case idle
    case authenticating
    case processing
    case success(SpotifyAddOutcome, trackTitle: String)
    /// El flujo "Abrir en Spotify" terminó: el URI del track se abrió en la
    /// app/web de Spotify. El usuario añade manualmente a la playlist que quiera.
    case openedInSpotify(trackTitle: String)
    case notFound(query: String)
    case error(reason: String)
}

// MARK: - View Model

@MainActor
@Observable
final class SpotifyViewModel {

    private(set) var state: SpotifyState = .idle

    private let auth: any SpotifyAuthing
    private let api: any SpotifyAdding
    /// Opcional para no romper los inits de tests existentes que sólo prueban
    /// `addToPlaylist`. En el init de producción se inyecta el cliente real.
    private let finder: (any SpotifyFinding)?
    private var currentTask: Task<Void, Never>?

    init(auth: any SpotifyAuthing, api: any SpotifyAdding, finder: (any SpotifyFinding)? = nil) {
        self.auth = auth
        self.api = api
        self.finder = finder
    }

    /// Init de conveniencia: construye los clients reales.
    init() {
        let http = HTTPClient()
        let auth = SpotifyAuthClient(http: http)
        let api = SpotifyApiClient(http: http, auth: auth)
        self.auth = auth
        self.api = api
        self.finder = api
    }

    // MARK: - Public commands

    /// Inicia el flujo de añadir el track. Si no estamos autenticados, dispara
    /// el sign-in primero (ASWebAuthSession). El estado se actualiza
    /// progresivamente para que la UI dé feedback en cada paso.
    func addToPlaylist(_ track: Track) {
        currentTask?.cancel()
        currentTask = Task { @MainActor [weak self] in
            await self?.runFlow(for: track)
        }
    }

    /// Inicia el flujo "Abrir en Spotify": busca el track en el catálogo
    /// Spotify y abre el URI resultante (`spotify:track:XXXX`) en la app
    /// Spotify de macOS, con fallback a `https://open.spotify.com/track/...`
    /// si la app no estuviera instalada. El usuario añade manualmente a la
    /// playlist que quiera dentro de Spotify.
    ///
    /// Este flujo evita los endpoints de creación de playlist y de
    /// lectura/escritura de tracks de playlist privada, que Spotify bloquea
    /// con 403 en Development Mode hasta pasar Extended Quota Review.
    func openInSpotify(_ track: Track) {
        currentTask?.cancel()
        currentTask = Task { @MainActor [weak self] in
            await self?.runOpenFlow(for: track)
        }
    }

    /// Resetea el estado a idle. Llamar cuando el usuario cierra el sheet
    /// o cambia de track identificado.
    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    /// Cierra sesión de Spotify (borra tokens del Keychain).
    func signOut() async {
        currentTask?.cancel()
        await auth.signOut()
        state = .idle
    }

    /// Snapshot del estado de autenticación.
    func isAuthenticated() async -> Bool {
        await auth.isAuthenticated()
    }

    // MARK: - Internals

    private func runFlow(for track: Track) async {
        // 1. Verificar auth, signIn si hace falta.
        let authed = await auth.isAuthenticated()
        if !authed {
            state = .authenticating
            do {
                _ = try await auth.signIn()
            } catch is CancellationError {
                state = .idle
                return
            } catch {
                if Task.isCancelled { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppLogger.spotify.error("signIn failed: \(reason, privacy: .public)")
                state = .error(reason: reason)
                return
            }
            if Task.isCancelled { return }
        }

        // 2. Find + add.
        state = .processing
        do {
            let outcome = try await api.addTrackToRadioLikes(track)
            if Task.isCancelled { return }
            state = .success(outcome, trackTitle: track.title)
            AppLogger.spotify.info("addToPlaylist outcome=\(String(describing: outcome), privacy: .public) for '\(track.title, privacy: .public)'")
        } catch RadioPremiumError.spotifyTrackNotFound(let query) {
            if Task.isCancelled { return }
            state = .notFound(query: query)
            AppLogger.spotify.info("track not found in Spotify: \(query, privacy: .public)")
        } catch RadioPremiumError.spotifyAuthRequired {
            // El token se invalidó mid-flow (revocado server-side, etc).
            // Forzar re-auth en el próximo intento.
            if Task.isCancelled { return }
            state = .error(reason: "Sesión Spotify expirada. Vuelve a conectar.")
        } catch {
            if Task.isCancelled { return }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLogger.spotify.error("add failed: \(reason, privacy: .public)")
            state = .error(reason: reason)
        }
    }

    /// Implementación del flujo "Abrir en Spotify". Espejo simplificado de
    /// `runFlow` pero solo con auth + search + open (sin writes ni dedup reads).
    private func runOpenFlow(for track: Track) async {
        guard let finder else {
            state = .error(reason: "Configuración incompleta: falta el buscador de Spotify.")
            return
        }

        // 1. Verificar auth. /v1/search requiere bearer token aunque sea search
        //    en catálogo público.
        let authed = await auth.isAuthenticated()
        if !authed {
            state = .authenticating
            do {
                _ = try await auth.signIn()
            } catch is CancellationError {
                state = .idle
                return
            } catch {
                if Task.isCancelled { return }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppLogger.spotify.error("signIn failed: \(reason, privacy: .public)")
                state = .error(reason: reason)
                return
            }
            if Task.isCancelled { return }
        }

        // 2. Search en Spotify y abrir el URI.
        state = .processing
        do {
            let uri = try await finder.findTrackUri(for: track)
            if Task.isCancelled { return }
            openSpotifyURI(uri)
            state = .openedInSpotify(trackTitle: track.title)
            AppLogger.spotify.info("opened in Spotify uri=\(uri, privacy: .public) for '\(track.title, privacy: .public)'")
        } catch RadioPremiumError.spotifyTrackNotFound(let query) {
            if Task.isCancelled { return }
            state = .notFound(query: query)
            AppLogger.spotify.info("track not found in Spotify: \(query, privacy: .public)")
        } catch RadioPremiumError.spotifyAuthRequired {
            if Task.isCancelled { return }
            state = .error(reason: "Sesión Spotify expirada. Vuelve a conectar.")
        } catch {
            if Task.isCancelled { return }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLogger.spotify.error("open failed: \(reason, privacy: .public)")
            state = .error(reason: reason)
        }
    }

    /// Abre el track en Spotify. Intenta primero la URI nativa
    /// (`spotify:track:XXX`) — abre la app de macOS si está instalada.
    /// Si no hay handler para el esquema `spotify:`, hace fallback a la web.
    private func openSpotifyURI(_ uri: String) {
        #if canImport(AppKit)
        if let appURL = URL(string: uri), NSWorkspace.shared.open(appURL) {
            return
        }
        // Fallback web: convierte "spotify:track:ID" → "https://open.spotify.com/track/ID"
        let trackId = uri.replacingOccurrences(of: "spotify:track:", with: "")
        if let webURL = URL(string: "https://open.spotify.com/track/\(trackId)") {
            NSWorkspace.shared.open(webURL)
        }
        #endif
    }
}
