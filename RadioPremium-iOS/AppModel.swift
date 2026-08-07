//
//  AppModel.swift
//  RadioPremium-iOS
//
//  Container observable que cuelga del @main App y se inyecta al árbol de
//  vistas vía .environment(_:). Tiene el player, favoritos, lista de
//  emisoras top y el helper de Now Playing.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class AppModel {

    /// Instancia única compartida entre la escena del iPhone (SwiftUI) y la
    /// escena CarPlay. Ambas interfaces controlan EL MISMO player y los mismos
    /// favoritos: pulsar play en el coche se refleja en el iPhone y viceversa.
    static let shared = AppModel()

    let player: IOSAudioPlayer
    let favorites: FavoritesStore
    private let api: RadioBrowserAPI
    private let nowPlaying: NowPlayingHelper

    private(set) var topStations: [Station] = []
    private(set) var searchResults: [Station] = []
    private(set) var isLoadingTop = false
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    private var nowPlayingTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.blancosampedro.RadioPremium-iOS", category: "app")

    init() {
        let player = IOSAudioPlayer()
        self.player = player
        self.favorites = FavoritesStore()
        self.api = RadioBrowserAPI()
        self.nowPlaying = NowPlayingHelper(player: player)
        observePlayerForNowPlaying()
    }

    /// Re-publica el Now Playing cada vez que cambian el estado o la emisora
    /// del player, indefinidamente. Sustituye al sondeo de 20×500ms que se
    /// detenía a los 10 segundos: pasado ese tiempo (o al pausar desde el
    /// propio Control Center, cuyos comandos no re-publicaban), la pantalla de
    /// bloqueo mostraba un playbackRate que ya no era real. Mismo patrón
    /// withObservationTracking que usa el PlayerViewModel de macOS.
    private func observePlayerForNowPlaying() {
        nowPlayingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.nowPlaying.update(station: self.player.currentStation, state: self.player.state)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.player.state
                        _ = self.player.currentStation
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    // MARK: - Browse

    func loadTopStations() async {
        guard !isLoadingTop else { return }
        isLoadingTop = true
        defer { isLoadingTop = false }

        do {
            topStations = try await api.topStations(limit: 50)
            errorMessage = nil
        } catch {
            log.error("topStations failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "No se pudieron cargar las emisoras: \(error.localizedDescription)"
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await api.search(name: trimmed, limit: 50)
            errorMessage = nil
        } catch {
            log.error("search failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Error de búsqueda: \(error.localizedDescription)"
        }
    }

    func clearSearch() {
        searchResults = []
    }

    // MARK: - Playback

    func play(_ station: Station) {
        player.play(station)
        // Update inmediato; los cambios posteriores de estado los re-publica
        // el bucle observePlayerForNowPlaying.
        nowPlaying.update(station: station, state: player.state)
    }

    func togglePlayPause() {
        player.togglePlayPause()
        if let s = player.currentStation {
            nowPlaying.update(station: s, state: player.state)
        }
    }

    func stop() {
        player.stop()
        nowPlaying.update(station: nil, state: .idle)
    }
}
